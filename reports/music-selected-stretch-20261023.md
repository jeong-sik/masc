# Selected passage time scaling

Source baseline: `9690424499654c099d15329006d35a0e8b46bee5`.
Implementation reviewed: `8acd5ed35157e5128da9b9459ccda65378baf658`.

`:stretch-notes RATIO [ANCHOR]` scales selected attack distances and note lengths
using exact integer arithmetic. One undo restores the passage. The default
anchor is the selection origin; an explicit anchor uses the document clock.

Focused Node execution passed 43 cases across eight selected files, including
eight new stretch cases. They exercise phrase and imported PPQ1001/SMPTE
documents, both independent SMF2 patterns, native release form and velocity,
unselected expression/routing, exact ratios, invalid transactions and key overlap.
The selected files are `selected-stretch`, `selected-duration`, `note-selection`,
`exact-position`, `timing-unclosed-attacks`, `track-quantize`, `source-timing-index`
and `source-patch-index` under `tools/alphatex/test/`, each with `.test.mjs`.

The actual source TUI was driven in private terminals for both a twelve-note
voice-led phrase and a PPQ1001 source with expression and two tracks. The journey
selected notes, copied them, stretched by two, undid/redid, saved JSON and MIDI,
exported track harmony and saved an arrangement made from the edited document.
Decoded files confirmed the intended native attacks/releases, matching exported
MIDI and harmony intervals, and an editable arrangement asset equal to the draft.
Only requests and persisted musical state were checked; no screen layout or
wording assertion was used. A fixture preparation failure was corrected before
the source-MIDI journey was rerun successfully.

These are selected checks and source-TUI evidence. The new stretch feature has
not been installed into the default viewer or exercised through physical MIDI
hardware, simultaneous audio input, or an audible output during this unit.
No OCaml/Swift build, full regression or CI run is claimed.
