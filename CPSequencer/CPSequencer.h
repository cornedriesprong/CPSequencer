//
//  CPSequencer.h
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#include <AudioToolbox/AudioToolbox.h>
#include <os/lock.h>
#include "TPCircularBuffer.h"
#include "vector"

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

typedef struct PlayingNote {
    int pitch;
    int beat;
    int subtick;
    int channel;
    int dest;
    bool stopped;
} PlayingNote;

typedef void (*callback_t)(const int beat,
                           const int quarter,
                           void * __nullable refCon);

class CPSequencer {
private:
    TPCircularBuffer fifoBuffer;
    struct os_unfair_lock_s lock;
    
    // nb: these are owned by the audio thread
    int previousSubtick = -1;
    int prevQuarter = -1;
    callback_t callback;
    void *callbackRefCon;
    std::vector<MIDIEvent*> scheduledEvents;
    std::vector<PlayingNote> playingNotes;
    bool sendMIDIClockStart = true;
    
    // shared variable, only access via trylock
    bool MIDIClockOn = false;
    
    void getMidiEventsFromFIFOBuffer();
    void stopPlayingNotes(MIDIPacket * _Nonnull midi, const int beat, const uint8_t subtick);
    void addPlayingNoteToMidiData(char status, PlayingNote * _Nonnull note, MIDIPacket * _Nonnull midi);
    void addEventToMidiData(char status, MIDIEvent * _Nonnull ev, MIDIPacket * _Nonnull midiData);
    void scheduleMIDIClock(uint8_t subtick, MIDIPacket * _Nonnull midi);
    void fireEvents(MIDIPacket * _Nonnull midi, const int beat, const uint8_t subtick);
    void scheduleEventsForNextBeat(const double beatPosition);
    
public:
    CPSequencer(callback_t __nullable cb, void * __nullable refCon);
    void addMidiEvent(MIDIEvent event);
    void clearBuffers(MIDIPacket * _Nonnull midiData);
    void stopSequencer();
    void setMIDIClockOn(bool isOn);
    
    void renderTimeline(const AUEventSampleTime now,
                        const double sampleRate,
                        const UInt32 frameCount,
                        const double tempo,
                        const double currentBeatPosition,
                        MIDIPacket * _Nonnull midiData);
};

