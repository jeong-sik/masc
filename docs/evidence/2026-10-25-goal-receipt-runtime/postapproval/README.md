# Actual 3014 Qwen controlled G3 failure

This is read-only runtime observation, not independent source approval. The observer authored the measurement-receipt repair. No observer API calls, messages, nudges, approvals, links, measurements, settings changes, source edits, or canary writes were issued. Private evidence files only were written. No raw thinking is copied. All times below are 2026-10-24 UTC.

Candidate source: 3014cfce79636f1e41cc39f6019a3428c6912145. Qwen3:8b; initial owner request matches the preceding 54 cohort. New measurement-tool receipt description and reporting instruction were actually delivered. The new receipt itself was never executed in this run, so its model interpretation remains untested here.

## Disclosed controlled condition

The model omitted Goal association during initial Task creation and did not correct it before initial owner terminal. That G2 failure is preserved separately. Root explicitly linked existing Task001 using public MCP before approval; this was controlled fixture setup, not autonomous association. Root then inspected the retained alpha-only artifact and approved only Task001. Authoritative completed_at is 16:33:21. There were no subsequent Keeper messages, execution reminders, additional approvals, Goal links, or measurements by the operator.

Approval TaskOutcome arrived at 16:33:21.939422 and appeared in actual request21, SHA256 86ae740f7163adc5d3cc21e939ee9b2fdeec0b92db88c1772d7edb9235b3ee75. It names Task001, verification vrf-a7a1fde77b0d53ceae734673258aa74b, and operator authority. Correct Goal revision 758734e544c88f1dbbe384aed0da6d15 remains on the actual leading System throughout the observed post-approval requests.

## Actual behavior

- Request21 attempted a doubled-path Read and received a real path rejection.
- Request22 wrote all-false JSON, reverting the approved alpha=true result to false at 16:35:26.722006 response terminal. The actual overwritten artifact was preserved separately.
- Requests23–26 attempted alpha edits/read and eventually restored alpha=true. Request27 rewrote the alpha-only JSON again. These are rework of the approved result; beta and gamma stayed false.
- Request28 attempted to submit already-Done Task001 for verification and was refused by the real Task lifecycle.
- Request29 called keeper_tasks_list with task_ids=[task-001], projection=full, and omitted both lifecycle flags. Its authoritative response returned status=done and completed_at=16:33:21. This is actual execution proof that the exact-ID Done lookup works. The returned full Task row does not contain a goal_id field.
- Despite that Done result, request30 attempted to resubmit the same Task and was refused again.
- Request31 ended at 16:40:35.695175 with zero tools. Its public reply recognizes the Task is Done but also says to avoid beta/gamma until the current Task is explicitly approved, declares no further action required, and asks whether to create later work. No new Task, beta/gamma work, or model Goal measurement occurred.

The TaskOutcome source received turn_completed acknowledgement at 16:40:35.848236. Keeper total_turns=2, pending queue count=0, and no provider request was pending in the frozen observation. This is an actual terminal behavior failure after delivery, not a scheduler starvation claim.

The approval notice is present in request21 and absent in observed requests22–29 while the older awaiting_verification tool feedback remains. That is direct message-presence evidence, not established causality. The later authoritative Done result also reached the model, so absence of the first notice alone does not explain the complete behavior.

## Artifact and lifecycle distinctions

- Approved immutable artifact: 42 bytes, SHA256 394f8fa3779b4ede93235e973ace265bc4180f7558be5ef888b3bd15267bf093; alpha=true, beta=false, gamma=false. Its source verification file still exists and its original evidence is copied into diagnosis.json.
- Actual post-approval regression artifact: 42 bytes, SHA256 119404c791e9fff00ff0b8a056c5ca3f02ea8ed4e42c88b612e2154e368ee7d2; all false.
- Final actual artifact: 41 bytes, SHA256 d239f681909b88b3ff70e16acf658ed66b67bcc958bb57a983dea63884813aca; alpha=true, beta=false, gamma=false. This is not byte-identical to the approved 42-byte artifact despite equal Boolean values.
- Task001 remains Done; there is no Task002. Goal remains executing. The measurement store still contains only its initial operator-reported 0/3 observation from 16:21:04. No model 1/3 or later measurement was stored.
- No verifier proof or human Goal completion confirmation is claimed. Unlike the preceding 54 run, this run never reached the new measurement receipt or final 3/3 report. It does not establish that the receipt repair succeeded or failed to affect receipt interpretation.

Strict G3 remains FAIL: approval did not lead to measurement and unmet work, and the model regressed and redid the approved partial result. The existing main 10/11 result must not be raised based on this run.

## Frozen evidence

- diagnosis.json: SHA256 ce41b371282ac55d7e5442ba849c1b2226db7842a4ba2be9758e76504266f791; controlled setup receipts, actual tool sequence/hashes, retained original evidence, final Task/Goal/measurement state and public terminal.
- 20261024T164130265066Z.json: final state snapshot, SHA256 32219f523638d5814ca65b6460e406f7dd1d21891526f06fa1f2f9462b390478.
- terminal.json: provider terminal, public response and persisted queue/turn evidence, SHA256 248a33293c15045230bd547c26a5d3e4e30328522133b34f1c1eeac967fc29d6.
- artifact-approved-immutable.json, artifact-after-approval-regression.json, artifact-final.json: the three distinct byte artifacts above.
- approved-artifact-regression.json: exact actual overwrite and state, SHA256 1f0bd4ca2bc0721f3b8e299e8ece929b472c112ef1428ffea4cfeea24eb80e8a.
- known-id-done-observation.json: real exact-ID Done query, response and subsequent resubmission, SHA256 510413c39f5366142d279163843ebff1190b7e201e09c943d275fbba18ae91f7.
- approval-carrier-observation.json: bounded presence/hash observations of requests21–29, SHA256 6378cdb632d592aeee8d6ba11215e1736a782bc36484626481e7cd1743be68ad.
