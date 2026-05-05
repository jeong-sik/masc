(** test_turn_id_propagation — Step 15 partial.

    Compile-time sentinel for the Step 0a (PR #11154 + #11156 + #11159)
    decision that wired [?turn_id] through [Log.Make] and every
    pre-defined module logger.  If a future PR strips [?turn_id] from
    the log surface, this file fails to type-check and the regression
    is caught at build time before the keeper fleet starts emitting
    log entries with no correlator -- which is exactly the silent
    failure mode the bloodflow restoration plan is meant to close. *)

(** Anchor: a fresh [Make] instantiation must accept [?turn_id] and
    [?keeper_name] on every level.  If the signature changes, this
    module won't compile. *)
module Anchor =
  Log.Make (struct
    let name = "test_turn_id_propagation_anchor"
  end)

let test_make_functor_signature_stable () =
  (* Pass [None] so we don't pollute the log ring during test output;
     the *type* of these calls is what matters -- if [?turn_id] is
     removed from any of the level helpers, compilation fails. *)
  Anchor.emit Log.Info ?turn_id:None ?keeper_name:None
    "[15d-anchor]";
  Anchor.debug ?turn_id:None ?keeper_name:None "%s" "[15d-anchor]";
  Anchor.info ?turn_id:None ?keeper_name:None "%s" "[15d-anchor]";
  Anchor.warn ?turn_id:None ?keeper_name:None "%s" "[15d-anchor]";
  Anchor.error ?turn_id:None ?keeper_name:None "%s" "[15d-anchor]";
  Alcotest.(check bool)
    "Log.Make.{emit,debug,info,warn,error} accept ?turn_id"
    true true

(** Pre-defined module loggers carry the same surface.  These four
    are the ones the keeper turn flow actually emits through:
    - Keeper: receipts, phase gate, cascade routing
    - Mcp:    runtime token / transport / dispatch
    - Auth:   token resolution events
    - Coord:  fleet coordination
    Other module loggers (Cancel, Session, Backend, etc.) share the
    same functor signature, so checking these four is sufficient. *)
let test_predefined_loggers_signature_stable () =
  Log.Keeper.info ?turn_id:None ?keeper_name:None "%s"
    "[15d-anchor]";
  Log.Keeper.warn ?turn_id:None ?keeper_name:None "%s"
    "[15d-anchor]";
  Log.Mcp.info ?turn_id:None ?keeper_name:None "%s"
    "[15d-anchor]";
  Log.Auth.info ?turn_id:None ?keeper_name:None "%s"
    "[15d-anchor]";
  Log.Coord.info ?turn_id:None ?keeper_name:None "%s"
    "[15d-anchor]";
  Alcotest.(check bool)
    "Log.{Keeper,Mcp,Auth,Coord} carry ?turn_id and ?keeper_name"
    true true

(** Accepting an [int turn_id] specifically (not just [None]) catches
    any signature drift to a different argument type (e.g. [string]
    or [Masc_domain.Ids.Turn_id.t]).  The [Step 0a] wiring uses [int] (the
    [meta.runtime.usage.total_turns + 1] monotonic counter). *)
let test_turn_id_is_int () =
  Anchor.info ~turn_id:42 ~keeper_name:"alice" "%s" "[15d-anchor]";
  Log.Keeper.info ~turn_id:0 ~keeper_name:"bob" "%s"
    "[15d-anchor]";
  Alcotest.(check bool) "?turn_id stays int" true true

let () =
  Alcotest.run "turn_id_propagation"
    [
      ( "log_make_functor",
        [
          Alcotest.test_case "Make functor surface stable" `Quick
            test_make_functor_signature_stable;
        ] );
      ( "predefined_loggers",
        [
          Alcotest.test_case "predefined module surfaces stable" `Quick
            test_predefined_loggers_signature_stable;
        ] );
      ( "type_anchor",
        [
          Alcotest.test_case "?turn_id accepts int values" `Quick
            test_turn_id_is_int;
        ] );
    ]
