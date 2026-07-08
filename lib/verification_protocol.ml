(** Verification Protocol — task completion verification and contract enforcement.

    This module implements the verification protocol for MASC tasks.
    It checks that task completions meet their acceptance criteria,
    validates completion contracts, and enforces the verification
    pipeline.

    Key functions:
    - verify_completion: Main entry point for task completion verification
    - check_contract: Validates that a task's completion contract is satisfied
    - warn_contract_gap: Warns when a contract gap is detected (observability only)
    - enforce_contract: Enforces contract requirements (returns result)
*)

open Masc_task
open Masc_state

(** Result type for verification outcomes. *)
type verification_result =
  | Verified of string
  | Rejected of string
  | Pending of string

(** Contract gap warning — returns unit for observability.
    TODO: Change to return result type for enforcement.
    Line 111: This function is called but its return value is discarded.
    Line 138: Called with `;` sequence operator, result ignored.
*)
let warn_contract_gap : task -> completion -> unit =
 fun task completion ->
  match task.contract with
  | None ->
      Printf.eprintf
        "[WARN] Task %s has no contract — verification proceeds without contract enforcement\n"
        task.id
  | Some contract ->
      if contract.completion_contract = [] then
        Printf.eprintf
          "[WARN] Task %s has empty completion_contract — verification proceeds without contract enforcement\n"
          task.id
      else
        ()

(** Enforce contract requirements — returns verification result.
    This is the enforcement layer that should replace warn_contract_gap.
    Tasks with no contract or empty completion_contract are rejected.
*)
let enforce_contract : task -> completion -> verification_result =
 fun task completion ->
  match task.contract with
  | None -> Rejected "Task has no contract — cannot verify completion"
  | Some contract ->
      if contract.completion_contract = [] then
        Rejected "Task has empty completion_contract — cannot verify completion"
      else
        (* Check each required_evidence entry *)
        let missing_evidence =
          List.filter (fun ev ->
            not (List.exists (fun c -> c = ev) completion.evidence)
          ) contract.required_evidence
        in
        match missing_evidence with
        | [] -> Verified "All contract requirements satisfied"
        | missing ->
            Rejected
              (Printf.sprintf
                 "Missing contract evidence: %s"
                 (String.concat ", " missing))

(** Main verification entry point.
    Line 138: Previously called warn_contract_gap with `;` (discarded result).
    Now calls enforce_contract and checks the result.
*)
let verify_completion : task -> completion -> verification_result =
 fun task completion ->
  (* Line 138: Previously `warn_contract_gap task completion;` — result discarded *)
  (* Now: enforce contract and check result *)
  match enforce_contract task completion with
  | Rejected reason -> Rejected reason
  | Verified _ ->
      (* Additional verification checks would go here *)
      Verified "Task completion verified"
  | Pending reason -> Pending reason

(** Run verification for a task and update state.
    Returns the updated Masc_state.t with the task marked as done.
*)
let run_verification : Masc_state.t -> Masc_task.t -> Masc_task.completion -> Masc_state.t =
 fun state task completion ->
  match verify_completion task completion with
  | Verified _ ->
      Masc_state.update_task state task.id (fun t ->
        { t with status = Masc_task.Done; verified_at = Some (Unix.gettimeofday ()) }
      )
  | Rejected reason ->
      Masc_state.update_task state task.id (fun t ->
        { t with status = Masc_task.Failed; failure_reason = Some reason }
      )
  | Pending reason ->
      Masc_state.update_task state task.id (fun t ->
        { t with status = Masc_task.Awaiting_verification; pending_reason = Some reason }
      )

(** Test: verify that tasks without contracts are rejected. *)
let%test "verify_completion rejects task with no contract" =
  let task =
    { Masc_task.id = "test-001"; status = Masc_task.In_progress; contract = None;
      completion_contract = []; required_evidence = []; title = "Test task";
      description = "Test description"; assigned_to = None;
      verified_at = None; failure_reason = None; pending_reason = None;
      created_at = Unix.gettimeofday (); updated_at = Unix.gettimeofday () }
  in
  let completion =
    { Masc_task.evidence = []; notes = "Test completion" }
  in
  match verify_completion task completion with
  | Rejected _ -> true
  | _ -> false

(** Test: verify that tasks with empty completion_contract are rejected. *)
let%test "verify_completion rejects task with empty completion_contract" =
  let task =
    { Masc_task.id = "test-002"; status = Masc_task.In_progress;
      contract = Some { Masc_task.completion_contract = []; required_evidence = [] };
      completion_contract = []; required_evidence = []; title = "Test task";
      description = "Test description"; assigned_to = None;
      verified_at = None; failure_reason = None; pending_reason = None;
      created_at = Unix.gettimeofday (); updated_at = Unix.gettimeofday () }
  in
  let completion =
    { Masc_task.evidence = []; notes = "Test completion" }
  in
  match verify_completion task completion with
  | Rejected _ -> true
  | _ -> false

(** Test: verify that tasks with valid contract pass. *)
let%test "verify_completion accepts task with valid contract" =
  let task =
    { Masc_task.id = "test-003"; status = Masc_task.In_progress;
      contract = Some { Masc_task.completion_contract = ["test-evidence"]; required_evidence = ["test-evidence"] };
      completion_contract = ["test-evidence"]; required_evidence = ["test-evidence"];
      title = "Test task"; description = "Test description"; assigned_to = None;
      verified_at = None; failure_reason = None; pending_reason = None;
      created_at = Unix.gettimeofday (); updated_at = Unix.gettimeofday () }
  in
  let completion =
    { Masc_task.evidence = ["test-evidence"]; notes = "Test completion" }
  in
  match verify_completion task completion with
  | Verified _ -> true
  | _ -> false