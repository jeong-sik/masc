(** Test-only restart launch noop state. *)

type state =
  { enabled : bool
  ; scope_depth : int
  ; scope_previous : bool
  }

let state = Atomic.make { enabled = false; scope_depth = 0; scope_previous = false }
let update f = Lockfree_atomic.update state f
let set enabled = update (fun state -> { state with enabled })
let enabled () = (Atomic.get state).enabled

let with_noop f =
  let enter () =
    update (fun state ->
      if state.scope_depth = 0
      then { enabled = true; scope_depth = 1; scope_previous = state.enabled }
      else { state with enabled = true; scope_depth = state.scope_depth + 1 })
  in
  let leave () =
    update (fun state ->
      if state.scope_depth <= 1
      then { enabled = state.scope_previous; scope_depth = 0; scope_previous = false }
      else { state with scope_depth = state.scope_depth - 1 })
  in
  enter ();
  Eio_guard.protect ~finally:leave f
;;
