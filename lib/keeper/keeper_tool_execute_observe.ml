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

type box_evidence =
  | Acknowledged
  | Refused of Keeper_gate.refusal_kind
  | Refused_after_a_stage_ran of Keeper_gate.refusal_kind
  | Unavailable

(* What one stage's receipt says. A multi-stage request (sequence, pipeline,
   substitution) leaves one receipt per stage it dispatched. *)
type stage_receipt =
  | Stage_applied
  | Stage_refused of Keeper_gate.refusal_kind
  | Stage_unacknowledged

let stage_receipt ~expected_mode = function
  | Keeper_sandbox_remote.Execution_observed ({ mode; boundary }, _) when mode = expected_mode ->
    (match boundary with
     | Exec_ssh_protocol.Sandbox_applied | Exec_ssh_protocol.Exec_failed -> Stage_applied
     (* Every refusal below ends the child before it starts that stage's
        program; the kind only says which step of building the box failed. *)
     | Exec_ssh_protocol.Refused_socket -> Stage_refused Keeper_gate.Socket_rule_not_applied
     | Exec_ssh_protocol.Refused_write -> Stage_refused Keeper_gate.Write_rule_not_applied
     | Exec_ssh_protocol.Setup_failed -> Stage_refused Keeper_gate.Setup_failed
     | Exec_ssh_protocol.Refused -> Stage_refused Keeper_gate.Unattributed
     | Exec_ssh_protocol.Child_ack_unavailable -> Stage_unacknowledged)
  | Keeper_sandbox_remote.Execution_observed _
  | Keeper_sandbox_remote.Execution_unavailable _ -> Stage_unacknowledged
;;

(* The whole request is read from every stage's receipt, never from the first
   refusal alone: in [a; b] or [a || b] one stage's program can run in an
   applied box while another stage's box could not be built. Only a request
   where no stage's box applied is a refusal in which nothing started. The
   kind is the first refusing stage's. *)
let box_evidence ~run evidence =
  let expected_mode = match run with
    | Keeper_types_profile_sandbox.Observe -> Exec_ssh_protocol.Observe
    | Keeper_types_profile_sandbox.Guest_local -> Exec_ssh_protocol.Guest_local in
  let receipts = List.map (stage_receipt ~expected_mode) evidence in
  let unacknowledged =
    List.exists (function Stage_unacknowledged -> true | Stage_applied | Stage_refused _ -> false) receipts
  in
  let applied =
    List.exists (function Stage_applied -> true | Stage_refused _ | Stage_unacknowledged -> false) receipts
  in
  let first_refusal =
    List.find_map (function Stage_refused kind -> Some kind | Stage_applied | Stage_unacknowledged -> None) receipts
  in
  if List.is_empty receipts || unacknowledged
  then Unavailable
  else (
    match first_refusal with
    | None -> Acknowledged
    | Some kind -> if applied then Refused_after_a_stage_ran kind else Refused kind)
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
          | Refused refusal_kind ->
            Keeper_gate.Observed_refused
              { status = result.status; stderr = result.stderr; refusal_kind }
          | Refused_after_a_stage_ran refusal_kind ->
            Keeper_gate.Observed_refused_after_a_stage_ran { refusal_kind }
          | Unavailable ->
            (* No acknowledgement: the box may or may not have applied.
               That says nothing about a refusal -- say exactly that,
               never dress an unknown up as an observed refusal. *)
            Keeper_gate.Observation_unavailable "enforced_box_not_acknowledged")
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
