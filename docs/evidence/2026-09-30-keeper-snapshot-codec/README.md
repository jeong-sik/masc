# Keeper snapshot executor boundary

Issue: https://github.com/jeong-sik/masc/issues/40077

Source inspection confirmed both edges of the shared-pool cycle:

- `Keeper_event_queue_persistence.commit_transform` holds the owner durable
  lock while snapshot encoding submits CPU work.
- `Keeper_event_queue_recovery.project_owner_result` and
  `project_discovered_bounded` hold a shared worker while loading the same
  owner. Server bootstrap publishes the same pool to both shared references.

The patch gives immutable state encoding its own worker. The public codec
does not accept callbacks. Strict same-state confirmation also passes the
state, so JSON construction remains inside the codec. The codec is installed
before initial owner preparation.

Review found a second cycle during shutdown: cancelled pool daemons stop
before release hooks, but release waits for the protected writer. A stop
promise now participates in each caller-local `Fiber.first`, cancelling its
blocked submission before release and propagating the owning switch's
cancellation. Switch checks prevent publishing an already-cancelled service.

The Keeper `ocaml-refactor-woman` independently confirmed the original graph
and proposed the closed codec, confirmation boundary and lifetime checks.
Discussion: `p-9a56b92b9964ecc74df2a2d2e488450b`.

Validation performed with OCaml 5.5.1:

- Isolated interface compilation and implementation typechecking passed for
  `keeper_event_queue_snapshot_codec` and `keeper_event_queue_persistence`,
  using existing dependency CMIs. No dependencies were rebuilt.
- The new `test_keeper_event_queue_codec_pool.ml` passed isolated typechecking
  against those interfaces.
- Changed bootstrap and test files passed parsing; `git diff --check` passed.
- Full typechecking of the updated existing state-v2 test was unavailable:
  existing `Masc__Keeper_registry_event_queue.cmi` assumes the previous
  persistence interface. That consumer must be rebuilt with the changed
  test confirmation seam.

The registered regression test uses actual persistence update/read calls
and one shared worker, with Promise barriers under the real owner lock. It
also covers encoding byte parity, release/reinstallation, and shutdown while
the writer holds its lock. A child-process fatal alarm bounds a hung test;
it introduces no product timeout.

These tests have not been executed. The reduced reproduction in the original
issue is not production-path runtime evidence. No full build, CI, live pool
configuration change, installation or production success is claimed.
