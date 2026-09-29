# Integrated remote row type failure

Run [36607930676](https://github.com/jeong-sik/masc/actions/runs/36607930676), head `e84d2d9caa4761d03880b5947324bb5d350a7b49`, failed its Test step.

After fixing the metrics error type, compilation reached an unbound `k_origin` record field in the remote chat gate callback at `bin/masc_tui.ml:26082`. Five TUI aliases failed before running and the executable build then aborted. Quiz23 and collector4 passed. The47 selected suites did not all run.

The fix gives the callback argument its actual `Tui_decode.keeper` type. Parser checks and source reviews did not detect this type error; native feature evidence remains pending. The compressed raw log is complete.
