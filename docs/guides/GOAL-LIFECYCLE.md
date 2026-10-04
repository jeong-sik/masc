# Suspending and restoring a Goal

Use **Pause** when you want to stop Goal progression temporarily, or **Block**
when a dependency prevents progress. Both preserve the live state the Goal will
return to: executing, verifying, or awaiting human confirmation. Switching between
Pause and Block preserves that restore state. Completed or dropped Goals must be
reopened before they can be suspended.

| Current state | Action | Result |
|---|---|---|
| Executing / verifying / awaiting confirmation | Pause or Block | Suspended with the current state saved |
| Paused | Resume | Restore the saved state |
| Blocked | Unblock | Restore the saved state |
| Paused | Block | Blocked, with the same restore state |
| Blocked | Pause | Paused, with the same restore state |
| Paused or blocked | Drop | Dropped |
| Paused or blocked | Reopen | Executing; the old proof request is reset |

The dashboard Goal detail shows the available controls, the restore state and
separate paused/blocked counts. TUI Goal detail uses `p` Pause, `r` Resume,
`b` Block and `u` Unblock; press the action key again to submit the armed action.
These detail keys take precedence over global navigation/refresh. Suspended Goals
remain in the TUI's default nonterminal list. `x` Drop and `o` Reopen still work.
The MCP operation is `masc_goal_transition` with `goal_id`, `action` and optional
`note`; `masc_goal_list` accepts `phase: "paused"` or `phase: "blocked"`.

Suspension applies to the Goal and admission of new Goal verification work.
Linked Tasks and unrelated Keeper turns continue under their own lifecycle.
Suspend those separately when that is intended.

An already bound verifier may finish while the Goal is suspended. Its exact
result is retained without advancing the Goal or creating a completion notice.
Resuming a verifying Goal explicitly wakes the verifier, which reconciles a
retained verdict or continues the existing pending request. Successful proof
still requires human confirmation. A paused Goal cannot be confirmed.

Editing the title, metric or target while suspended preserves Pause/Block but
changes the restore state to executing. The new criterion revision invalidates
old proof bindings. Editing due date or priority does not reset the restore state.

Goal JSON retains a string `phase`. A suspended row additionally requires a
`resume_phase` naming one of the three live states; live/terminal rows omit it.
The decoder rejects missing/invalid restore states and restore targets attached
to unsuspended Goals. The lifecycle and its audit intent commit together under
the Goal store lock. Older binaries cannot read suspended rows; restore or reopen
them using a version that supports suspension before rolling back.

This implements the [D4 decision in #41014](https://github.com/jeong-sik/masc/issues/41014).
Creation-time criterion feasibility appraisal (D3) remains separate work.
