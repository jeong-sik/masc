# Focused native profile only

The first, separate 800-transition profile spent 4093 of 4123 main-thread
samples in Iomux poll and cannot rank rendering hot paths. This follow-up
performs one roster cycle and 6000 alternating Info cycles (24006 new expected
frames acknowledged). It removes repeated full-history precondition replay
only after the first checked Info transition. Previous opposite-window ACKs
then establish the precondition. Every input still requires a new expected
window followed by FRAME_END. Sampling ran for five seconds at a requested
1ms interval on the verified owned candidate child; sampler exit was 0.

These timings are perturbed and are NOT comparative latency evidence.
`observation.json` and stdout preserve the original scenario receipt unchanged.
Its inherited session_resources scope is WRONG FOR THIS PROFILE RUNNER:
RUSAGE_CHILDREN includes the reaped sample, pgrep and ps children as well as
the launcher/TUI. Do not attribute its 5.886153 CPU seconds to the TUI or compare
it with the unprofiled comparator CPU. This was found by adversarial review.

The native stack has 4256 main-thread samples, including 1617 in kernel poll;
self samples include String.split_on_char (87), render_prim.collect (54),
theme.go (47), and Unicode/layout helpers. Samples are not exact per-frame
CPU percentages. Inspect repeated footer pin classification and buffer line
splitting as candidates; this does not establish the 25ms CI input's cause.

No product source changed for this profile and no binary was installed.

This profile omits per-input current-screen reconstruction after the first
Info transition. It is not a general regression proof under dynamic screen
changes. The unmodified controlled scenario retains that check.
