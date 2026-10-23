# Current completion rejection: issue #38059

The remaining defect is delivery after an obsolete outbox snapshot, not missing
Submit cleanup. Submit already retires pending rejections in its Task commit.
Cancellation provenance, Todo permissions and approval policy are outside this repair.

## Delivery and intake contract

A rejection verdict creates one current relation per Task. Pending delivery and
delivered receipt sets are disjoint. Successful queue delivery acknowledgement
moves the exact pending item to delivered; a crash before acknowledgement leaves
pending authority. A stale acknowledgement never installs an obsolete receipt.

Submit, Release, Done, Cancel, new verdict, deletion and operator recovery retire
the old relation in the same Task commit. An unroutable producer release must
match the exact pending verification and complete payload before changing the Task.

The producer acquires the Keeper intake token before the backlog lock. Inside
that lock, the existing lease fence checks ownership, rereads authoritative
backlog and publishes only a still-pending exact rejection. Queue publication
updates the live cell under its owner lock. Inventory/Librarian notifications
and the live Keeper wake run after the intake/backlog/fence locks release.
The later exact source acknowledgement uses its own backlog commit, avoiding
reentry into the lease fence.

Keeper intake accepts a rejection only when the pending or delivered relation
matches the Task, verification, producer, reason, typed authority and InProgress
owner. A positively obsolete source is acknowledged by exact queue selection
without an observation or trigger. If neither relation is recorded while the
Task remains InProgress under the same producer, intake cannot establish which
rejection is current: preserve the exact source with a typed retry outcome.
With no relation, a missing Task, another owner or another Task state is
positive retirement evidence. Unread/corrupt primary authority is retryable:
retain the source and continue independent inputs. Recovery snapshots and handoff
text are never control authority. This is an intake-time decision, not a promise
that the Task cannot change during subsequent provider rounds.

An absent `delivered_completion_rejections` field supplies an empty observation
set, just like an absent pending set; it confers neither delivered authority nor
proof of retirement. This keeps Task reads and claims available for ordinary
backlogs without that observation. Explicitly malformed, duplicate and
overlapping states are refused. A missing exact pending identity returns
`Superseded` before standing checks and never permits a new queue publication;
that producer result is not permission to ACK an uncertain existing source.
No version-specific migration or inferred receipt is introduced. No live data,
installation or runtime restart was changed in this work.

## Evidence scope

- Actual complete Types_core ML/MLI and its actual dependency closure were
  independently compiled; four verbatim new codec fixture functions passed.
  The Skill_source_config dependency includes its actual identity type/parser
  slice only; unrelated TOML effects and Types_auth are outside this probe.
- The actual Outbox ML/MLI passed nine cases against explicit
  storage/lock/lease ports: publication scope, delivered authority, obsolete
  snapshots and ACKs, payload/owner conflicts, read/write/queue failures, and
  refusal before publication on lease loss. Two cases additionally decode a
  field-absent document through the actual codec, preserve a possible old source
  under its active producer, and require positive Task retirement evidence for
  Obsolete. The normal publication case also decodes an absent delivered field
  while retaining its existing pending relation. These ports model ordering and
  failures; they do not execute real filesystem leases or concurrent queues.
- Task/queue integration regressions were added to existing native suites:
  four delivery/acknowledgement cases and three consumer cases. Existing raw
  wake tests now create actual committed rejection authority. Additional native
  regressions check Task list/claim with no delivered wire field, uncertain or
  malformed delivered evidence preserving the old queue source, and positive
  resubmission ACK with the field absent. These native suites have not been executed by this external coding session.
- Changed OCaml source syntax and whitespace checks are recorded separately.
- Independent agent source review covered the producer/outbox/queue publication
  and unroutable release delta. It does not independently approve the consumer
  code that reviewer authored, nor substitute for a current-head GitHub review.

No Dune build, full project typecheck, CI dispatch, actual lease takeover,
concurrent shutdown execution, installed binary or live Keeper behavior is
claimed. Source manifests and bounded probe logs accompany this directory.

## Reproduce these bounded checks

With the repository OCaml/opam dependencies installed, run:

```sh
python3 docs/evidence/2026-10-23-completion-rejection-current/reproduce.py .
```

The command creates and retains a fresh temporary directory, copies actual
source from this checkout, compiles the selected dependency closure, and runs
the four actual codec fixtures plus nine actual Outbox cases. The sibling
`ports/` files and `outbox_fixture.ml` explicitly model only storage, errors
and deterministic ordering. They do not run the real Keeper queue, consumer,
filesystem lease or shutdown. The output manifest binds source, verbatim
fixture definitions and harness bytes. Compile/run logs contain exact argv.
