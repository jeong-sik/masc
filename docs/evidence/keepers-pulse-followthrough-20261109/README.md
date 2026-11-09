# Keeper Pulse: follow-through observations

The implementation reference is the user-supplied Keeper Pulse Markdown, pasted text and screenshot. The remote artifact page was unavailable to the read tool. This is a manual terminal comparison, not a pixel similarity score or an automated UI assertion suite.

## Source boundaries

- Native frames: frozen `677fe1e84dfee7b5cd9d7c2f1560a9898684bb16` (source tree `f288d2f351175c2aeb47ff882af396e85f73011b`), before the later lower-stack header fixes and ordinary-absence implementation.
- Current follow-through: #50669 `16424935d0d9cddba3a38f6e76fcce3d40350c28`.
- Ordinary absence: #50680 `a96ec36efb3f7d3248f0d4e85d07644f08a1a2f4`. These native frames do not execute that later change; their `? absent` is the old implementation.

The later integration preserves the reviewed implementation and removes rendered-string/layout assertions added by another stack update. Source review, compiler/type checks, focused tests and the older native frames are distinct evidence.

## Native setup and limits

[Manual probe artifacts run 42620614284](https://github.com/jeong-sik/masc/actions/runs/42620614284) completed with `success`, driver head `3d1271ef26b82b604b8f88dd6c126947ee4578bd`, ref `main`, attempt 1, candidate input `677fe1e84dfee7b5cd9d7c2f1560a9898684bb16`. ZIP artifact 13677536296 is 186655616 bytes, SHA256 `652b244a66753ed44fb0e5e1e8d7cf5727a995137d599564b768f8806ae58a3b`. All 14 file digests, probe/tree/driver/run/attempt, packaged provenance and both staged embedded build commits were checked. The native pair was staged privately without installation.

A new private base contained only canonical synthetic store inputs: three Keepers, 70 ordinary facts and two measured-zero snapshots; Ledger 2 claims / 0 conflicts / 3 classified / 1 excluded. Native code computed the memory bins and pending Briefing building 2/2. No schedule or stale/digest success was fabricated. Autonomy/reactive/bootstrap were disabled, the only fixture model endpoint was a closed loopback port, and ambient provider credentials were excluded. The server's HTTP private roots were checked. Default HTTPS binding failed because its port was already occupied; this observation covers HTTP only.

The terminal proxy passed native GET responses through and blocked every mutation. Only the deliberate memory-health fault closed a connection without contacting upstream or writing any HTTP status/body. The later R key tested the real failed-read path; Plain entry had no preceding R. Published frames and bodies are sanitized derivatives. Their own hashes are recorded separately from native wire hashes.

The first controller failed with ENOTTY before useful frames. The second retained a startup diagnostic requiring an interactive TTY and a non-dumb TERM; the capture environment had retained `TERM=dumb`. Neither was a product success. The third 120-column controller explicitly used `TERM=xterm-256color`. Original local failure records were retained. No full 48-view matrix, provider recovery, production fleet behavior, installation, deployment or full regression result is claimed here.

## Manual reading

The selected frames retain actual panel ownership and clipping. A label requested by the capture controller alone is not proof of which panel opened. See observation.json for timestamps, native response receipts, relevant manual actions, frame digests, controller exit and preference observations.

| Observation | 120×35 | 80×24 |
| --- | --- | --- |
| Plain entry using `3` without R | Native Memory GET 200/body completed | Native Memory GET 200/body completed |
| Age | 24 bins; positive ladder and two measured-zero rows | Adjacent bins merged to 12; same zero rows |
| World using `W` | Keepers → Ledger → Briefing; building details | All three core stages; secondary details clipped |
| Deliberate Memory transport failure | Actual Story Caution and held 70-fact observation | Caution retained with past/now/next; reason clips at right edge |

The source/header fixes are compared with the user reference by meaning, not by exact prototype wording. The World strip is intentionally still `? absent` in this older native pair. The later ordinary-absence source has separate strict decoder and real native-store roundtrip tests.

At 2026-11-09 13:28:43 UTC the owned private native process was absent after SIGTERM; its pane exit status was observed as 0. No SIGKILL was sent. Each controller reported exit 0, but individual TUI child exit status was not separately retained. The private-base and live preference bytes were unchanged during both captures; no preference restoration was performed.

## Focused verification

[Test run 42625266384](https://github.com/jeong-sik/masc/actions/runs/42625266384), head `a96ec36efb3f7d3248f0d4e85d07644f08a1a2f4`, ref `feat/keepers-world-absence`, conclusion `success`: TARGET_SUITES=`test_workspace_memory_ledger,test_workspace_memory_ledger_view,test_tui_decode_workspace_memory,test_tui_memory_world,test_tui_keeper_axis`, minimal=true. The five suites passed 18 / 7 / 7 / 6 / 5 tests (43 total). This is focused verification, not full regression.

PR type-check (dune build @check), run 42625243301, uses that same head/ref. Its final observed conclusion is `success`. The earlier `677fe1e` type/key/Story successes remain attached to that earlier source.

[cleanup.json](cleanup.json) records the final dedicated tmux check (`no server running`), stale owned socket removal and absent transport-fault flag.

A concurrent session subsequently began rebasing the lower G4 layer onto newer main. This evidence remains frozen to the named 677fe1e native pair and a96ec36 focused/type checks; later main/rebase heads do not inherit these execution verdicts. No new main scope is certified by this record.
