# Overview first-use PTY frames

These PNGs replay actual 80×32 and 140×32 PTY frames from [Test run 36375142759, job 108779332096](https://github.com/jeong-sik/masc/actions/runs/36375142759/job/108779332096). Run head: `7c1e432e7d2e1fcb32e7950f95f1777082a6cfcb`. The targeted `test_tui_keyboard_overview_pty` suite passed. Text and cell positions come from the captured frames; DejaVu Sans Mono and monochrome colour are used for this image replay. The linked run log contains the raw ANSI frames as `OVERVIEW_FRAME_*_B64`.

| Briefing state | 80×32 | 140×32 |
| --- | --- | --- |
| Not read yet | [PNG](overview-unread-80x32.png) | [PNG](overview-unread-140x32.png) |
| Read, Keeper 0 | [PNG](overview-empty-80x32.png) | [PNG](overview-empty-140x32.png) |

The unread state says `Overview briefing not read yet` and does not claim the fleet is empty. The read empty state shows `Start here (2 steps)`, the actual create and navigation instructions, and `Approvals: 0?` because that source is unread. At this 32-row height, usage displays six of nine accounts at both widths and explicitly says that three more do not fit.

Raw frame SHA-256, in table order:

- Unread 80×32: `44ec86f87328bba11433ece8bd092fc237abef242f70765a34aead19ac42a547`
- Unread 140×32: `76fef2a5e727714b43eb40c3f5847a00e74e63012268110587b6d6e7c179200d`
- Empty 80×32: `40fbdb5d11d70dc98eda5b955af89113256883660a2772ba4d0f5a868181c61c`
- Empty 140×32: `c2602abba25b0d6a79370eb83258a62f3d287c3a3a91dd7ed031fd1689a5455c`
