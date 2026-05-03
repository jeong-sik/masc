(* Stub for [Keeper_fsm_guard_runtime] used by ppx_tla tests.
   The PPX generates [Keeper_fsm_guard_runtime.wrap_unit] calls;
   this stub provides the same signature so tests compile without
   the full keeper runtime.

   Unlike the production version which bumps a Prometheus counter,
   this stub tracks invocations in a mutable ref for test inspection. *)

let invocations : (string * string) list ref = ref []

let wrap_unit ~(action : string) ~(stage : string) (thunk : unit -> unit) : unit =
  invocations := (action, stage) :: !invocations;
  thunk ()

let get_invocations () = List.rev !invocations

let reset_invocations () = invocations := []
