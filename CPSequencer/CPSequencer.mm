//
//  CPSequencer.c
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include "CPSequencer.h"
#include "vector"
#include "TPCircularBuffer.h"

typedef struct PlayingNote {
    int pitch;
    int beat;
    int subtick;
    int channel;
    int dest;
    bool stopped;
} PlayingNote;

TPCircularBuffer fifoBuffer;

// nb: these are owned by the audio thread
int previousSubtick = -1;
int prevQuarter = -1;
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
    event.dest = 0;
    event.queued = true;
    
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

void stopPlayingNotes(MIDIPacket *midi,
                      const int beat,
                      const uint8_t subtick) {
    
    if (playingNotes.size() == 0)
        return;
    
    for (int i = 0; i < playingNotes.size(); i++) {
        
        // check if playing note is due to be stopped
        if (subtick == playingNotes[i].subtick &&
            beat == playingNotes[i].beat &&
            !playingNotes[i].stopped) {
            
            // if so, send note off
            PlayingNote note = playingNotes[i];
            
            // check if destination doesn't have weird value
            if (note.dest < 0 || note.dest > 7)
                note.dest = 0;
            
            int size = midi[note.dest].length;
            midi[note.dest].data[size] = NOTE_OFF + note.channel;
            midi[note.dest].data[size + 1] = note.pitch;
            midi[note.dest].data[size + 2] = 0;
            midi[note.dest].length = size + 3;
            
            playingNotes[i].stopped = true;
        }
    }
    
    // remove playing notes that have stopped
    for (int i = 0; i < playingNotes.size(); i++) {
        if (playingNotes[i].stopped) {
            playingNotes.erase(playingNotes.begin() + i);
        }
    }
}

void addPlayingNoteToMidiData(char status, PlayingNote *note, MIDIPacket *midi) {
    
    int size = midi[note->dest].length;
    midi[note->dest].data[size] = status + note->channel;
    midi[note->dest].data[size + 1] = note->pitch;
    midi[note->dest].data[size + 2] = 0;
    midi[note->dest].length = size + 3;
}

void addEventToMidiData(char status, MIDIEvent *ev, MIDIPacket *midiData) {
    
    int size = midiData[ev->dest].length;
    midiData[ev->dest].data[size] = status + ev->channel;
    midiData[ev->dest].data[size + 1] = ev->data1;
    midiData[ev->dest].data[size + 2] = ev->data2;
    midiData[ev->dest].length = size + 3;
}

void fireEvents(MIDIPacket *midiData,
                const int beat,
                const uint8_t subtick) {
    
    stopPlayingNotes(midiData,
                     beat,
                     subtick);
    
    if (scheduledEvents.size() == 0)
        return;
    
    for (int i = 0; i < scheduledEvents.size(); i++) {
        
        if (subtick == scheduledEvents[i]->subtick &&
            beat == scheduledEvents[i]->beat &&
            scheduledEvents[i]->queued == true) {
            
            MIDIEvent *event = scheduledEvents[i];
            
            // if there's a playing note with same pitch, stop it first
            for (int j = 0; j < playingNotes.size(); j++) {

                if (playingNotes[j].pitch == event->data1 &&
                    !playingNotes[j].stopped) {

                    // if so, send note off
                    PlayingNote note = playingNotes[j];
                    note.stopped = true;
                    addPlayingNoteToMidiData(NOTE_OFF, &note, midiData);
                }
            }

            // schedule note on
            addEventToMidiData(NOTE_ON, event, midiData);
            
            printf("playing     %d:%d\n", event->beat, event->subtick);
            
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
            noteOff.dest = event->dest;
            noteOff.stopped = false;
            playingNotes.push_back(noteOff);
            
            scheduledEvents[i]->queued = false;
        }
    }
    
    // remove scheduled events in the past
    for (int i = 0; i < scheduledEvents.size(); i++) {
        if (scheduledEvents[i]->queued == false) {
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
    
    double beat;
    modf(beatPosition, &beat);
    double quarter = int(floor(beatPosition * 4.0)) % 4;
    if (quarter != prevQuarter) {
        
        int nextBeat = quarter + 1 >= 4 ? beat + 1 : beat;
        int nextQuarter = (((int)quarter + 1) % 4);
        
        callback(nextBeat,
                 nextQuarter,
                 callbackRefCon);
        prevQuarter = quarter;
    }
}

void clearBuffers(MIDIPacket *midi) {
    
    // clear note buffers
    if (scheduledEvents.size() > 0)
        scheduledEvents.clear();
    
    if (playingNotes.size() > 0) {
        // stop playing notes immediately
        for(int i = 0; i < playingNotes.size(); i++) {
            
            PlayingNote note = playingNotes[i];
            int size = midi[note.dest].length;
            midi[note.dest].data[size] = NOTE_OFF + note.channel;
            midi[note.dest].data[size + 1] = note.pitch;
            midi[note.dest].data[size + 2] = 0;
            midi[note.dest].length = size + 3;
        }
        playingNotes.clear();
    }
}

void resetSequencer(const double beatPosition) {
    
    prevQuarter = -1;
    previousSubtick = -1;
    scheduleEventsForNextBeat(0);
//        // stop MIDI clock
}

void renderTimeline(const AUEventSampleTime now,
                    const double sampleRate,
                    const UInt32 frameCount,
                    const double tempo,
                    const double beatPosition,
                    MIDIPacket *midi) {
    
    // get MIDI events from FIFO buffer and put in scheduledEvents
    getMidiEventsFromFIFOBuffer();
    
    uint8_t subtickAtBufferBegin = subtickPosition(beatPosition);
    uint8_t subtickOffset = 0;
    // nb: it seems we need to increase the buffer's window size a little
    // bit to account for timing jitter. 128 seems to be a good value.
    for (int64_t outputTimestamp = sampleTimeForNextSubtick(sampleRate, tempo, now, beatPosition);
         outputTimestamp <= (now + frameCount + 128);
         outputTimestamp += samplesPerSubtick(sampleRate, tempo)) {
        
        // wrap beat around if subtick count in current render cycle overflows beat boundaries
        int beat = floor(beatPosition);
        if (beatPosition < 0) {
            beat = -1;
        } else if ((subtickAtBufferBegin + subtickOffset) >= PPQ)
            beat += 1;
        
        uint8_t subtick = (subtickAtBufferBegin + subtickOffset) % PPQ;
        
        if (previousSubtick == subtick) {
            // we've already scheduled events for this subtick, continue
            subtickOffset++;
            continue;
        }
        
//        if ((subtick - previousSubtick) != 1 && (previousSubtick - subtick) != PPQ - 1) {
//            if (subtick - previousSubtick == 0) {
//                printf("double subtick at   %d:%d\n", beat, subtick);
//            } else {
//                int missedSubtickCount = (subtick - previousSubtick) - 1;
//                printf("missed %d subticks at %d:%d\n", missedSubtickCount, beat, previousSubtick);
//            }
//            printf("output timestamp    %lld\n", outputTimestamp);
//            printf("buffer end          %lld\n", now + frameCount);
//            printf("-------------------------\n");
//        }
        
        previousSubtick = subtick;
        
        fireEvents(midi,
                   beat,
                   subtick);
        
        // timestamp MIDI packets
        for (int i = 0; i < 8; i++) {
            midi[i].timeStamp = outputTimestamp;
        }
        
        subtickOffset++;
    }
    
    scheduleEventsForNextBeat(beatPosition);
}
