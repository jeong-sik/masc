# MSX and DOS activity

In TUI All Lanes, select MSX or DOS and press Space to open activity settings.
Space edits the draft and **s** previews and saves it. The Runtime source editor
also accepts these settings in the workspace's `runtime.toml`:

```toml
[machines.msx]
enabled = false

[machines.dos]
enabled = true
```

Omitted flags default to `true`. These tables accept only boolean `enabled`
values; unknown machine names or settings are rejected. Saving publishes the
validated configuration used by both machine owners. A missing published
configuration is shown as **Unobserved**, and new machine work is refused.

**Off** prevents new loads, restores, stepping and input. MSX disk changes and
the spectator's advancing tick are also refused. DOS refuses giving control to
a new player. An operation accepted before Off finishes its input release and
checkpoint work; Off does not interrupt it halfway through.

Turning activity off preserves the current machine, configured paths,
incarnation, RAM, input history and checkpoints. Screen/live reads, captures,
memory inspection and checkpoint saving remain available. Ejecting a machine
and releasing DOS control are still possible. The DOS load/restore tools with
no arguments list available programs/checkpoints and remain usable while off.
Turning On allows new work on the retained machine. Retained RAM refers to the
current server process; use the existing save/restore checkpoints for persistence
across server restarts.

The MSX spectator keeps watching the retained screen through read-only requests
while activity is Off or unavailable. Once On is observed, its next normal poll
can advance the machine again. A lost tick response still requires an explicit
observation before polling resumes. Refused keyboard input is shown as a notice.

The Lane inventory shows activity separately from publication. **Off + Stable**
means new machine work is disabled and a completed screen is still available.
**Off + Running** can occur while previously accepted work finishes. Activity On
does not imply a machine has been loaded. Unobserved does not mean Off.

In TUI **All Lanes**, select MSX or DOS and press **Space** to open activity
settings. Enter still opens the spectator. Inside settings, Space changes only
the draft and **s** previews and saves it against the original file revision.
Esc returns to the list and keeps the draft. **r** reads both the current file
and the machine's server activity again; those are displayed separately.

A conflicting or uncertain save keeps the intended change. **u** reapplies
only that activity to the displayed current file; **s** then saves explicitly.
If the reread already contains the intended value, no further save is needed.
**x** discards the draft without writing. A changed configuration-file path
requires discarding the old draft before editing the new file. Existing inline
or dotted machine declarations currently use the Runtime source editor.

In Web **All Lanes**, choose **Inspect** on MSX or DOS, then open activity
settings. The switch changes a retained draft; **Save activity settings**
(활동 설정 저장) previews and saves explicitly. MSX and DOS have independent
drafts, retained across dashboard navigation. The Runtime source editor keeps
its own draft. Web editing supports standard tables, dotted keys and inline
tables while retaining comments and unrelated settings.

The editor rereads the file and server activity after a successful or unanswered
save. It shows the last observation and its time separately from the saved file
and commit receipt. A failed read remains visible and can be retried. A mismatch
does not claim that the file has been applied. An uncertain write requires an
explicit reapply or discard after reading; it is never automatically repeated.
Reapply changes only the selected machine's activity in the freshly read file.
A changed file path requires discarding the old draft first. Enabling does not
load a machine or restore a checkpoint.

Package Add-ons have a separate [activity setting](lane-package-activity.md).
