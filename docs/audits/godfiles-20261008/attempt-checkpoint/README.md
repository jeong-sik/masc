# Attempt checkpoint owner

Parent: `a21200bec43675e133936fb149217551d78e801a` (#41962).
Campaign: [#41857](https://github.com/jeong-sik/masc/issues/41857).

The 3,290-line turn driver combined lane dispatch, replay adaptation and the
persistence callback adapter. `Keeper_attempt_checkpoint` now owns the latter
boundary. Its result projection is pure. Its explicitly named `canonical_sink`
adapter validates/restores a snapshot before invoking caller-supplied persistence.
It owns no storage, telemetry or provider effects. `Keeper_replay_prefix` remains
the authority for exact canonical/current-input validation.

The driver and affected tests call the actual owner directly. The old
`For_testing` result type, five forwarding/accessor functions and the copied
`provider_result` field are removed. That field had no production reader; its
only reader tested that the already-held input was copied into the output.
The provider-result parameter remains necessary to compute the turn result.
Provider observations are emitted by `Keeper_turn_driver_try_provider` before
it returns to the driver's replay adaptation; that path is unchanged and is
included in the fingerprints.

The private result contains only the turn result and a separately produced valid
checkpoint, which remains useful even on provider failure. Successful response
checkpoints are restored, invalid separate checkpoints fail the turn and are not
returned, and invalid snapshots never call persistence. Snapshot stage/turn/time,
checkpoint working context, exact answer/tool suffix, sink results and exceptions
retain their existing semantics. The driver is now 3,234 lines; its other
responsibilities and the full initial inventory remain pending.

## Executed checks

[checks.json](checks.json) records the exact commands, exits, test counts and
binary fingerprints. [source-sha256.json](source-sha256.json) records the source.

| Boundary | Actual target | Result |
| --- | --- | --- |
| Driver interface and direct owner/test consumers | focused build of both test executables / [build.log](build.log) | exit 0 |
| Prefix drift after a completed attempt, rejected checkpoints, sink writing and existing official observations | `accept 0-1,6,38,43` / [accept.log](accept.log) | 5 executed scenarios passed |
| Per-candidate media projection, canonical image/current-input restoration, separate failed checkpoint and sink refusal; deferred driver dispatch | `runtime_lane_resolution 13-18` / [failover.log](failover.log) | 6 executed scenarios passed |

The current-input scenario keeps canonical image bytes, speaker metadata,
working context and the exact completed-tool/answer suffix. It tries four invalid
boundaries and verifies none calls persistence. Its save/reload and later native
input projection are exercised through the same real owner APIs used by the
driver. The two deferred-lane cases use `run_named` against configured loopback
refusal endpoints, not a live provider. Filtered `[SKIP]` cases are excluded from
the counts. No mirrored helper regression suite is added.

These checks do not establish an installed Keeper, real provider response, full
build/CI, runtime recovery or deployment. This is one bounded responsibility
repair, not completion of the Godfile campaign.
