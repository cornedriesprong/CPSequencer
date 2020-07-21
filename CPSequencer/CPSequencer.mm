//
//  CPSequencer.c
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include "CPSequencer.h"
#include "vector"

typedef struct PlayingNote {
    int pitch;
    int beat;
    int subtick;
    int channel;
    int destination;
    bool hasStopped;
} PlayingNote;

TPCircularBuffer fifoBuffer;

// nb: these are owned by the audio thread
int previousSubtick = 0;
int previousBeat = 0;
callback_t callback;
void *callbackRefCon;
std::vector<MIDIEvent*> scheduledEvents;
std::vector<PlayingNote> playingNotes;

MIDIEvent event(int beat, int subtick) {
    
    MIDIEvent event = {0};
    event.beat = beat;
    event.subtick = subtick;
    event.status = NOTE_ON;
    event.data1 = 64;
    event.data2 = 100;
    event.duration = 24;
    event.channel = 0;
    event.destination = 0;
    event.isQueued = true;
    
    return event;
}

void CPSequencerInit(callback_t __nullable cb, void * __nullable refCon) {
    
    callback = cb;
    callbackRefCon = refCon;
    scheduledEvents.reserve(NOTE_CAPACITY);
    playingNotes.reserve(NOTE_CAPACITY);
    TPCircularBufferInit(&fifoBuffer, BUFFER_LENGTH);
}

void addMidiEvent(MIDIEvent event) {
    
    uint32_t availableBytes = 0;
    MIDIEvent *head = (MIDIEvent *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    head = &event;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(MIDIEvent));
}

void getMidiEventsFromFIFOBuffer() {
    
    uint32_t bytes = -1;
    while (bytes != 0) {
        MIDIEvent *event = (MIDIEvent *)TPCircularBufferTail(&fifoBuffer, &bytes);
        if (event) {
            scheduledEvents.push_back(event);
            TPCircularBufferConsume(&fifoBuffer, sizeof(MIDIEvent));
        }
    }
}

void stopPlayingNotes(MIDIPacket *midiData,
                      const uint8_t beat,
                      const uint8_t subtick) {
    
    if (playingNotes.size() == 0)
        return;
    
    for (int i = 0; i < playingNotes.size(); i++) {
        
        // check if playing note is due to be stopped
        if (subtick == playingNotes[i].subtick &&
            beat == playingNotes[i].beat &&
            !playingNotes[i].hasStopped) {
            
            // if so, send note off
            PlayingNote note = playingNotes[i];
            
            // check if destination doesn't have weird value
            if (note.destination < 0 || note.destination > 7)
                note.destination = 0;
            
            int size = midiData[note.destination].length;
            midiData[note.destination].data[size] = NOTE_OFF + note.channel;
            midiData[note.destination].data[size + 1] = note.pitch;
            midiData[note.destination].data[size + 2] = 0;
            midiData[note.destination].length = size + 3;
            
            playingNotes[i].hasStopped = true;
        }
    }
    
    // remove playing notes that have stopped
    for (int i = 0; i < playingNotes.size(); i++) {
        if (playingNotes[i].hasStopped) {
            playingNotes.erase(playingNotes.begin() + i);
        }
    }
}

void fireEvents(MIDIPacket *midiData,
                const uint8_t beat,
                const uint8_t subtick) {
    
    stopPlayingNotes(midiData,
                     beat,
                     subtick);
    
    if (scheduledEvents.size() == 0)
        return;
    
    for (int i = 0; i < scheduledEvents.size(); i++) {
        
        if (subtick == scheduledEvents[i]->subtick &&
            beat == scheduledEvents[i]->beat &&
            scheduledEvents[i]->isQueued == true) {
            
            MIDIEvent *event = scheduledEvents[i];
            
            // if there's a playing note with same pitch, stop it first
            for (int j = 0; j < playingNotes.size(); j++) {

                if (playingNotes[j].pitch == event->data1 &&
                    !playingNotes[j].hasStopped) {

                    // if so, send note off
                    PlayingNote note = playingNotes[j];
                    playingNotes[j].hasStopped = true;

                    int size = midiData[note.destination].length;
                    midiData[note.destination].data[size] = NOTE_OFF + note.channel;
                    midiData[note.destination].data[size + 1] = note.pitch;
                    midiData[note.destination].data[size + 2] = 0;
                    midiData[note.destination].length = size + 3;
                }
            }

            // schedule note on
            int size = midiData[event->destination].length;
            midiData[event->destination].data[size] = NOTE_ON + event->channel;
            midiData[event->destination].data[size + 1] = event->data1;
            midiData[event->destination].data[size + 2] = event->data2;
            midiData[event->destination].length = size + 3;
            
            // schedule note off
            PlayingNote noteOff;
            noteOff.pitch = event->data1;
            
            int currentBeat;
            if (subtick + event->duration >= PPQ) {
                currentBeat = beat + (int)floor((event->duration + subtick) / (double)PPQ);
            } else {
                currentBeat = beat;
            }
            noteOff.beat = currentBeat;
            noteOff.subtick = (subtick + event->duration) % PPQ;
            noteOff.channel = event->channel;
            noteOff.destination = event->destination;
            noteOff.hasStopped = false;
            playingNotes.push_back(noteOff);
            
            scheduledEvents[i]->isQueued = false;
        }
    }
    
    // remove scheduled events in the past
    for (int i = 0; i < scheduledEvents.size(); i++) {
        if (scheduledEvents[i]->isQueued == false) {
            scheduledEvents.erase(scheduledEvents.begin() + i);
        }
    }
}

