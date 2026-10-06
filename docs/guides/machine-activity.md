# MSX and DOS activity

Set machine activity in the workspace's `runtime.toml` through the existing
Runtime source editor and its preview/save flow:

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

The inventory currently provides these readings in TUI and Web. Dedicated
machine on/off editors remain a follow-up; use Runtime source editing for now.
Package Add-ons have a separate [activity setting](lane-package-activity.md).
