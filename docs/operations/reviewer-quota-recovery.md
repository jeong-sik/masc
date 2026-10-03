# Reviewer quota recovery

A Keeper assigned directly to one runtime has no alternative candidate when
that account is quota-blocked. An active lifecycle or a successful account probe
does not establish that its pending reviews are being completed.

The October 3 runtime audit observed Antigravity quota refusals on two review
Keepers, 30 pending completion-authority Tasks, 30 runnable events and 7 events
retained under paused/dead owners. These are different queues and are not added
together as a count of independent failures. The quota refusals had no observed
next runtime. DNS and Codex routing errors also recurred between successful
turns; do not classify a successful probe as a permanent repair.

## Configure an alternative

`config/runtime.toml` ships the opt-in `reviewer-failover` lane. The candidates
are Codex, Z.AI and Antigravity on three different providers. This does not
supply credentials or guarantee provider availability, and it leaves the fleet
default and all deployment-local Keeper assignments unchanged.

For an existing workspace:

1. Read `/health?full=1` and confirm `paths.effective_base_path` and
   `paths.effective_masc_root`. Read the current runtime configuration through
   the runtime configuration surface. Preserve its revision and the old
   assignment for rollback.
2. Inspect the target Keeper's resolved assignment and any lane of the same
   name. A lane takes precedence over a runtime with that name. Check candidate
   bindings, credentials, native-tool permissions and sandbox compatibility in
   the actual workspace. Seed IDs can differ from install-wizard IDs; use the
   existing live binding IDs instead of copying credentials or inventing IDs.
3. Through the dashboard runtime configuration surface, create a named lane
   containing available candidates on separate providers. The seed below is
   an example, not a replacement for the live file:

   ```toml
   [runtime.lanes.reviewer-failover]
   candidates = [
     "codex_subscription.codex-gpt-6-1-sol-high",
     "glm-coding.glm-5-3",
     "antigravity_subscription.antigravity-gemini-3-8-flash-high",
   ]
   ```

4. Assign the intended Keeper to that lane through the runtime configuration
   surface. Keep unrelated assignments, exact-output lanes, provider homes and
   bindings intact. Read back both the lane and the assignment after saving.
   Do not overwrite the live TOML with the repository seed.

   ```toml
   [runtime.assignments]
   # Merge this entry into the existing assignment table; do not duplicate it.
   reviewer = "reviewer-failover"
   ```

5. Inspect the next naturally scheduled turn's attempt/runtime evidence and the
   original event's durable acknowledgment. Do not claim recovery from a saved
   assignment or an account/read probe alone. A completed review must still
   satisfy current-head independent review rules.

The runtime's existing failure/effect policy determines whether another
candidate may run. A timeout after turn dispatch with an unknown outward effect
requires resolving the original attempt; another candidate is not permission to
repeat it. Do not delete events, advance Librarian progress or mark Tasks Done
to make an outage disappear. Rollback restores the saved assignment and removes
the new lane only if no other assignment or Fusion seat uses it.

## Verify the separate judgment lane

A Keeper's runtime assignment does not configure `verifier_exact`. For pending
completion-authority Tasks, inspect that lane's actual HTTP `slots` and official
client `cli_slots`, account availability and durable verification IDs separately.
Keep the existing IDs through retries and require a durable verdict before
claiming completion. Do not copy general Keeper candidates into HTTP slots:
subscription clients must use the configured official-client channel.

## Follow-up boundaries

This configuration change makes an alternative route available; it does not
implement structured Antigravity quota detection or consume the live backlog.
Those remain tracked by [#39696](https://github.com/jeong-sik/masc/issues/39696)
and [#39190](https://github.com/jeong-sik/masc/issues/39190). Do not classify quota
from substrings of human-readable error messages. Preserve provider-reported
reset and typed failure evidence when extending those paths.
