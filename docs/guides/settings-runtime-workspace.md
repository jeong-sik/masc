# Settings Runtime workspace changes

Settings → Runtime and Model routing use the currently verified workspace.
Changing workspace or reconnecting withdraws earlier model choices and reads
new defaults, runtime resolution, provider catalog and requested file state.
When identity is unavailable, the screen offers **작업공간 확인** and disables
Runtime writes. **현재 Runtime 설정 읽기** reloads current observations.

Default, media failover and lane edits write immediately through the typed
routing API. A token wait or candidate-file read cannot carry an old workspace's
selection into a new workspace. Candidate reordering still requires the current
file revision and the same declared order that was displayed.

If a dispatched save has no confirmed response, reread current Runtime settings
before trying another write. Finishing an older read does not establish the
result of that save. File replacement, runtime resume and observed application
remain separate results. Pending saves, uncertain results and saved receipts stay
with the verified workspace connection across Settings navigation. A follow-up
refresh failure does not discard a confirmed receipt. Browser reload or a new
workspace connection starts a new Settings session.

Leaving Settings cancels unsent actions and screen reads. An already-sent save
continues its receipt/resume handling while its workspace stays current. Returning
to Settings during a pending save keeps another typed write disabled. Returning
to Settings or Runtime during resume is supported: both reread the observation
when resume finishes. An uncertain response also invalidates older file bases
without claiming the file was saved. The raw Runtime editor keeps its independent
unsaved draft; compare it with the current file before choosing a save basis.
Changing workspace stops further effects from the old operation; it cannot undo
an earlier server-side write.

The source and synthetic-HTTP checks are recorded in
[the B10 evidence](../../dashboard/evidence/2026-10-05-settings-runtime-workspace/README.md).
They do not establish deployment or native TUI behavior.
