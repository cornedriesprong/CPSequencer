//
//  CPSequencer.c
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include "CPSequencer.h"

CPSequencer::CPSequencer(callback_t __nullable cb, void * __nullable refCon) {
    
    callback = cb;
    callbackRefCon = refCon;
    scheduledEvents.reserve(NOTE_CAPACITY);
    playingNotes.reserve(NOTE_CAPACITY);
    TPCircularBufferInit(&fifoBuffer, BUFFER_LENGTH);
}

void CPSequencer::setMIDIClockOn(bool isOn) {
    MIDIClockOn = isOn;
}

void CPSequencer::addMidiEvent(MIDIEvent event) {
    
    uint32_t availableBytes = 0;
    MIDIEvent *head = (MIDIEvent *)TPCircularBufferHead(&fifoBuffer, &availableBytes);
    head = &event;
    TPCircularBufferProduceBytes(&fifoBuffer, head, sizeof(MIDIEvent));
}

void CPSequencer::getMidiEventsFromFIFOBuffer() {
    
    uint32_t bytes = -1;
    while (bytes != 0) {
        MIDIEvent *event = (MIDIEvent *)TPCircularBufferTail(&fifoBuffer, &bytes);
        if (event) {
            scheduledEvents.push_back(event);
            TPCircularBufferConsume(&fifoBuffer, sizeof(MIDIEvent));
        }
    }
}

