# Prompt Presets

A saved preset groups prompt overrides, Keeper instructions, Runtime assignments
and exact-output lane declarations. It does not replace the managed default
prompt files. Presets live under `<base-path>/.masc/presets/<name>/`.

## Dashboard

Open **Settings → Prompts**. **Saved prompt settings** lists actual saved
snapshots; the separate assembly-stage filter changes which prompt rows you see.
Choose a saved snapshot to inspect its affected settings and compare it with the
current configuration. Expand the settings list for individual names.

To save, enter a new name and an optional description. An existing name is
rejected atomically, including when another client creates it after your list
was loaded. The web save does not replace an existing snapshot.

To restore, choose the snapshot, open its restore confirmation, review its scope
and confirm. The server first replaces `_autosave` with the current configuration.
Every later restore replaces that one backup. Inspect the result for each
surface: an accepted HTTP response can still report partial application.

A pending or uncertain write remains attached to its original workspace session
when you navigate away. If the result is uncertain, reread the current state
before considering a new operation; the client does not automatically replay it.
A workspace or credential change invalidates the old selection and confirmation.

## TUI

Open Config and use `p` to select the presets section. Use `n` to save the current
settings, `u` twice to confirm restoration, and `r` to reread. The selected saved
snapshot's details and the result explain preserved settings and skipped lanes.
The chat commands also support `/preset`, `/preset show <name>`,
`/preset save <name> [description]` and `/preset restore <name>`.
See the [canonical TUI key reference](TUI-KEYS.md) for navigation and deletion.

The existing TUI/API save can replace a preset of the same name. Use a new name
when retaining an earlier snapshot. The web create-only save has different
replacement semantics.

## Earlier saved snapshots and partial results

A lane request setting absent from the snapshot was not recorded and leaves the
current declaration unchanged. Explicit JSON `null` removes the declaration;
a recorded value restores that value. A lane unavailable in the current runtime
stays visible in the saved contents but is excluded from runtime writes. Neither
inspection nor restoration rewrites the original saved snapshot.

An assignment unavailable under the current capability catalog, or an assignment
or complete lane declaration the current Runtime writer refuses, keeps its
current value. This includes saved Runtime IDs that are no longer configured.
Other accepted settings can still restore. Review the
reported exclusions: no replacement model is selected and lane candidate lists
are not shortened to make them pass. A restore with exclusions is partial.

If the final Runtime write itself fails, its part is reported as failed. Prompt
overrides and Keeper instructions have their own application results; inspect
all of them.
Overrides apply immediately, Keeper instructions take effect at the next up/turn,
and the Runtime commit receipt separately describes file durability and running
lane publication. Restoring `_autosave` applies the settings it captured, subject
to the same per-surface report and the limitations described above.
