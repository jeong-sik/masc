# TUI input frame timing, 2026-09-24

`baseline.txt` is the raw successful output of `python3 test/test_tui_input_frame_pty.py /path/to/installed/masc-tui`. It records installed binary and scenario SHA-256, input bytes and ten complete expected-frame observations. This is the installed baseline, not the proposed implementation. Its source revision was not independently established.

Each input is sent immediately after the preceding expected frame, without a settling sleep. The target must differ from the previously completed screen; timing ends at FRAME_END after that target arrives. Unrelated background output alone cannot acknowledge a transition. The observer includes PTY/Python overhead and does not measure physical display latency. This fixture uses a temporary server and data store, not the live runtime's Keeper data.

Nine recent-frame observations took 14.746333–23.421417ms. One first detail-scroll observation took 1.315417ms. All arrow, wheel, page and detail scroll transitions passed. The full draft burst also survived byte-for-byte without submitting a message. These are ten observations, not a percentile acceptance claim.

The scheduler previously held Input to its 16ms frame interval unless a background request happened to be pending. The change renders the leading input as soon as the terminal buffer and terminal-probe replay queue drain; later input frames, background updates and continuously buffered input keep the 16ms interval. A partial UTF-8 scalar alone does not count as queued actionable input.

Validation added: deterministic recent-frame/buffer-drain/continuous-burst schedules, terminal-probe replay drain behavior, main-loop wiring, and this PTY scenario. Local formatting, Python syntax, diff checks and installed-baseline PTY pass; candidate compile/execution belong to CI. An independent reviewer found the omitted replay queue, which was corrected and covered. The broader 0.1ms TUI/server/scroll objective remains unachieved.

The initial measurement draft used the general polling helper, which waits after reading a matching frame and inflated observations by roughly 100ms. The retained scenario checks for the completed frame before waiting for another byte. Only the final observer's output is retained here.
