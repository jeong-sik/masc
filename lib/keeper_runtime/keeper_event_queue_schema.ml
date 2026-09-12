(* keeper_event_queue_schema.ml

   Single source of truth for the durable event-queue store generations.

   #25867 (cluster: durable-schema-migration-enforcement): hard-cut schema
   changes shipped without a migration story froze the fleet three times
   (#29516, #29601, #29666) and lost durable data before that (#25078 and
   friends). The policy-level enforcement lives in
   scripts/wire-field-removal-schema-gate.sh (task-598, #35285); this module
   is the type-level half: the writer's marker, the reader's expectation,
   and the snapshot filename generation all come from here, so they cannot
   drift apart inside a PR — renaming the store file while leaving the
   marker, or bumping the marker without the file, is visible as one-line
   diffs against one module.

   Rule: a generation change edits exactly the constants below in the same
   commit as the shape change, and references the incident pattern in the
   commit message. test/keeper_event_queue/test_schema_generation_pins.ml
   pins these values a second time so an accidental edit needs two
   conscious changes, not one. *)

let state = "keeper.event_queue.state.v18"

let transition_wal = "masc.keeper_event_queue.transition.v8"

let fleet_summary = "masc.keeper_event_queue.fleet_summary.v4"

(* The filename generation is deliberately independent of the payload
   marker: bump it when the store LAYOUT changes (path, companion files),
   bump the payload marker when the WIRE SHAPE changes. Both moving
   together without a migration story is the hard-cut this module exists
   to make loud. *)
let snapshot_filename = "event-queue-v19.json"

(* The WAL file generation rides on the row marker (transition.v8): bump
   both together or a bumped marker writes a file the older binary's
   rotation/lookup never opens — the silent-miss channel that
   "writer 3곳은 전부 참조" diff-only reading missed. *)
let transition_wal_filename = "event-queue-transitions-v8.jsonl"

type mismatch =
  { store : string (* which store: "snapshot" | "transition_wal" | ... *)
  ; path : string (* file the generation was read from, when known *)
  ; actual : string
  ; expected : string
  }

let describe_mismatch { store; path; actual; expected } =
  Printf.sprintf
    "%s generation mismatch at %s: file carries %s, this binary expects %s; \
     the store was written by a different release and was not migrated"
    store path actual expected
