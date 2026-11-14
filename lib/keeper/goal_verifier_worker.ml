module V = Goal_verifier_original
module A = Verification_authority_tools
module AR = Task.Anti_rationalization
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Change = Verifier_review_authority_change
module View = Goal_verifier_refusal

open Result.Syntax
let scope = "goal-proof-reviews"
let tool_name = "goal_proof_review"
let host_installation_id = "masc.goal-verification"
let host_package_id = "masc.goal-verification.review"

type run_identity = View.run_identity
type receipt = {
  run : run_identity;
  result : AR.review_result;
  tools : Verification_run_registry.tool_observation list;
  elapsed_s : float;
}
type error =
  | Store_unavailable of string
  | Original_invalid of string
  | Destination_mismatch of string
  | Authority_unavailable of string
  | Question_changed
  | Authority_changed of Change.t
  | Execution_pending of string
type interruption = Cancelled | Raised
let interruption_label = function Cancelled -> "review_cancelled" | Raised -> "review_raised"
let interruption_of_label = function
  | "review_cancelled" -> Ok Cancelled
  | "review_raised" -> Ok Raised
  | _ -> Error "unknown Goal review interruption"
type retry_grant = {parent_digest : string; requested_by : string}
type retained = {record : Owner.retained; original : V.t; run : run_identity}
type observation_issue =
  | Unattributable_metadata
  | Noncanonical_request_metadata
  | Original_binding_mismatch
type observation_binding = {
  base_path : string;
  goal_id : string;
  request_id : string;
  criterion : Goal_store.criterion;
  submitted_evidence : Workspace_verification_store.submitted_evidence_item list;
}
type request_observation = {
  binding : observation_binding;
  observation_started_at : float;
  observation_finished_at : float;
  observed_records : retained list;
  issues : observation_issue list;
}
let error_to_string = function
  | Store_unavailable d | Original_invalid d | Destination_mismatch d | Authority_unavailable d
  | Execution_pending d -> d
  | Question_changed -> "the Goal proof question changed after its review original was prepared"
  | Authority_changed change -> Change.to_string change

let invalid detail = Error (Original_invalid detail)
let decode result = Result.map_error (fun detail -> Original_invalid detail) result
let serialized ~store ~kind ~identity work =
  try
    let root = Lane_addon_store.root store in
    let parent = Unix.realpath (Filename.dirname root) in
    let key = Filename.concat parent (Filename.concat (Filename.basename root)
      (Filename.concat "goal-review-serialization" (kind ^ "-" ^ Lane_addon_store.digest identity))) in
    File_lock_eio.with_mutex key work
  with Unix.Unix_error (error, operation, _) -> Error (Store_unavailable (operation ^ ": " ^ Unix.error_message error))
