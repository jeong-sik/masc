# Remaining Ego process-state gap

The original Ego Lite 0.6.0.20 experiment found JavaScript-dialog state in the SDK
process. MASC's persistent Node session is a measured workaround, separate
from the native locator/input/wait functionality now delegated to Ego.

The [0.6.1.11 follow-up](0.6.1.11/) repeats the controlled two-process observation
after the installed CLI advanced. It supports retaining the serial session;
it does not relabel earlier MASC/Keeper runs as new-version execution.

## Original .20 same-space observation

The guardian opened a confirm in an owned fixture on existing task space 4,
page p1, and stayed alive as recovery. A second SDK process acquired space 4
but stopped progressing at page.info(). About twelve seconds later the
guardian dismissed the confirm; the same observer then returned, and its
own dismissDialog() returned false. Both processes exited code 0. The final
space remained agent-owned with no open dialog. No new space, handoff or
finish was used. This does not test the original opener exiting while its
dialog remains open: that unsafe recovery case was deliberately not induced.

[proof.json](proof.json), exact guardian/observer inputs, fixture and stdout
record this experiment. This proves current process-state asymmetry; it does
not prove installed MASC, the new host path or an autonomous Keeper task.
The upstream requirement is pinned at
https://github.com/citrolabs/ego-lite/blob/d392204d1ea1a8027a591ab2b0129c2e11d85f26/docs/native-javascript-dialog-requirement.md.

## Download lifetime is not inferred from the guide

The installed guide says SDK round disposal deletes its temporary downloads.
In the owned 29-byte experiment, the exact SDK temp file and saveAs copy both
remained after process exit, at a later stat and in a later invocation. The
[download-lifetime](download-lifetime/) records retain those observations.
Do not claim .20 always deletes a temp file at round exit. MASC still needs
native-event waiting, Download handle ownership, durable download listing and
artifact publication; accidental temp-file survival does not provide those.
