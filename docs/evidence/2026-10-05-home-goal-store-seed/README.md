# Goal Home fixture durable seed and recovery navigation

Parent #41192 `7da701a398a9b9383dc37a1a5312b49b421c780e`. Only `goal_drop_arm_withdrawal_journey` changes. No product edit/build. The old #40438 unknown HTTP-key cause was already corrected in this fixture; this followup establishes a separate missing required durable-field cause.

`planning_goal` is an HTTP response fixture without created_at/updated_at. The Goal scenario removes verification/verifier_unreconciled and adds criterion_revision, but then persists that row to goals.json. `Goal_store.goal_of_yojson` requires created_at and updated_at strings; `load_goals_to_confirm` reads this real store, not the planning HTTP snapshot. The unchanged scenario reproduced failure waiting for ConfirmGoal. Supplying both fixed fixture ISO facts makes the actual card/detail/first drop arm execute against the same binary. Strict production parsing is untouched.

The timestamp-only attempt then reached the original mismatch wait and exposed a clipped100-column header (`[connecte…]`). The fixture now fits the full badge at160 columns BEFORE arming, then forces161/162-column withdrawal/recovery frames. An intermediate same-width recovery failed waiting for a fresh full clear despite correct visible recovery; distinct geometry makes those existing redraw assertions exercise actual full frames. No key is sent between the first x arm and the periodic foreign identity read.

After recovery, original Right did nothing on Home: the main Home handler accepts Enter, while the generic Right branch leaves Overview unchanged. Re-selecting the exact recovered Goal card and pressing Enter uses the real Home navigation. The generic Goal-action disarm runs only when the pre-key view is Planning, so selecting/opening from Overview does not substitute for the identity/reconciliation reset. The first recovered x must still arm rather than POST. All original foreign/recovered identity, exact Goal visibility, arm and no-drop-POST assertions remain.

Actual same-binary fixture RED and final Goal GREEN are retained. Binary was rehashed before RED as exact-main6fc `196d9fce8ecced88ab44ac424d300d9744299ee1f707d323eac9c0803d7bae0e`; there is no new build or newer-main executable claim. Timestamps-progress, geometry-progress and Right-progress failures document successive fixture contract defects, not product failures. This is synthetic loopback HTTP/PTY proof, not release or production verification.

The three previously unreached held-identity scenarios now all pass: before-read, after-read and decision. Combined with the prior parent's four preceding passes, the eight scenarios have split scoped evidence; **no single full-eight PASS is claimed**. The original earlier full-script failure remains preserved in the parent evidence directory. No duplicate full-eight run was performed after this repair.

Ruff and diff check pass. Pyright141→141 with identical diagnostic-message multisets; it is not clean and no suppression is added. Raw checker hashes and exact fixture/binary hashes are recorded in checks.json. #40438 remains the existing issue; publication and any reply are left to root review.

Decoded screen text trims trailing padding; original terminal bytes remain in the corresponding raw failure logs.
