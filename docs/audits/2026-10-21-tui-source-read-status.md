# Keeper detail progress belongs to the original source

| Source | As-Is | To-Be |
| --- | --- | --- |
| Info execution without snapshot/error | Always loading | Read only while Keeper lanes is in flight; otherwise unobserved |
| Info/Secrets retained lanes during refresh | Pending hidden behind values | Original lanes progress and last observation |
| Secrets retained projection after lanes failure | Prior projection could hide the new error | Actual failure beside retained projection |
| Secrets without lanes/error/request | Detail loading without an owning tab request | Unobserved; never borrow another detail clock |
| Channels without value/error | Extra generic loading even when idle, held or not started | Quiet is unobserved; existing typed status/names/recheck/start-failure notice owns progress |
| Automation without matching snapshot/error/request | Generic loading | Unobserved |
| Automation retained snapshot during request | Pending hidden | Original Keeper schedule request interval plus last observation |
| Item account without value/error/request | Always loading | Unobserved unless this Keeper's Item request exists |

The original producers are distinct. Keeper lanes has one current in-flight flag
and authority-checked completion for execution and Secrets. Channels uses
`Connector_read`: status and names, held after-write demand and failed start are
different states. Its existing source notice already renders those stages; no
second loading row is invented. Automation and Item use original tab/Keeper
request entries. Container logs, standalone lanes and unrelated tab requests
cannot establish their pending status. No timeout or elapsed-time inference is
added. A request entry/flag proves scheduling, not physical I/O start or progress.

Only renderer decisions change. Existing launch-time clearing, source values,
failure retention, request generations, workspace withdrawal and completion
admission remain. Known empty schedules keep their original store/page-capped
absence classification; missing/foreign snapshots never establish emptiness.
The transport table, actual secret projection and Item preview/eligibility
remain original. No new request, retry, pending slot, cache, timer, effect or
authority is added. Extra work is current request lookup and notice construction
on the visible frame; retained Secrets now format alongside a failed refresh.
Added rows remain in the existing all_lines/Info field scroll accounting.

This is an unexecuted source-state comparison. No wording/layout/row/snapshot/
PTY test is added. One changed OCaml renderer receives parsing only. Original
launch/completion/authority sources and data projection/classification bodies
are compared with the parent. No typing, warning/link/build/behavior test, CI,
TUI/controller/native/model run, install/restart/live write, independent approval
or merge is established. Actual screen/scroll/input interaction, source failures
and matched Before/After remain unmeasured. The change does not establish the
root cause or speed of the reported persistent TUI Loading.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend continuation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts. Source display honesty is not
logical work completion, effect success, physical cleanup or paint evidence.