void CPSequencer::stopPlayingNotes(MIDIPacket *midi, const int beat, const uint8_t subtick) {
    
    
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

void CPSequencer::addPlayingNoteToMidiData(char status, PlayingNote *note, MIDIPacket *midi) {
    
    int size = midi[note->dest].length;
    midi[note->dest].data[size] = status + note->channel;
    midi[note->dest].data[size + 1] = note->pitch;
    midi[note->dest].data[size + 2] = 0;
    midi[note->dest].length = size + 3;
}

void CPSequencer::addEventToMidiData(char status, MIDIEvent *ev, MIDIPacket *midiData) {
    
    int size = midiData[ev->dest].length;
    midiData[ev->dest].data[size] = status + ev->channel;
    midiData[ev->dest].data[size + 1] = ev->data1;
    midiData[ev->dest].data[size + 2] = ev->data2;
    midiData[ev->dest].length = size + 3;
}

void CPSequencer::scheduleMIDIClock(uint8_t subtick, MIDIPacket *midi) {
    
    if (subtick % (PPQ / 24) == 0) {
        if (sendMIDIClockStart) {
            for (int i = 0; i < 8; i++) {
                midi[i].data[0] = MIDI_CLOCK_START;
                midi[i].length++;
            }
            sendMIDIClockStart = false;
        } else {
            for (int i = 0; i < 8; i++) {
                midi[i].data[0] = MIDI_CLOCK;
                midi[i].length++;
            }
        }
    }
}

void CPSequencer::fireEvents(MIDIPacket *midi,
                             const int beat,
                             const uint8_t subtick) {
    
    stopPlayingNotes(midi,
                     beat,
                     subtick);
    
    if (scheduledEvents.size() == 0)
        return;
    
    for (int i = 0; i < scheduledEvents.size(); i++) {
        
        if (subtick == scheduledEvents[i]->subtick &&
            beat == scheduledEvents[i]->beat &&
            scheduledEvents[i]->queued == true) {
            
            MIDIEvent *ev = scheduledEvents[i];
            
            switch (ev->status) {
                case NOTE_ON: {
                    // if there's a playing note with same pitch, stop it first
                    for (int j = 0; j < playingNotes.size(); j++) {
                        if (playingNotes[j].pitch == ev->data1 &&
                            !playingNotes[j].stopped) {
                            
                            // if so, send note off
                            PlayingNote *note = &playingNotes[j];
                            note->stopped = true;
                            addPlayingNoteToMidiData(NOTE_OFF, note, midi);
                        }
                    }
                    
                    addEventToMidiData(NOTE_ON, ev, midi);
                    
                    // schedule note off
                    PlayingNote noteOff;
                    noteOff.pitch = ev->data1;
                    
                    int currentBeat;
                    if (subtick + ev->duration >= PPQ) {
                        currentBeat = beat + (int)floor((ev->duration + subtick) / (double)PPQ);
                    } else {
                        currentBeat = beat;
                    }
                    noteOff.beat    = currentBeat;
                    noteOff.subtick = (subtick + ev->duration) % PPQ;
                    noteOff.channel = ev->channel;
                    noteOff.dest    = ev->dest;
                    noteOff.stopped = false;
                    playingNotes.push_back(noteOff);
                    
                    break;
                }
                case CC: {
                    addEventToMidiData(CC, ev, midi);
                    break;
                }
                case PITCH_BEND: {
                    addEventToMidiData(PITCH_BEND, ev, midi);
                    break;
                }
            }
            
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

void CPSequencer::scheduleEventsForNextSegment(const double beatPosition) {
    
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

void CPSequencer::clearBuffers(MIDIPacket midiData[MIDI_PACKET_SIZE][8]) {
    
    // clear fifo buffer
    TPCircularBufferClear(&fifoBuffer);
    
    // clear note buffers
    if (scheduledEvents.size() > 0)
        scheduledEvents.clear();
    
    if (playingNotes.size() > 0) {
        // stop playing notes immediately
        for (int i = 0; i < playingNotes.size(); i++) {
            PlayingNote *note = &playingNotes[i];
            addPlayingNoteToMidiData(NOTE_OFF, note, midiData[note->dest]);
        }
        playingNotes.clear();
    }
    
    // stop MIDI clock
    if (MIDIClockOn) {
        for (int i = 0; i < 4; i++) {
            for (int j = 0; j < 8; j++) {
                midiData[i][j].data[0] = MIDI_CLOCK_STOP;
                midiData[i][j].length++;
            }
        }
    }
    
    sendMIDIClockStart = true;
}

void CPSequencer::stopSequencer() {
    prevQuarter = -1;
}

void CPSequencer::renderTimeline(const AUEventSampleTime now,
                                 const double sampleRate,
                                 const UInt32 frameCount,
                                 const double tempo,
                                 const double beatPosition,
                                 MIDIPacket midiData[MIDI_PACKET_SIZE][8]) {
    
    // get MIDI events from FIFO buffer and put in scheduledEvents
    getMidiEventsFromFIFOBuffer();
    
    uint8_t subtickAtBufferBegin = subtickPosition(beatPosition);
    uint8_t subtickOffset = 0;
    // nb: it seems we need to increase the buffer's window size a little
    // bit to account for timing jitter. 128 seems to be a good value.

    for (int64_t outputTimestamp = sampleTimeForNextSubtick(sampleRate, tempo, now, beatPosition);
         outputTimestamp <= (now + (frameCount));
         outputTimestamp += samplesPerSubtick(sampleRate, tempo)) {
        
        // wrap beat around if subtick count in current render cycle overflows beat boundaries
        int beat = floor(beatPosition);
        if (beatPosition < 0) {
            beat = -1;
        } else if ((subtickAtBufferBegin + subtickOffset) >= PPQ) {
            beat += 1;
        }
        
        uint8_t subtick = (subtickAtBufferBegin + subtickOffset) % PPQ;
        
        previousSubtick = subtick;
        
        if (MIDIClockOn) {
            scheduleMIDIClock(subtick, midiData[subtickOffset]);
        }
        
        fireEvents(midiData[subtickOffset],
                   beat,
                   subtick);
        
        for (int i = 0; i < 8; i++) {
            midiData[subtickOffset][i].timeStamp = outputTimestamp;
        }
        
        subtickOffset++;
    }
    
    scheduleEventsForNextSegment(beatPosition);
}
