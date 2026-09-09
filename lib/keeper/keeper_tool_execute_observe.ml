(** See .mli for the contract. *)

type t =
  { execution_evidence : unit -> Keeper_sandbox_remote.execution_observation list
  ; route : unit -> Keeper_sandbox_shell_ir_target.observe_route
  ; dispatch :
      Masc_exec.Sandbox_target.t
      -> ( Masc_exec.Exec_dispatch.dispatch_result
         , Keeper_tooling.Execute_shell_ir.dispatch_error )
         result
  ; outcome : Keeper_gate.observation option ref
  }

let create ~execution_evidence ~route ~dispatch = { execution_evidence; route; dispatch; outcome = ref None }

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

type box_evidence = Acknowledged | Refused | Unavailable

let box_evidence ~run evidence =
  let expected_mode = match run with
    | Keeper_types_profile_sandbox.Observe -> Exec_ssh_protocol.Observe
    | Keeper_types_profile_sandbox.Guest_local -> Exec_ssh_protocol.Guest_local in
  let rec read = function
    | [] -> Acknowledged
    | Keeper_sandbox_remote.Execution_observed ({ mode; boundary }, _) :: rest
      when mode = expected_mode ->
        (match boundary with
         | Exec_ssh_protocol.Sandbox_applied | Exec_ssh_protocol.Exec_failed -> read rest
         | Exec_ssh_protocol.Setup_failed | Exec_ssh_protocol.Refused -> Refused
         | Exec_ssh_protocol.Child_ack_unavailable -> Unavailable)
    | _ -> Unavailable
  in
  match evidence with [] -> Unavailable | _ -> read evidence
;;

let observe t () : Keeper_gate.observation =
  let outcome : Keeper_gate.observation =
    match t.route () with
    | Keeper_sandbox_shell_ir_target.No_box reason ->
      Keeper_gate.Observation_unavailable reason
    | Keeper_sandbox_shell_ir_target.Boxed { target = sandbox; run } ->
      (match t.dispatch sandbox with
       | Ok result ->
         (match box_evidence ~run (t.execution_evidence ()) with
          | Acknowledged -> Keeper_gate.Observed_result { run; result }
          | Refused -> Keeper_gate.Observed_refused { status = result.status; stderr = result.stderr }
          | Unavailable -> Keeper_gate.Observation_unavailable "enforced_box_not_acknowledged")
       | Error error -> Keeper_gate.Observation_unavailable (unavailable_tag error))
  in
  t.outcome := Some outcome;
  outcome
;;

let outcome t = !(t.outcome)

let dispatch_authorized ~source ~on_output_chunk ~dispatch =
  match source with
  | Keeper_gate.Observed_in_box { result; run = _ } ->
    if not (String.equal result.stdout "")
    then on_output_chunk (`Stdout result.stdout);
    if not (String.equal result.stderr "")
    then on_output_chunk (`Stderr result.stderr);
    Ok result
  | Keeper_gate.One_shot_resolution _
  | Keeper_gate.Exact_always_rule _
  | Keeper_gate.Keeper_always_allow
  | Keeper_gate.Workspace_always_allow
  | Keeper_gate.Readonly_sandbox
  | Keeper_gate.Local_output -> dispatch ()
;;
