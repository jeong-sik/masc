# SMF, captured MIDI2 and WAV together

Ordinary arrangement Space playback combines every audible SMF, captured MIDI2/WAV
and ordinary WAV region under one native host clock. Select `:mixed-output AUDIO_UID`
and `:midi-output MIDI_UID`. SMF assets can override source ports with
`:midi-port ASSET PORT MIDI_UID`; captures can override original inputs with
`:midi-source ASSET SOURCE_ID MIDI_UID`. Mute/solo determines the audible schedule;
preparation never drops a source merely because another source kind is present.

The IO worker owns one private playback root. Each captured source's manifest,
WAV, audio-block clock and UMP log are verified and copied once. Original SMF
source bytes and decoded timelines remain retained in the project. Region records
retain native trims and compressed finite repeats. Schema6 `hybrid-arrangement`
contains the paired WAV/UMP plan and a schema3 SMF region timeline, with a single
duration shared by both. Captures with no MIDI retain clock-only regions.

`HybridMidiTransport` admits both real engines before acquiring outputs. It owns
preparation, silent staging, one future epoch, either-order completion and failure
cleanup. Both MIDI engines and every audio voice must finish, including a silent
arrangement horizon. A second-engine failure stops and drains the first. The
captured engine stages first, so its refused reconstruction leaves both engines
unchanged and the pause, resume or seek is refused without ending playback. Pause,
forward/backward seek, output changes, editing and exit preserve that ownership.
Each protocol engine retains its original expressive state model and uncertainty
accounting; no MIDI2 words are converted to MIDI1.

Hybrid SMF channel messages are framed losslessly as MIDI1 UMP with explicit group
zero using [CoreMIDI event lists](https://developer.apple.com/documentation/coremidi/midisendeventlist(_:_:_:)).
The channel and data bytes retain their original values; selected destination
native delivery is CoreMIDI's responsibility. This does not promote SMF velocities
or invent MIDI2 attributes. The selected output's declared active-group bitmap,
when present, must include group zero. Raw captured UMP still requires a pinned
native MIDI2 endpoint. Existing standalone SMF audition retains its byte-stream
transport. Unsupported SMF region system state remains an explicit diagnostic.

A physical state scope is destination UID, UMP group and channel, including
restored prefix state. Different groups/channels may share a destination. The two
engines cannot reconstruct each other's prior state on the same physical channel,
even across sequential clips; those scopes require independent channels, groups
or outputs. This prevents one engine's pedal/key cleanup and state chase from
changing the other's voices. Existing source-specific baseline and opaque-state
admission also applies. No controller defaults are fabricated.

Playback bindings carry a stable ordinal plus destination and stream protocol:
SMF protocol1 first, captured protocol2 second. One endpoint can occur in both
stream roles; duplicates within one role are consolidated. The JS bridge verifies
every binding/protocol, audio output and common-clock acknowledgement. A protocol
substitution fails and drains the child. Complete native closure precedes private
source deletion. Protocol tags describe the submitted stream; raw UMP additionally
pins the endpoint's native protocol. No endpoint setting is changed by playback.

Monitored recording/overdub, latency compensation, practice/count-in, external
clock, selected VST project integration, whole-arrangement looping and physical,
visible Ghostty and acoustic verification remain separate sequencer work.
