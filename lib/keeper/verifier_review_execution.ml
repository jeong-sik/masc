module AR = Task.Anti_rationalization
module V = Verifier_review_original
module P = Lane_addon_request_progress
module Agent = Agent_core.Agent
open Result.Syntax

type reference = {keeper_name:string; runtime_id:string; execution:Types_core.verifier_execution_reference}
let schema = "verifier_review_execution/v1"

let keeper_name original =
  let* digest = V.digest original in
  Ok ("completion-review-" ^ digest)

let session_root ~base_path original =
  let* digest = V.digest original in
  Ok (Filename.concat (Filename.concat
    (Common.masc_dir_from_base_path ~base_path) "verifier-executions") digest)

let execution_to_json = function
  | Types_core.Native_execution {call_id} ->
    `Assoc ["kind",`String "native";"call_id",`String call_id]
  | Official_session -> `Assoc ["kind",`String "official_session"]

let execution_of_json = function
  | `Assoc [("kind",`String "official_session")] -> Ok Types_core.Official_session
  | `Assoc fields ->
    let module J=Run_registry_core.Json in
    let* ()=J.exact_fields ~required:["kind";"call_id"] fields in
    let* kind=J.string_field "kind" fields in
    let* call_id=J.string_field "call_id" fields in
    let* _=Keeper_id.Trace_id.of_string call_id in
    if kind="native" then Ok (Types_core.Native_execution {call_id})
    else Error "unknown review execution kind"
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "review execution must be an object"

let capture ~original ~runtime_id ~execution =
  let* original_digest = V.digest original in
  let* keeper_name = keeper_name original in
  let* _ = execution_of_json (execution_to_json execution) in
  if String.trim runtime_id = "" then Error "review execution runtime is blank"
  else Ok (`Assoc ["schema",`String schema;"original_digest",`String original_digest;
    "keeper_name",`String keeper_name;"runtime_id",`String runtime_id;
    "execution",execution_to_json execution])

let decode ~original json =
  let module J = Run_registry_core.Json in
  let* fields = J.object_fields json in
  let* () = J.exact_fields ~required:["schema";"original_digest";"keeper_name";"runtime_id";"execution"] fields in
  let* version = J.string_field "schema" fields in
  let* original_digest = J.string_field "original_digest" fields in
  let* captured_keeper_name = J.string_field "keeper_name" fields in
  let* runtime_id = J.string_field "runtime_id" fields in
  let* execution = match List.assoc_opt "execution" fields with
    | Some value -> execution_of_json value
    | None -> Error "missing review execution" in
  let* _ = capture ~original ~runtime_id ~execution in
  let* expected_digest = V.digest original in
  let* expected_keeper = keeper_name original in
  if version <> schema || original_digest <> expected_digest || captured_keeper_name <> expected_keeper
  then Error "review execution does not bind its exact original"
  else Ok {keeper_name=captured_keeper_name;runtime_id;execution}

let same_call left right = match left.execution,right.execution with
  | Types_core.Native_execution a, Native_execution b -> a.call_id=b.call_id
  | Official_session, Official_session -> left.runtime_id=right.runtime_id
  | Native_execution _,Official_session | Official_session,Native_execution _ -> false

let references ~original progress =
  let* refs = List.fold_left (fun acc event ->
    let* refs = acc in
    match event with
    | P.Execution_observed (Waiting json) ->
      let* reference = decode ~original json in
      (match List.find_opt (fun previous -> same_call previous reference) refs with
       | Some previous when previous=reference -> Ok refs
       | Some _ -> Error "review execution call has conflicting ownership"
       | None -> Ok (reference::refs))
    | P.Execution_observed (Outcome_unknown _ | Absent _)
    | Dispatch_intended | Admission_declined _ | Judgment_retained _ | Preparation_intended _
    | Preparation_observed _ | Replacement_intended _ | Replacement_observed _
    | Commit_intended _ | Commit_uncertain _ | Commit_retry_observed _ | Commit_observed _
    | Commit_conflicted _ | Refused _ | Successor_intended _ | Successor_observed _ | Observer _ -> Ok refs) (Ok []) (P.events progress) in
  Ok (List.rev refs)

type observation = Awaiting | Repair_required of string | Verdict of AR.review_result

type call_observation =
  | Call_awaiting
  | Call_repair of string
  | Call_no_verdict
  | Call_verdict of AR.verdict

let observe_call ~base_path ~original reference =
  match reference.execution with
  | Types_core.Official_session ->
    Ok (Call_repair "original official-client session requires operator reconciliation")
  | Native_execution {call_id} ->
  let* base_path = session_root ~base_path original in
  let* journal = Keeper_request_execution.reopen ~base_path
    ~keeper_name:reference.keeper_name ~call_id in
  let* projection = Keeper_request_execution.projection journal in
  let map_error result = Result.map_error Agent.Execution_projection.error_to_string result in
  let* terminal = Agent.read_execution_terminal projection |> map_error in
  match terminal with
  | None ->
    (* Missing terminal evidence never authorizes replay. Confirmed owner-loss
       reconciliation is tracked by #46152; elapsed time alone is not that fact. *)
    Ok (Call_awaiting)
  | Some terminal ->
    (match terminal.disposition.recovery with
     | Agent.Operator_repair_required _ -> Ok (Call_repair "original execution has an unsettled effect")
     | Retire ->
       let* invocations = Agent.Execution_projection.settled_tool_invocations projection |> map_error in
       let reports = List.filter (fun (invocation:Agent.Execution_projection.settled_tool_invocation) ->
         invocation.tool_name="report_review_verdict") invocations in
       match terminal.disposition.outcome, reports with
       | Terminal_succeeded, [report] ->
         let successful = report.attempt_admitted && (match report.result with
           | Llm_provider.Types.ToolResult {outcome=Tool_succeeded;_} -> true
           | ToolResult {outcome=Tool_failed _;_} | Text _ | Thinking _ | ReasoningDetails _
           | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _ -> false) in
         if successful then
            (match AR.step_verdict_call AR.empty_verdict_call report.input with
             | _, AR.Verdict_recorded verdict -> Ok (Call_verdict verdict)
             | _, (Verdict_refused _ | Verdict_already_recorded _) ->
               Ok (Call_repair "settled report does not satisfy the original verdict protocol"))
         else Ok (Call_repair "report invocation has no successful handler settlement")
       | (Terminal_failed | Terminal_succeeded), [] -> Ok Call_no_verdict
       | Terminal_cancelled, _ -> Ok (Call_repair "original reviewer was cancelled without a retained judgment")
       | (Terminal_succeeded | Terminal_failed), _ ->
         Ok (Call_repair "original report history cannot establish one accepted verdict"))

let observe ~base_path ~original progress =
  let* () = if V.output_contract original = V.canonical_output_contract () then Ok ()
    else Error "original output contract differs from the review protocol" in
  let* references = references ~original progress in
  if references=[] then Ok (Repair_required "historical original has no durable execution locator")
  else
    let* observations = List.fold_left (fun acc reference ->
      let* observations = acc in
      let* observation = observe_call ~base_path ~original reference in
      Ok ((reference,observation)::observations)) (Ok []) references in
    if List.exists (fun (_,observation) -> observation=Call_awaiting) observations then Ok Awaiting
    else match List.find_map (function _,Call_repair detail -> Some detail
      | _,(Call_awaiting | Call_no_verdict | Call_verdict _) -> None) observations with
    | Some detail -> Ok (Repair_required detail)
    | None ->
      match List.filter_map (function reference,Call_verdict verdict -> Some (reference,verdict)
        | _,(Call_awaiting | Call_no_verdict | Call_repair _) -> None) observations with
      | [reference,verdict] -> Ok (Verdict {
          AR.verdict=Some verdict;evaluator_runtime=reference.runtime_id;
          generator_runtime=V.generator_runtime original;evaluator_execution=None;
          gate=AR.Structured_tool;fallback_reason=None;retryable_runtimes=[];model_absent_runtimes=[]})
      | [] -> Ok (Repair_required "original executions have no retained verdict")
      | _ -> Ok (Repair_required "multiple original executions supplied verdicts")
