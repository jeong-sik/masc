# Overview first-use PTY frames

These PNGs replay actual 80×32 and 140×32 PTY frames from [Test run 36384455321, job 108806799941](https://github.com/jeong-sik/masc/actions/runs/36384455321/job/108806799941). Run head: `81c14def69cbefbf613c672b2e7d557083467d38`. The targeted `test_tui_keyboard_overview_pty` suite passed. Text and cell positions come from the captured frames; DejaVu Sans Mono and monochrome colour are used for this image replay. The linked run's `suite-runner-log` artifact contains the raw ANSI frames as `OVERVIEW_FRAME_*_B64`.

| Briefing state | 80×32 | 140×32 |
| --- | --- | --- |
| Not read yet | [PNG](overview-unread-80x32.png) | [PNG](overview-unread-140x32.png) |
| Read, Keeper 0 | [PNG](overview-empty-80x32.png) | [PNG](overview-empty-140x32.png) |

The unread state says `Overview briefing not read yet` and does not claim the fleet is empty. The read empty state shows `Start here (2 steps)`, the actual create and navigation instructions, and `Approvals: 0?` because that source is unread. At this 32-row height, usage displays four of nine accounts at both widths and explicitly says that five more do not fit.

Raw frame SHA-256, in table order:

- Unread 80×32: `72a01052b9c25ac636522c347aefd53cc236e92726c2dfc7d6ffeb245bd443c0`
- Unread 140×32: `a7fab6dd3fe7c3bc775c1e0d9ac046fd49f5bb831e6d13a77e324d3578a8c8c6`
- Empty 80×32: `4f9a5b6be13875fe5a558b5163a19bd5295e00236e54db32398effa371f72c3f`
- Empty 140×32: `0472dd76764d43fb94f7fbfeb755f714eb9afdd6e8cabf786340ece507c7152b`
