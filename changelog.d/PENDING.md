### Fixed

- Restoring MIDI state for a seek, a resume or each copy of a region cut late
  in a source no longer resends the whole controller history. A write that a
  later write of the same field replaces is dropped unless a kept message
  reads it: a Program Change keeps the bank it applied, a Data Entry its
  parameter selection, and a sounding MIDI 2.0 Note On, Program Change or
  Detach the values it keeps. A prefix of 1,000 CC11 and 1,000 pitch bend
  messages now restores as one of each, so the boundary Note On is the third
  message instead of the 2,001st; a take's channel pressure stream restores as
  one message. Relative Data Increment/Decrement and MIDI 2.0 relative parameter
  steps are still resent with the absolute values they adjust (#44072,
  #PENDING).
