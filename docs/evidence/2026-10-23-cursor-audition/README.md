# Cursor audition

`p` / `:play-cursor` prepares a temporary cursor-to-range-end window. Saved loop locators and editor history remain unchanged; native repeat follows the existing loop switch. MIDI output uses its existing state reconstruction. Imported VST/FluidSynth audio retains the complete source render and plays its selected PCM window. SMF2 retains explicit pattern selection and SMPTE retains the source clock.

The private installed auxiliary TUI prepared 54.3 seconds from beat 9.5 of a 100-beat, 100 BPM document. The rendered WAV had 2,394,630 stereo frames at 44,100 Hz, all finite; its peak was 0.08267092704772949. The native output child was observed on BlackHole and was gone after stop. The copied project and user original remained byte-identical. This does not measure received audio, acoustics, physical MIDI, or the user's Ghostty display. Raw captures and the user's music remain private.

The focused checks cover actual Worker MIDI/VST/FluidSynth plans; sustained voices across tracks; PPQ1001 and SMPTE SMF1/2; missing patterns; invalid windows; generation cancellation; seek/pause/restart; instrument selection and capture cancellation. See receipt.json for files and runtime identity. These are focused checks, not the full regression suite or Release/Tag validation.

Independent review found the first cursor audition lost its start through instrument selection. The repair carries the requested cursor through picker admission and owned capture, and retires it on dismissal/stop. Review also noticed missing starting-state window metadata: the real player's readiness gate already rejects pre-ack seeks, so no incorrect native seek was demonstrated. Starting metadata is now complete; an actual playback module probe confirms no pre-ack write and correct relative seek after acknowledgement.

Design reference: Ardour distinguishes play from edit point and loop-range playback in its [Transport menu](https://manual.ardour.org/ardours-interface/main-menu/Transport-menu/). MASC keeps its saved loop locators intact when auditioning from the cursor.
