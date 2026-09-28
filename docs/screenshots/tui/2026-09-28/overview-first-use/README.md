# Overview first-use PTY frames

These PNGs replay actual 80×32 and 140×32 PTY frames from [Test run 36397563003, job 108847477371](https://github.com/jeong-sik/masc/actions/runs/36397563003/job/108847477371). Run head: `d918ff6c2b955646050df6c560b00a44986ccfec`. The targeted `test_tui_keyboard_overview_pty` suite passed. Text and cell positions come from the captured frames; DejaVu Sans Mono and monochrome colour are used for this image replay. The linked run's `suite-runner-log` artifact contains the raw ANSI frames as `OVERVIEW_FRAME_*_B64`.

| Briefing state | 80×32 | 140×32 |
| --- | --- | --- |
| Not read yet | [PNG](overview-unread-80x32.png) | [PNG](overview-unread-140x32.png) |
| Read, Keeper 0 | [PNG](overview-empty-80x32.png) | [PNG](overview-empty-140x32.png) |

The unread state says `Overview briefing not read yet`, has no `Attention (0)`, and does not claim the fleet is empty. The read empty state shows `Start here (2 steps)`, a create command using the TUI's loopback peer and the port shown in its footer, and `Approvals: 0?` because that source is unread. Its empty Goals verdict shares the guaranteed first row. At this 32-row height, usage displays six of nine accounts at both widths and explicitly says that three more do not fit.

Raw frame SHA-256, in table order:

- Unread 80×32: `1cac05c38ffd10574ba60e2bd9da78d05690429c7856b7681be47e93d14853c1`
- Unread 140×32: `1e4dab82adb753731ee0c4117287d62210eb46c04e2d476e8bcb8c1720eb452c`
- Empty 80×32: `31fdaa749da2255c5fd7a5d53dabd3ee196d515317cca38d7647a5657b141714`
- Empty 140×32: `5c81373d37048236ecb224d64146357bd80bca23f1a6d852f3a01bff5b507ef3`
