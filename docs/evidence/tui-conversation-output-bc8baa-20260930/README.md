# Conversation output fixture evidence

Test run [36664252263](https://github.com/jeong-sik/masc/actions/runs/36664252263) succeeded for head `bc8baa583b0e86f12387abce8728fdb4d4880c66` before latest-main integration. It ran answering, chat activity, row memo, queue/frame, and Activity pane PTY suites.

`capture.pty` is the scenario's actual terminal capture; `frame.txt` decodes its final recorded frame using the same harness. `frame.png` is a monochrome reconstruction for viewing. The running output appears in the conversation once, beside the queued message; stale polling, empty preview and safe teardown are checked later in the same passing scenario. This is fixture evidence, not a real-provider or production run. The integration head requires its own CI run.
