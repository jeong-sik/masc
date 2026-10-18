### Added
- Native captured-take playback pauses/resumes with `p` and seeks WAV and MIDI together with `:seek SECONDS`, reconstructing live keys, sustain/sostenuto, ordered channel and per-note expression, program/bank state and original note attributes/releases when source baselines are known. (#43816)

### Fixed
- Delayed seek callbacks skip expired notes, including callbacks past the source end. Reconstruction diagnoses unknown initial values, opaque effects and one-shot Portamento Control instead of inventing state or replaying consumed effects; full-source UMP audition remains available. (#43816)
