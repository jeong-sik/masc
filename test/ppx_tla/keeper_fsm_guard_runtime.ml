(* Stub for [Keeper_fsm_guard_runtime] used by ppx_tla tests.
   The PPX generates [Keeper_fsm_guard_runtime.wrap_unit] calls;
   this stub provides the same signature so tests compile without
   the full keeper runtime. *)

let wrap_unit ~action:_ ~stage:_ thunk =
  thunk ()