double samplesPerBeat(double sampleRate, double tempo) {
    return (sampleRate * 60.0) / tempo;
}

double samplesPerSubtick(double sampleRate, double tempo) {
    return samplesPerBeat(sampleRate, tempo) / PPQ;
}

int subtickPosition(const double beatPosition) {
    
    double integral;
    double fractional = modf(beatPosition, &integral);
    return ceil(PPQ * fractional);
}

int64_t sampleTimeForNextSubtick(const double sampleRate,
                                 const double tempo,
                                 AUEventSampleTime sampleTime,
                                 const double beatPosition) {
    
    double transportTimeToNextBeat;
    if (ceil(beatPosition) == beatPosition) {
        transportTimeToNextBeat = 1;
    } else {
        transportTimeToNextBeat = ceil(beatPosition) - beatPosition;
    }
    double samplesToNextBeat = transportTimeToNextBeat * samplesPerBeat(sampleRate, tempo);
    double nextBeatSampleTime = sampleTime + samplesToNextBeat;
    int subticksLeftInBeat = PPQ - subtickPosition(beatPosition);
    return nextBeatSampleTime - (subticksLeftInBeat * samplesPerSubtick(sampleRate, tempo));
}

void scheduleEventsForNextBeat(const double beatPosition) {
    
    double integral;
    modf(beatPosition, &integral);
    int beat = (int)integral;
    if (beat != previousBeat) {
        callback(beat + 1, callbackRefCon);
        previousBeat = beat;
    }
}

void renderTimeline(const AUEventSampleTime now,
                    const double sampleRate,
                    const UInt32 frameCount,
                    const double tempo,
                    const double currentBeatPosition,
                    MIDIPacket *midiData) {
    
    // get MIDI events from FIFO buffer and put in scheduledEvents
    getMidiEventsFromFIFOBuffer();
    
    uint8_t subtickAtBufferBegin = subtickPosition(currentBeatPosition);
    uint8_t subtickOffset = 0;
    // nb: it seems we need to increase the buffer's window size a little
    // bit to account for timing jitter. 128 seems to be a good value.
    for (int64_t outputTimestamp = sampleTimeForNextSubtick(sampleRate, tempo, now, currentBeatPosition);
         outputTimestamp <= (now + frameCount + 128);
         outputTimestamp += samplesPerSubtick(sampleRate, tempo)) {
        
        // wrap beat around if subtick count in current render cycle overflows beat boundaries
        uint8_t beat = floor(currentBeatPosition) + 1;
        if ((subtickAtBufferBegin + subtickOffset) >= PPQ)
            beat += 1;
        
        uint8_t subtick = (subtickAtBufferBegin + subtickOffset) % PPQ;
        
        if (previousSubtick == subtick) {
            // we've already scheduled events for this subtick, continue
            subtickOffset++;
            continue;
        }
        
        if ((subtick - previousSubtick) != 1 && (previousSubtick - subtick) != PPQ - 1) {
            if (subtick - previousSubtick == 0) {
                printf("double subtick at   %d:%d\n", beat, subtick);
            } else {
                int missedSubtickCount = (subtick - previousSubtick) - 1;
                printf("missed %d subticks at %d:%d\n", missedSubtickCount, beat, previousSubtick);
            }
            printf("output timestamp    %lld\n", outputTimestamp);
            printf("buffer end          %lld\n", now + frameCount);
            printf("-------------------------\n");
        }
        
        previousSubtick = subtick;
        
        fireEvents(midiData,
                   beat,
                   subtick);
        
        // timestamp MIDI packets
        for (int i = 0; i < 8; i++) {
            midiData[i].timeStamp = outputTimestamp;
        }
        
        subtickOffset++;
    }
    
    scheduleEventsForNextBeat(currentBeatPosition);
}
