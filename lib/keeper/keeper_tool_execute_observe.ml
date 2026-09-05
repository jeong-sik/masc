(** See .mli for the contract. *)

type t =
  { route : unit -> Keeper_sandbox_shell_ir_target.observe_route
  ; dispatch :
      Masc_exec.Sandbox_target.t
      -> ( Masc_exec.Exec_dispatch.dispatch_result
         , Keeper_tooling.Execute_shell_ir.dispatch_error )
         result
  ; observed : Masc_exec.Exec_dispatch.dispatch_result option ref
    (* One call's stage lives on one fiber: the gate calls [observe] once,
       the caller reads [observed_result] once, and neither yields between
       the write and the read. A plain ref is the honest cell for that. *)
  ; outcome : Keeper_gate.observation option ref
  }

let create ~route ~dispatch = { route; dispatch; observed = ref None; outcome = ref None }

(* The typed gate's refusals, in the closed tags it already exports, so the
   gate log names the same reason the real dispatch would have logged. *)
let unavailable_tag = function
  | Keeper_tooling.Execute_shell_ir.Gate_reject _ -> "gate_reject"
  | Keeper_tooling.Execute_shell_ir.Cannot_parse reason ->
    "cannot_parse:" ^ Keeper_tooling.Execute_shell_ir.parse_reason_tag reason
  | Keeper_tooling.Execute_shell_ir.Too_complex reason ->
    "too_complex:" ^ Keeper_tooling.Execute_shell_ir.too_complex_reason_tag reason
  | Keeper_tooling.Execute_shell_ir.Path_reject _ -> "path_reject"
;;

let observe t () : Keeper_gate.observation =
  let outcome : Keeper_gate.observation =
    match t.route () with
    | Keeper_sandbox_shell_ir_target.No_box reason ->
      Keeper_gate.Observation_unavailable reason
    | Keeper_sandbox_shell_ir_target.Boxed { target = sandbox; run } ->
      (match t.dispatch sandbox with
       | Ok ({ Masc_exec.Exec_dispatch.status = Unix.WEXITED 0; _ } as result) ->
         t.observed := Some result;
         Keeper_gate.Observed_clean { run }
       | Ok { Masc_exec.Exec_dispatch.status; stderr; stdout = _ } ->
         Keeper_gate.Observed_refused { status; stderr }
       | Error error -> Keeper_gate.Observation_unavailable (unavailable_tag error))
  in
  t.outcome := Some outcome;
  outcome
;;

let observed_result t = !(t.observed)
let outcome t = !(t.outcome)