let serialized_subject ~store ~goal_id ~request_id work =
  serialized ~store ~kind:"subject" ~identity:(Yojson.Safe.to_string (`List [`String goal_id; `String request_id])) work
let text key fields = Json_util.require_field_string ~surface:scope key fields
let field key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error (scope ^ "." ^ key ^ " is required")
let object_fields allowed = function
  | `Assoc fields -> let* () = Json_util.reject_unknown_fields ~surface:scope ~allowed fields in Ok fields
  | _ -> Error (scope ^ " must be an object")
let run_json = View.run_json
let run_of_json = View.run_of_json

(* The staged successor and its published owner name the very same complete
   request bytes. In particular, recovery cannot invent another run after the
   parent intent has become durable. The summary remains an observation index. *)
let grant_json = function
  | None -> `Null
  | Some grant -> `Assoc ["parent_digest", `String grant.parent_digest; "requested_by", `String grant.requested_by]
let grant_of_json = function
  | `Null -> Ok None
  | json ->
    let* fields = object_fields ["parent_digest"; "requested_by"] json in
    let* parent_digest = text "parent_digest" fields in
    let* requested_by = text "requested_by" fields in
    if String_util.is_lowercase_sha256_hex parent_digest then Ok (Some {parent_digest; requested_by})
    else Error "invalid Goal retry parent digest"
let request_json original run explicit_retry =
  `Assoc ["schema", `String "goal_verifier_request/v1";
    "original", V.to_json original; "run", run_json run; "explicit_retry", grant_json explicit_retry]

let request_of_json json =
  let* fields = object_fields ["schema"; "original"; "run"; "explicit_retry"] json in
  let* version = text "schema" fields in
  let* original_json = field "original" fields in
  let* original = V.of_json original_json in
  let* encoded_run = field "run" fields in
  let* run = run_of_json encoded_run in
  let* encoded_grant = field "explicit_retry" fields in
  let* explicit_retry = grant_of_json encoded_grant in
  if version = "goal_verifier_request/v1" && (V.attempt original > 0 || explicit_retry = None)
  then Ok (original, run, explicit_retry)
  else Error "unknown Goal verifier request schema"

let key ~goal_id ~request_id ~attempt =
  if String.trim goal_id = "" || String.trim request_id = "" || attempt < 0 then
    Error "Goal verifier original requires its exact nonblank subject and nonnegative attempt"
  else Ok (Yojson.Safe.to_string (`List [`String goal_id; `String request_id; `Int attempt]))
type invalid_attribution =
  | Goal_request of string * string
  | Unattributable

let subject_of_key encoded =
  match (try Ok (Yojson.Safe.from_string encoded)
    with Yojson.Json_error detail -> Error detail) with
  | Error detail -> Error (Unattributable, Original_invalid detail)
  | Ok (`List [`String goal_id; `String request_id; `Int attempt]) ->
    (match key ~goal_id ~request_id ~attempt with
     | Ok canonical when String.equal canonical encoded -> Ok (goal_id,request_id)
     | Ok _ -> Error (Goal_request (goal_id,request_id),
         Original_invalid "Goal verifier original subject key is not canonical")
     | Error detail -> Error (Unattributable, Original_invalid detail))
  | Ok _ -> Error (Unattributable,
      Original_invalid "Goal verifier original subject key is invalid")
let original_key original =
  let subject = V.subject original in
  key ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original)
let summary original run =
  let* digest = V.digest original in
  let* _ = run_of_json (run_json run) in
  Lane_addon_action.canonical (`Assoc ["schema", `String "goal_verifier_owner/v1";
    "original_digest", `String digest; "run", run_json run])

let validate_record ~installation_id ~package_id (record : Owner.retained) =
  let* original, run, explicit_retry = decode (request_of_json record.request) in
  let* expected_key = decode (original_key original) in
  let* fields = decode (object_fields ["schema"; "original_digest"; "run"] record.summary) in
  let* summary_run = decode (field "run" fields) in
  let* summary_run = decode (run_of_json summary_run) in
  let* expected_summary = decode (summary original run) in
  let* expected_digest = decode (Owner.request_digest (request_json original run explicit_retry)) in
  if record.scope <> scope || record.tool <> tool_name || record.request_id <> expected_key
    || record.request_digest <> expected_digest || summary_run <> run
    || not (Yojson.Safe.equal expected_summary record.summary) then
    invalid "Goal verifier owner identity or complete original differs"
  else if record.installation_id <> installation_id || record.package_id <> package_id then
    Error (Destination_mismatch "Goal verifier original belongs to another destination")
  else Ok {record; original; run}

let load ~store ~installation_id ~package_id ~goal_id ~request_id ~attempt =
  let* owner_key = decode (key ~goal_id ~request_id ~attempt) in
  let* record = Owner.load ~store ~scope ~request_id:owner_key
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  match record with
  | None -> Ok None
  | Some record -> Result.map Option.some (validate_record ~installation_id ~package_id record)

let retain_with_grant ~store ~installation_id ~package_id ~run ~explicit_retry original =
  let* request_id = decode (original_key original) in
  let* summary = decode (summary original run) in
  let* () = Owner.retain ~store ~scope ~request_id ~installation_id ~package_id
    ~tool:tool_name ~summary ~request:(request_json original run explicit_retry)
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  let subject = V.subject original in
  let* loaded = load ~store ~installation_id ~package_id ~goal_id:subject.goal_id
    ~request_id:subject.request_id ~attempt:(V.attempt original) in
  match loaded with Some retained -> Ok retained | None -> invalid "retained Goal original is absent"

let retain ~store ~installation_id ~package_id ~run original =
  let subject = V.subject original in
  serialized_subject ~store ~goal_id:subject.goal_id ~request_id:subject.request_id (fun () ->
    retain_with_grant ~store ~installation_id ~package_id ~run ~explicit_retry:None original)

let read_all ~store =
  let* records = Owner.load_scope ~store ~scope
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  let* reversed = List.fold_left (fun state (record : Owner.retained) ->
    let* acc = state in
    let* retained = validate_record ~installation_id:record.installation_id ~package_id:record.package_id record in
    Ok (retained::acc)) (Ok []) records in
  Ok (List.rev reversed)

(* The record's own destination stands in for the caller's, as [read_all]
   does: a preflight has no live destination to compare. *)
let check_retained (record : Owner.retained) =
  validate_record ~installation_id:record.installation_id ~package_id:record.package_id record
  |> Result.map (fun (_ : retained) -> ())
  |> Result.map_error error_to_string

let inventory ~store ~installation_id ~package_id =
  let* records = read_all ~store in
  Ok (List.filter (fun retained -> retained.record.installation_id = installation_id
    && retained.record.package_id = package_id) records)

type invalid_subject =
  { request_id : string
  ; attribution : invalid_attribution
  ; error : error
  }

type subject_discovery =
  { subjects : ((string * string) * Owner.Record.t) list
  ; invalid : invalid_subject list
  }

(* Noncanonical keys retain their parsed identity only to bound refusal. They
   never become readable originals or permission to dispatch another request. *)
let classify_subjects records =
  let discovery = List.fold_left (fun found record ->
    match subject_of_key (Owner.Record.request_id record) with
    | Ok subject -> { found with subjects=(subject,record)::found.subjects }
    | Error (attribution,error) ->
      let rejected = {request_id=Owner.Record.request_id record;attribution;error} in
      { found with invalid=rejected::found.invalid })
    { subjects=[]; invalid=[] } records in
  { subjects=List.rev discovery.subjects; invalid=List.rev discovery.invalid }

let discover_subjects ~store =
  Owner.discover ~store ~scope
  |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e))
  |> Result.map classify_subjects

let observe_subjects ~store =
  let* observation = Owner.observe ~store ~scope
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  let malformed = match observation.Owner.issues with [] -> false | _::_ -> true in
  Ok (classify_subjects observation.records, malformed)

let load_discovered ~store ~installation_id ~package_id records =
  let* reversed = List.fold_left (fun state (_,observed) ->
    let* found = state in
    let* record = Owner.load_listed ~store observed
      |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
    let* retained = validate_record ~installation_id ~package_id record in
    Ok (retained::found)) (Ok []) records in
  Ok (List.rev reversed)

let invalid_is_unattributable (entry : invalid_subject) =
  match entry.attribution with
  | Unattributable -> true
  | Goal_request _ -> false

let noncanonical_affects_request ~goal_id ~request_id (entry : invalid_subject) =
  match entry.attribution with
  | Unattributable -> false
  | Goal_request (observed_goal,observed_request) ->
    observed_goal=goal_id && observed_request=request_id

let inventory_for_goal ~store ~installation_id ~package_id ~goal_id =
  if String.trim goal_id = "" then invalid "Goal inventory requires a nonblank Goal ID"
  else
    let* discovery = discover_subjects ~store in
    let selected = List.filter (fun ((observed_goal,_),_) -> observed_goal=goal_id)
      discovery.subjects in
    let* () =
      if selected=[] && List.exists invalid_is_unattributable discovery.invalid
      then invalid "Goal original metadata is unavailable and cannot be attributed"
      else Ok () in
    load_discovered ~store ~installation_id ~package_id selected

(* Observation only: unlike [frontier], this does not repair successor links
   or retain a new request. Keep known records alongside discovery problems;
   neither an empty list nor a list without issues proves absence. *)
let observe_for_request ~store ~installation_id ~package_id ~(binding : observation_binding) =
  let {base_path; goal_id; request_id; criterion; submitted_evidence} = binding in
  let observation_started_at = Time_compat.now () in
  let* _ = decode (key ~goal_id ~request_id ~attempt:0) in
  let* discovery, malformed = observe_subjects ~store in
  let issues =
    (if malformed || List.exists invalid_is_unattributable discovery.invalid
     then [Unattributable_metadata] else [])
    @ (if List.exists (noncanonical_affects_request ~goal_id ~request_id) discovery.invalid
       then [Noncanonical_request_metadata] else []) in
  let selected = List.filter (fun ((observed_goal,observed_request),_) ->
    observed_goal=goal_id && observed_request=request_id) discovery.subjects in
  let evidence_json items = `List (List.map
    Workspace_verification_store.submitted_evidence_item_to_yojson items) in
  let matches_binding retained =
    let subject = V.subject retained.original in
    String.equal (V.base_path retained.original) base_path
    && Goal_store.criterion_equal subject.criterion criterion
    && Yojson.Safe.equal (evidence_json (V.submitted_evidence retained.original))
      (evidence_json submitted_evidence) in
  let* observed_records, issues = List.fold_left (fun state selected ->
    let* records,issues = state in
    let* loaded = load_discovered ~store ~installation_id ~package_id [selected] in
    match loaded with
    | [retained] when matches_binding retained -> Ok (retained::records,issues)
    | [_] -> Ok (records,Original_binding_mismatch::issues)
    | [] | _::_::_ -> invalid "Goal review observation did not restore one selected record")
    (Ok ([],List.rev issues)) selected in
  Ok {binding; observation_started_at;
    observation_finished_at=Time_compat.now ();
    observed_records=List.sort (fun left right ->
      Int.compare (V.attempt left.original) (V.attempt right.original)) observed_records;
    issues=List.rev issues}

module Goal_map = Map.Make (String)

let inventory_by_goal ~store ~installation_id ~package_id =
  let* discovery = discover_subjects ~store in
  (* This grouping belongs to this one immutable observation. The original
     metadata remains the authority; no second index is persisted or reused. *)
  let groups,reversed_order = List.fold_left (fun (groups,order) (((goal_id,_),_) as row) ->
    match Goal_map.find_opt goal_id groups with
    | None -> Goal_map.add goal_id [row] groups,goal_id::order
    | Some previous -> Goal_map.add goal_id (row::previous) groups,order)
    (Goal_map.empty,[]) discovery.subjects in
  let destination_matches (_,record) =
    Owner.Record.installation_id record=installation_id
    && Owner.Record.package_id record=package_id in
  let groups = List.filter_map (fun goal_id ->
    let rows = List.rev (Goal_map.find goal_id groups) in
    if List.exists destination_matches rows then
      Some (goal_id,load_discovered ~store ~installation_id ~package_id rows)
    else None) (List.rev reversed_order) in
  Ok (groups, List.map (fun entry -> entry.request_id,entry.error) discovery.invalid)

let original (retained : retained) = retained.original
let run_identity (retained : retained) = retained.run
let destination (retained : retained) = retained.record.installation_id, retained.record.package_id
let progress (retained : retained) = retained.record.progress

let receipt_json retained (receipt : receipt) =
  let* digest = V.digest retained.original in
  Ok (`Assoc ["schema", `String "goal_verifier_receipt/v1";
    "original_digest", `String digest; "run", run_json receipt.run;
    (* This existing codec describes only the shared structured reviewer
       result. No Task request, producer or Task-store identity is reused. *)
    "result", Verifier_review_owner.result_to_json receipt.result;
    "tools", `List (List.map Verification_run_registry.tool_observation_to_yojson receipt.tools);
    "elapsed_s", `Float receipt.elapsed_s])

let tools_of_json = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* observation = Verification_run_registry.tool_observation_of_yojson value in
        loop (observation :: acc) rest
    in
    loop [] values
  | _ -> Error "Goal verifier receipt tools must be a list"

let receipt_of_json retained json =
  let* fields = object_fields ["schema"; "original_digest"; "run"; "result"; "tools"; "elapsed_s"] json in
  let* version = text "schema" fields in
  let* digest = text "original_digest" fields in
  let* expected_digest = V.digest retained.original in
  let* encoded_run = field "run" fields in
  let* run = run_of_json encoded_run in
  let* result_json = field "result" fields in
  let* result = Verifier_review_owner.result_of_json result_json in
  let* tools_json = field "tools" fields in
  let* tools = tools_of_json tools_json in
  let* elapsed_s = Json_util.require_field_float ~surface:scope "elapsed_s" fields in
  if version <> "goal_verifier_receipt/v1" || digest <> expected_digest
    || run <> retained.run || not (Float.is_finite elapsed_s) || elapsed_s < 0. then
    Error "Goal verifier receipt differs from its original or fixed run"
  else Ok {run; result; tools; elapsed_s}

(* Task reviews permit a reasonless APPROVE, but a Goal proof requires the
   model's stated evidence. Keep the exact reply in the receipt and project
   only its Goal admission disposition. No retryable provider failed here. *)
let goal_admission_result (result : AR.review_result) =
  match result.verdict with
  | Some (AR.Approve reason | Reject reason) when String.trim reason = "" ->
    {result with verdict=None; gate=AR.Invalid_verdict;
      fallback_reason=Some "Goal verdict has no stated reason";
      retryable_runtimes=[]}
  | None | Some (Approve _ | Reject _) -> result

let refusal_receipt retained (refusal : View.reviewer_refusal) =
  let evidence = refusal.evidence in
  let* fields = object_fields ["schema"; "receipt"; "disposition"] evidence in
  let* version = text "schema" fields in
  let* receipt_json = field "receipt" fields in
  let* receipt = receipt_of_json retained receipt_json in
  let* disposition = field "disposition" fields in
  if version <> "goal_verifier_refusal/v1"
      || (goal_admission_result receipt.result).AR.verdict <> None then
    Error "Goal verifier refusal is not an original non-verdict"
  else Ok (receipt, disposition)

(* A before-dispatch refusal reached no reviewer. Its evidence holds only what
   moved away from this original's lookup authority or answer format, so it
   has no receipt, result or evaluator runtime. *)
let moved_authority retained evidence =
  let* change = Change.of_json evidence |> Result.map_error (fun detail -> Original_invalid detail) in
  if Change.begins_at ~authority:(V.authority_binding retained.original)
      ~answer_format:(V.output_contract retained.original) change then Ok change
  else invalid "Goal before-dispatch refusal names another original's authority or answer format"

let restored_receipt retained =
  let decode_judgment json =
    let* receipt = decode (receipt_of_json retained json) in
    match receipt.result.AR.verdict with
    | Some _ -> Ok (Some receipt)
    | None -> invalid "Goal verifier judgment lacks a structured verdict" in
  match View.view (Progress.phase (progress retained)) with
  | View.Judged json -> decode_judgment json
  | View.Committing commit | View.Commit_unknown (commit,_) | View.Finished commit
  | View.Conflicted (commit,_) ->
    decode_judgment commit.judgment
  | View.Rejected {stage; refusal} ->
    (match stage, refusal with
     | View.Execution, View.Reviewer_refused r ->
       let* receipt, _ = decode (refusal_receipt retained r) in Ok (Some receipt)
     | View.Before_dispatch, View.Authority_moved _ ->
       let* _ = moved_authority retained (View.evidence_json refusal) in Ok None
     | (View.Execution,
        (View.Authority_moved _ | View.Run_ended _ | View.Owner_exited _))
     | (View.Before_dispatch,
        (View.Reviewer_refused _ | View.Run_ended _ | View.Owner_exited _)) ->
       invalid "Goal refusal evidence does not match its refusal stage")
  | View.Subdividing (refusal,_) | View.Subdivided (refusal,_) ->
    (match refusal with
     | View.Reviewer_refused r ->
       let* receipt, _ = decode (refusal_receipt retained r) in Ok (Some receipt)
     | View.Authority_moved _ | View.Run_ended _ | View.Owner_exited _ ->
       invalid "Goal refusal evidence does not match its refusal stage")
  | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ -> Ok None

let retained_judgment retained =
  let* judgment = match View.view (Progress.phase (progress retained)) with
    | View.Judged judgment -> Ok judgment
    | View.Committing commit | View.Commit_unknown (commit,_) | View.Finished commit
    | View.Conflicted (commit,_) ->
      Ok commit.judgment
    | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Rejected _
    | View.Subdividing _ | View.Subdivided _ ->
      Error (Execution_pending "Goal review has no retained structured judgment") in
  let* receipt = decode (receipt_of_json retained judgment) in
  match receipt.result.AR.verdict with
  | Some _ -> Ok judgment
  | None -> invalid "Goal judgment has no structured verdict"

let observed_receipt retained =
  let* receipt = restored_receipt retained in
  match receipt with
  | Some _ -> Ok receipt
  | None ->
    match View.view (Progress.phase (progress retained)) with
    | View.Admission_wait evidence ->
      let* receipt, _ = decode (refusal_receipt retained {evidence}) in Ok (Some receipt)
    | View.Dispatch_pending (Some (View.Outcome_unknown (`Assoc fields)))
        when List.assoc_opt "schema" fields = Some (`String "goal_verifier_unknown/v1") ->
      let* _ = decode (object_fields ["schema"; "receipt"; "observations"] (`Assoc fields)) in
      let* encoded = decode (field "receipt" fields) in
      Result.map Option.some (decode (receipt_of_json retained encoded))
    | View.Captured | View.Dispatch_pending None
    | View.Dispatch_pending (Some (View.Outcome_unknown _ | View.Waiting _ | View.Absent _))
    | View.Rejected {stage=View.Before_dispatch; _}
    | View.Subdividing (View.Authority_moved _, _)
    | View.Subdivided (View.Authority_moved _, _) -> Ok None
    | View.Judged _ | View.Committing _ | View.Commit_unknown _ | View.Finished _
    | View.Conflicted _ | View.Rejected {stage=View.Execution; _}
    | View.Subdividing ((View.Reviewer_refused _ | View.Run_ended _ | View.Owner_exited _), _)
    | View.Subdivided ((View.Reviewer_refused _ | View.Run_ended _ | View.Owner_exited _), _) ->
      invalid "Goal terminal observation lacks its original receipt"

let tool_observations retained =
  let* receipt = observed_receipt retained in
  match receipt with
  | Some receipt -> Ok receipt.tools
  | None ->
    match View.view (Progress.phase (progress retained)) with
    | View.Dispatch_pending (Some (View.Outcome_unknown evidence)) ->
      (match evidence with
       | `Assoc fields when List.assoc_opt "schema" fields = Some (`String "goal_verifier_unknown/v1") ->
         let* fields = decode (object_fields ["schema"; "receipt"; "observations"] evidence) in
         let* encoded = decode (field "receipt" fields) in
         let* receipt = decode (receipt_of_json retained encoded) in Ok receipt.tools
       | `Assoc _ ->
         let* fields = decode (object_fields ["cause"; "run"; "tools"; "observations"] evidence) in
         let* cause = decode (text "cause" fields) in
         let* _ = decode (interruption_of_label cause) in
         let* encoded_run = decode (field "run" fields) in
         let* run = decode (run_of_json encoded_run) in
         let* tools = decode (field "tools" fields) in
         if run = retained.run then decode (tools_of_json tools)
         else invalid "Goal interrupted observation differs from its fixed run"
       | _ -> invalid "Goal unknown observation is malformed")
    | View.Captured | View.Admission_wait _ | View.Dispatch_pending None
    | View.Rejected {stage=View.Before_dispatch; _}
    | View.Subdividing (View.Authority_moved _, _)
    | View.Subdivided (View.Authority_moved _, _) -> Ok []
    | View.Dispatch_pending (Some (View.Waiting _ | View.Absent _)) ->
      invalid "Goal dispatch observation has no retained tool receipt"
    | View.Judged _ | View.Committing _ | View.Commit_unknown _ | View.Finished _
    | View.Conflicted _ | View.Rejected {stage=View.Execution; _}
    | View.Subdividing ((View.Reviewer_refused _ | View.Run_ended _ | View.Owner_exited _), _)
    | View.Subdivided ((View.Reviewer_refused _ | View.Run_ended _ | View.Owner_exited _), _) ->
      invalid "Goal terminal observation lacks its original receipt"

let advance ~store retained event =
  serialized ~store ~kind:"record" ~identity:retained.record.request_id (fun () ->
  match Owner.advance ~store ~expected:retained.record ~event with
  | Error error -> Error (Store_unavailable (Owner.update_error_to_string error))
  | Ok (Owner.Unconfirmed detail) -> Error (Store_unavailable
      ("Goal progress publication is unconfirmed; restore its original before effects: " ^ detail))
  | Ok (Owner.Already_stored _) when event = Progress.Dispatch_intended ->
    Error (Execution_pending "Goal dispatch intent already exists; restore its outcome")
  | Ok (Owner.Stored record | Owner.Already_stored record) -> Ok {retained with record})

let reload ~store retained =
  let subject = V.subject retained.original in
  let* current = load ~store ~installation_id:retained.record.installation_id
    ~package_id:retained.record.package_id ~goal_id:subject.goal_id
    ~request_id:subject.request_id ~attempt:(V.attempt retained.original) in
  match current with
  | None -> invalid "Goal original disappeared before execution"
  | Some current when current.record.request_digest = retained.record.request_digest
      && Yojson.Safe.equal current.record.summary retained.record.summary -> Ok current
  | Some _ -> invalid "Goal original or fixed run changed before execution"

let record_observer ~store ~retained event =
  let* retained = reload ~store retained in
  advance ~store retained (Progress.Observer event)

let retryable_refusal retained evidence =
  let* receipt, disposition = decode (refusal_receipt retained evidence) in
  let* fields = decode (object_fields ["schema"; "certainty"; "observations"; "result"] disposition) in
  let* result = decode (field "result" fields) in
  let* () = if Yojson.Safe.equal result
      (Verifier_review_owner.result_to_json (goal_admission_result receipt.result))
    then Ok () else invalid "Goal refusal differs from its original result" in
  match (goal_admission_result receipt.result).AR.retryable_runtimes with
  | [] -> Ok false
  | _::_ -> let* () = decode (Verifier_review_owner.retry_result disposition) in Ok true

(* HIGH-RISK-UNREVIEWED: a new attempt asks the parent's question with the
   lookup authority prepared now. [authority] is forced only on the way to a
   new attempt, before its identity is allocated; restoring an intended
   successor uses its pinned body and never prepares authority again. A
   changed question forces it and allocates nothing. *)
let successor_of ~authority parent =
  let* current = authority () |> Result.map_error (fun detail -> Authority_unavailable detail) in
  V.successor ~authority:current parent.original |> Result.map_error (function
    | V.Question_changed -> Question_changed
    | V.Prompt_unavailable detail -> Authority_unavailable ("Goal review prompt unavailable: " ^ detail)
    | V.Successor_unavailable detail -> Original_invalid detail)

let select_frontier ~automatic ~authority ~store ~installation_id ~package_id ~goal_id ~request_id ~new_run =
  let* _ = decode (key ~goal_id ~request_id ~attempt:0) in
  let* discovery = discover_subjects ~store in
  let selected = List.filter (fun ((observed_goal,observed_request),_) ->
    observed_goal=goal_id && observed_request=request_id) discovery.subjects in
  let* () =
    if List.exists (noncanonical_affects_request ~goal_id ~request_id) discovery.invalid
       || (selected=[] && List.exists invalid_is_unattributable discovery.invalid)
    then invalid "Goal frontier metadata is unavailable and cannot be attributed"
    else Ok () in
  let* related = load_discovered ~store ~installation_id ~package_id selected in
  let related = List.sort (fun left right -> Int.compare (V.attempt left.original) (V.attempt right.original)) related in
  let restore_child parent successor =
    let* encoded = Owner.load_successor_request ~store ~scope successor
      |> Result.map_error (fun error -> Store_unavailable (Owner.error_to_string error)) in
    let* child, run, explicit_retry = decode (request_of_json encoded) in
    let* refusal = match View.view (Progress.phase (progress parent)) with
      | View.Subdividing (refusal,_) | View.Subdivided (refusal,_) -> Ok refusal
      | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
      | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _
      | View.Rejected _ -> invalid "Goal child lacks its terminal parent" in
    (* The refusal's stage says which evidence authorizes the child: an
       execution refusal's receipt, or what moved before dispatch. *)
    let* () = match refusal with
      | View.Reviewer_refused r ->
        let* automatic_retry = retryable_refusal parent r in
        let* _, disposition = decode (refusal_receipt parent r) in
        (match explicit_retry with
         | None when automatic_retry -> Ok ()
         | None -> invalid "Goal successor lacks a typed automatic retry"
         | Some grant when grant.parent_digest = parent.record.request_digest ->
           decode (Verifier_review_owner.terminal_result disposition)
         | Some _ -> invalid "Goal explicit retry names another parent")
      | View.Authority_moved _ ->
        let* _ = moved_authority parent (View.evidence_json refusal) in
        (match explicit_retry with
         | None -> Ok ()
         | Some _ -> invalid "Goal explicit retry cannot follow a before-dispatch refusal")
      | View.Run_ended _ | View.Owner_exited _ ->
        invalid "Goal refusal evidence does not match its refusal stage" in
    (* The parent's [Successor_intended] digest pins the child's whole body,
       so its lookup grants are the ones it was prepared with. Here the child
       must also ask the parent's question as its next attempt. *)
    let* child_key = decode (original_key child) in
    let* () = if successor.Progress.request_id = child_key
        && V.is_successor_of ~parent:parent.original child
        && run.run_id <> parent.run.run_id then Ok ()
      else invalid "Goal successor changed its question or reused the previous run" in
    let* child = retain_with_grant ~store ~installation_id ~package_id ~run ~explicit_retry child in
    let* _ = match View.view (Progress.phase (progress parent)) with
      | View.Subdividing _ -> advance ~store parent (Progress.Successor_observed successor.request_id)
      | View.Subdivided _ -> Ok parent
      | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
      | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _
      | View.Rejected _ -> invalid "Goal successor has no original parent intent" in
    Ok child in
  let allocate parent =
    let* child = successor_of ~authority parent in
    let run = new_run () in
    let* _ = decode (summary child run) in
    let* () = if run.run_id <> parent.run.run_id then Ok ()
      else invalid "Goal successor must have a distinct fixed run" in
    let* request_id = decode (original_key child) in
    let* successor = Owner.prepare_successor ~store ~scope ~request_id
      ~request:(request_json child run None)
      |> Result.map_error (fun error -> Store_unavailable (Owner.error_to_string error)) in
    let* parent = advance ~store parent (Progress.Successor_intended successor) in
    let* child = restore_child parent successor in
    Ok (Some child) in
  let rec walk parent rest =
    match View.view (Progress.phase (progress parent)), rest with
    | (View.Subdividing (_, successor) | View.Subdivided (_, successor)), _ ->
      let* () =
        match View.view (Progress.phase (progress parent)), rest with
        | View.Subdivided _, [] ->
          invalid "Goal successor original is missing after parent observed its intent"
        | View.Subdivided _, existing::_ when existing.record.request_id <> successor.Progress.request_id ->
          invalid "Goal successor original differs from its retained intent"
        | (View.Subdividing _ | View.Subdivided _), _ -> Ok ()
        | (View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
          | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _
          | View.Rejected _), _ ->
          invalid "Goal successor parent changed during restoration"
      in
      let* child = restore_child parent successor in
      (match rest with
       | [] -> walk child []
       | existing::tail ->
         if existing.record.request_digest = child.record.request_digest
           && existing.record.request_id = child.record.request_id
           && Yojson.Safe.equal existing.record.summary child.record.summary
         then walk child tail else invalid "Goal inventory differs from its original linked child")
    | View.Rejected {stage=View.Execution; refusal=View.Reviewer_refused r}, [] ->
      let* retryable = retryable_refusal parent r in
      if not retryable || not automatic then Ok (Some parent) else allocate parent
    | View.Rejected {stage=View.Execution;
                     refusal=(View.Authority_moved _ | View.Run_ended _ | View.Owner_exited _)}, [] ->
      invalid "Goal refusal evidence does not match its refusal stage"
    | View.Rejected {stage=View.Before_dispatch; refusal}, [] ->
      (* HIGH-RISK-UNREVIEWED: the same question met another lookup authority
         or answer format before dispatch. Its next attempt asks it again with
         the current authority, on a wake or an explicit request alike. *)
      let* _ = moved_authority parent (View.evidence_json refusal) in
      allocate parent
    | (View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
      | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _), [] ->
      Ok (Some parent)
    | (View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
      | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _
      | View.Rejected {stage=(View.Before_dispatch | View.Execution); _}), _::_ ->
      invalid "Goal child exists without the original successor intent" in
  match related with
  | [] -> Ok None
  | first::rest when V.attempt first.original = 0 -> walk first rest
  | _::_ -> invalid "Goal frontier is missing its first original attempt"

let frontier ~authority ~store ~installation_id ~package_id ~goal_id ~request_id ~new_run =
  serialized_subject ~store ~goal_id ~request_id (fun () ->
    select_frontier ~automatic:true ~authority ~store ~installation_id ~package_id ~goal_id ~request_id ~new_run)

let request_retry ~authority ~store ~installation_id ~package_id ~goal_id ~request_id ~requested_by ~new_run =
  serialized_subject ~store ~goal_id ~request_id (fun () ->
  let* _ = decode (text "requested_by" ["requested_by", `String requested_by]) in
  let* parent = select_frontier ~automatic:false ~authority ~store ~installation_id ~package_id
    ~goal_id ~request_id ~new_run in
  match parent with
  | None -> Ok ()
  | Some parent ->
    match View.view (Progress.phase (progress parent)) with
    | View.Rejected {stage=View.Execution; refusal=View.Reviewer_refused r} ->
      let* _ = retryable_refusal parent r in
      let* _, disposition = decode (refusal_receipt parent r) in
      let* () = decode (Verifier_review_owner.terminal_result disposition) in
      let* child = successor_of ~authority parent in
      let run = new_run () in
      let* _ = decode (summary child run) in
      let* () = if run.run_id <> parent.run.run_id then Ok () else invalid "Goal retry reused its parent's run" in
      let grant = Some {parent_digest=parent.record.request_digest; requested_by} in
      let* child_key = decode (original_key child) in
      let* successor = Owner.prepare_successor ~store ~scope ~request_id:child_key
        ~request:(request_json child run grant)
        |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
      let* _ = advance ~store parent (Progress.Successor_intended successor) in
      let* _ = select_frontier ~automatic:false ~authority ~store ~installation_id ~package_id
        ~goal_id ~request_id ~new_run in Ok ()
    | View.Rejected {stage=View.Execution;
                     refusal=(View.Authority_moved _ | View.Run_ended _ | View.Owner_exited _)} ->
      invalid "Goal refusal evidence does not match its refusal stage"
    | View.Dispatch_pending (Some (View.Outcome_unknown _)) ->
      Error (Execution_pending "The original Goal verification outcome is unknown; no new review was started. Inspect its original run.")
    | View.Dispatch_pending (None | Some (View.Waiting _ | View.Absent _)) ->
      Error (Execution_pending "The original Goal verification may still be running; no new review was started. Inspect its original run.")
    | View.Captured | View.Admission_wait _ | View.Judged _ | View.Committing _ | View.Commit_unknown _
    | View.Finished _ | View.Conflicted _ | View.Rejected {stage=View.Before_dispatch; _}
    | View.Subdividing _ | View.Subdivided _ -> Ok ())

let run ?on_tool_result ?sw ~store ~retained ~authority ~provider_rest () =
  let* retained = reload ~store retained in
  let* restored = restored_receipt retained in
  match restored with
  | Some receipt -> Ok receipt
  | None ->
    let* () = match View.view (Progress.phase (progress retained)) with
      | View.Captured -> Ok ()
      | View.Admission_wait evidence ->
        let* receipt, disposition = decode (refusal_receipt retained {evidence}) in
        let* () = decode (Verifier_review_owner.validate_admission disposition) in
        let agrees = match disposition with
          | `Assoc fields -> (match List.assoc_opt "result" fields with
              | Some json -> Yojson.Safe.equal json (Verifier_review_owner.result_to_json receipt.result)
              | None -> false)
          | _ -> false in
        if agrees then Ok () else invalid "Goal admission observation differs from its original receipt"
      | View.Dispatch_pending _ -> Error (Execution_pending "Goal reviewer may have dispatched; no automatic replay")
      | View.Rejected {stage=View.Before_dispatch; refusal} ->
        (* Already refused before dispatch: its next attempt asks again. *)
        let* change = moved_authority retained (View.evidence_json refusal) in
        Error (Authority_changed change)
      | View.Judged _ | View.Committing _ | View.Commit_unknown _ | View.Finished _ | View.Conflicted _
      | View.Rejected {stage=View.Execution; _} | View.Subdividing _ | View.Subdivided _ ->
        invalid "Goal review frontier changed" in
    let* () = if V.question_matches retained.original authority then Ok ()
      else Error Question_changed in
    (* HIGH-RISK-UNREVIEWED: a retained attempt whose lookup authority or answer
       format is not the current one is refused before dispatch. The refusal
       keeps only what moved; the next attempt asks the same question with the
       current authority, so the old grants never reach a reviewer. *)
    let* () = match V.authority_change retained.original authority with
      | Error detail -> invalid detail
      | Ok (Some change) ->
        let* _ = advance ~store retained
          (Progress.Refused {stage=Progress.Before_dispatch; evidence=Change.to_json change}) in
        Error (Authority_changed change)
      | Ok None ->
        (* The same authority digest names the same tools, so other names mean
           the retained original disagrees with its own digest. *)
        if V.lookup_schemas retained.original = List.map (fun (tool : Types_core.tool_schema) -> tool.name)
            (A.goal_review_lookup authority).schemas then Ok ()
        else invalid "Goal retained lookup tools differ from their authority digest" in
    let* dispatching = advance ~store retained Progress.Dispatch_intended in
    let current = ref dispatching in
    let unknown = ref false in
    let reached = ref false in
    let facts = ref [] in
    let tools = ref [] in
    let exception Retention_failed of error in
    let on_execution = function
      | AR.Admission_refused -> facts := `Assoc ["fact", `String "admission_refused"] :: !facts
      | Reply_received {runtime_id} -> reached := true;
        facts := `Assoc ["fact", `String "reply_received"; "runtime_id", `String runtime_id] :: !facts
      | Attempt_failed {runtime_id; certainty; error; failure=_} ->
        let fact = match certainty with
          | AR.Before_dispatch -> "before_dispatch"
          | Definite_refusal -> reached := true; "definite_refusal"
          | Outcome_unknown -> unknown := true; reached := true; "outcome_unknown" in
        facts := `Assoc ["fact", `String fact; "runtime_id", `String runtime_id;
          "error_category", `String Agent_core.Error.(category error |> category_label)] :: !facts in
    let observed_tool ~input result =
      tools := Verification_run_registry.observe_tool_result ~input
        ~finished_at:(Time_compat.now ()) result :: !tools;
      Option.iter (fun callback -> callback ~input result) on_tool_result in
    let retain_reply result =
      let receipt = {run=retained.run; result; tools=List.rev !tools;
        elapsed_s=max 0. (Time_compat.now () -. retained.run.started_at)} in
      let encoded = match receipt_json retained receipt with
        | Ok json -> json | Error detail -> raise (Retention_failed (Original_invalid detail)) in
      let admission = goal_admission_result result in
      let disposition = `Assoc (["schema", `String (if !reached then "verifier_review_refusal/v1"
          else "verifier_admission_refusal/v1");
        "observations", `List (List.rev !facts); "result", Verifier_review_owner.result_to_json admission]
        @ if !reached then ["certainty", `String "definite"] else []) in
      let refusal = `Assoc ["schema", `String "goal_verifier_refusal/v1";
        "receipt", encoded; "disposition", disposition] in
      let event = match !unknown, admission.AR.verdict, !reached with
        | true, _, _ -> Progress.Execution_observed (Progress.Outcome_unknown
            (`Assoc ["schema", `String "goal_verifier_unknown/v1";
              "receipt", encoded; "observations", `List (List.rev !facts)]))
        | false, Some _, _ -> Progress.Judgment_retained encoded
        | false, None, false -> Progress.Admission_declined refusal
        | false, None, true -> Progress.Refused {stage=Progress.Execution; evidence=refusal} in
      match advance ~store !current event with
      | Ok saved -> current := saved
      | Error error -> raise (Retention_failed error) in
    try
      let subject = V.subject retained.original in
      ignore (AR.run_retained ~system_prompt:(V.system_instructions retained.original)
        ~prompt:(V.prompt retained.original) ~on_execution ~on_verdict:retain_reply
        ~on_tool_result:observed_tool ?sw
        ~log_info:(fun message -> Log.Misc.info "[goal-proof-review] goal_id=%s %s" subject.goal_id message)
        ~log_warn:(fun message -> Log.Misc.warn "[goal-proof-review] goal_id=%s %s" subject.goal_id message)
        ~lookup:(A.goal_review_lookup authority) ~provider_rest
        ~base_path:(A.goal_review_base_path authority) ());
      if !unknown then Error (Execution_pending "Goal reviewer outcome unknown; original retained")
      else
        (match View.view (Progress.phase (progress !current)) with
         | View.Admission_wait evidence ->
           let* receipt, _ = decode (refusal_receipt !current {evidence}) in Ok receipt
         | View.Captured | View.Dispatch_pending _ | View.Judged _ | View.Committing _
         | View.Commit_unknown _ | View.Finished _ | View.Conflicted _ | View.Rejected _
         | View.Subdividing _ | View.Subdivided _ ->
           let* receipt = restored_receipt !current in
           match receipt with Some receipt -> Ok receipt | None -> invalid "Goal reviewer returned without retained reply")
    with
    | Retention_failed error -> Error error
    | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      let cause = match exn with
        | Eio.Cancel.Cancelled _ -> Cancelled
        | _ -> Raised in
      Eio.Cancel.protect (fun () ->
        match reload ~store retained with
        | Ok saved -> (match View.view (Progress.phase (progress saved)) with
            | View.Dispatch_pending _ ->
              (match advance ~store saved (Progress.Execution_observed
                (Progress.Outcome_unknown (`Assoc ["cause", `String (interruption_label cause);
                  "run", run_json retained.run;
                  "tools", `List (List.map Verification_run_registry.tool_observation_to_yojson (List.rev !tools));
                  "observations", `List (List.rev !facts)]))) with
               | Ok _ -> ()
               | Error error -> Log.Misc.error "Goal interrupted review retention failed: %s" (error_to_string error))
            | View.Captured | View.Admission_wait _ | View.Judged _ | View.Committing _
            | View.Commit_unknown _ | View.Finished _ | View.Conflicted _ | View.Rejected _
            | View.Subdividing _ | View.Subdivided _ -> ())
        | Error error -> Log.Misc.error "Goal interrupted review reload failed: %s" (error_to_string error));
      Printexc.raise_with_backtrace exn backtrace

let commit ~store ~retained ~change ~observe ~apply =
  let* retained = reload ~store retained in
  let pending detail = Error (Execution_pending detail) in
  let validate commit =
    let* receipt = decode (receipt_of_json retained commit.Progress.judgment) in
    let* digest = decode (V.digest retained.original) in
    let* () = match receipt.result.AR.verdict, commit.change.after with
      | Some _, `Assoc fields when List.assoc_opt "original_digest" fields = Some (`String digest)
          && (match List.assoc_opt "receipt" fields with
            (* The owner canonicalizes integral JSON numbers when retaining
               progress. Decoding a receipt restores typed float metadata;
               re-encoding it would change 0 back to 0.0. Authenticate the
               exact retained judgment after its typed validation above. *)
            | Some value -> Yojson.Safe.equal value commit.judgment | None -> false) -> Ok ()
      | None, _ | Some _, _ -> invalid "Goal commit intent differs from its original structured judgment" in
    Ok () in
  let confirm saved commit =
    match observe commit.Progress.change with
    | Error detail ->
      let* _ = advance ~store saved (Progress.Commit_uncertain
        (`Assoc ["cause", `String "goal_commit_observation_unavailable"; "detail", `String detail])) in
      pending ("Goal commit observation unavailable: " ^ detail)
    | Ok observed when Yojson.Safe.equal observed commit.change.after ->
      let* _ = advance ~store saved (Progress.Commit_observed observed) in Ok ()
    | Ok observed when Yojson.Safe.equal observed commit.change.before ->
      let* saved = advance ~store saved (Progress.Commit_retry_observed observed) in
      (match apply commit.change with
       | Error detail ->
         let* _ = advance ~store saved (Progress.Commit_uncertain (`String detail)) in pending detail
       | Ok () ->
         (match observe commit.change with
          | Ok observed when Yojson.Safe.equal observed commit.change.after ->
            let* _ = advance ~store saved (Progress.Commit_observed observed) in Ok ()
          | Ok observed ->
            let* _ = advance ~store saved (Progress.Commit_uncertain observed) in
            pending "Goal commit returned without its exact authoritative after-state"
          | Error detail ->
            let* _ = advance ~store saved (Progress.Commit_uncertain (`String detail)) in pending detail))
    | Ok observed ->
      let* _ = advance ~store saved (Progress.Commit_conflicted observed) in
      pending "Goal commit conflicts with the authoritative original subject" in
  let recover saved commit =
    let* () = validate commit in
    let* saved = match View.view (Progress.phase (progress saved)) with
      | View.Committing _ -> advance ~store saved (Progress.Commit_uncertain
          (`Assoc ["cause", `String "original_goal_commit_requires_observation"]))
      | View.Commit_unknown _ -> Ok saved
      | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Judged _
      | View.Finished _ | View.Conflicted _ | View.Rejected _ | View.Subdividing _
      | View.Subdivided _ ->
        invalid "Goal commit recovery lacks its original intent" in
    confirm saved commit in
  match View.view (Progress.phase (progress retained)) with
  | View.Finished commit -> validate commit
  | View.Committing commit | View.Commit_unknown (commit, _) -> recover retained commit
  | View.Judged judgment ->
    let commit = {Progress.judgment; change} in
    let* () = validate commit in
    let* saved = advance ~store retained (Progress.Commit_intended change) in
    recover saved commit
  | View.Captured | View.Admission_wait _ | View.Dispatch_pending _ | View.Rejected _
  | View.Subdividing _ | View.Subdivided _ ->
    pending "Goal proof cannot commit without its original retained judgment"
  | View.Conflicted _ -> pending "Goal proof is conflicted; the original host must resolve it"
