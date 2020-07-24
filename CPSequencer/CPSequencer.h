//
//  CPSequencer.h
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include <AudioToolbox/AudioToolbox.h>

#define NOTE_ON             0x90
#define NOTE_OFF            0x80
#define CC                  0xB0
#define PITCH_BEND          0xE0
#define PROGRAM_CHANGE      0xE0
#define MIDI_CLOCK          0xF8
#define MIDI_CLOCK_START    0xFA
#define MIDI_CLOCK_CONTINUE 0xFA
#define MIDI_CLOCK_STOP     0xFC
#define PPQ                 96
#define NOTE_CAPACITY       256
#define BUFFER_LENGTH       16384

typedef struct MIDIEvent {
    int beat;
    int subtick;
    uint8_t status;
    uint8_t data1;
    uint8_t data2;
    int duration;   // only relevant for note events
    int dest;
    int channel;
    bool queued;
} MIDIEvent;

typedef void (*callback_t)(const int beat,
                           const int quarter,
                           void * __nullable refCon);

void CPSequencerInit(callback_t __nullable cb, void * __nullable refCon);
void addMidiEvent(MIDIEvent event);
void clearBuffers(MIDIPacket * _Nonnull midiData);
void resetSequencer(const double beatPosition);

void renderTimeline(const AUEventSampleTime now,
                    const double sampleRate,
                    const UInt32 frameCount,
                    const double tempo,
                    const double currentBeatPosition,
                    MIDIPacket * _Nonnull midiData);
