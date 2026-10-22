# Actual Curator host failure and intake evidence

This is a failing integration observation of native source `1196e280ee8b1b5d2381a59210fa51246affe76e`, not execution proof for the subsequent repair.

The matching native server and TUI came from run [39717901525](https://github.com/jeong-sik/masc/actions/runs/39717901525): its two selected suites passed 29 cases. The separate 14-suite run [39717776023](https://github.com/jeong-sik/masc/actions/runs/39717776023) failed four production-owner cases (2, 3, 11, 12); 1005/1009 passed. That run remains FAIL.

A real private Keeper attempted the configured Ollama provider and received its weekly-quota HTTP429. After an explicit private route change, GLM executed the original memory-write tool once. Candidate `memory-admission-4b846287b1db9d8e4b0251c0ee400ce5` was later admitted by the real Librarian into current revision1 with one fact and acknowledged. No Current snapshot, ledger, model answer or observation receipt was injected.

The normal host then logged `Eio_guard.Non_eio_mutex_context(0)` while trying to process those facts. Source tracing finds an Eio registry-metadata mutex in `Prompt_registry.render_resolved_prompt_template`, which both request preparation and strict capture restore call from system threads. The fixture had not enabled runtime mutex guards. This is a distinct reproduced product failure; it is not established as the cause of the four Linux fixture timeouts.

The repair makes already-resolved rendering pure, observes metadata drift during live resolution, enables the real guard in the production fixture, and uses an atomic idle checkpoint subscription with cancellation cleanup for its existing30s observation budget. Source and syntax checks are separate from pending compiled execution. The original13 production assertions remain, with2 narrow idle/cancellation cases added.

`dashboard-before-on.png` is a real Ego Chromium screenshot of the actual server-backed Dashboard. `tui-lanes-before-on.txt` contains actual native PTY cells, without layout assertions; it is not a desktop screenshot. Both show the same private workspace before Curator activation. On/Off domain completion, original Curator receipts, repaired native host, reconnect, and operator installation remain unproved here. Raw private source logs remain outside the repository; the public failure excerpt is unchanged lines. Other capture files are byte-identical and hashed in `receipt.json`.
