# Terminal state with unavailable end clock

`of_log` can retain a terminal phase with ended_at unavailable when replay clocks are incomplete. `elapsed_text` previously treated every absent ended_at as a live age, so the settled turn kept getting older whenever the pane refreshed. Terminal lifecycle truth was ignored in the timing decision.

When ended_at is absent, request live age only in Waiting/Working. Stream_ended/Stream_failed return no duration. Preserve the existing span calculation for an observed end clock. No synthetic end timestamp, timeout or age threshold was added.

Actual complete parent/current elapsed_text was interpreted with minimal phase/record types. Formatting calls were replaced by counting sinks returning sentinel strings; this measures which timing computation is requested, not formatting output. Parent failed `terminal turn kept aging without an observed end clock`. Current passed both terminal variants at two observation times, no terminal live-age requests, both active variants requesting age, and known terminal span selection. Artifacts `/tmp/masc-terminal-age-without-clock-20261012/{parent,current}.{ml,log}`.

Source syntax-only parsing and git diff --check passed. No wording/layout/timer-label test was added. Replay still uses its existing policy for incomplete event clocks; preserving individually known terminal clocks and distinguishing receipt/observation time require separate work. Full replay/typecheck/build/CI/runtime/installation/screenshots/formal approval/merge are not established.
