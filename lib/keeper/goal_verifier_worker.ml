module V = Goal_verifier_original
module A = Verification_authority_tools
module AR = Task.Anti_rationalization
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress

let ( let* ) = Result.bind
let scope = "goal-proof-reviews"
let tool_name = "goal_proof_review"

type run_identity = {run_id : string; started_at : float}
type receipt = {
  run : run_identity;
  result : AR.review_result;
  tools : Verification_run_registry.tool_observation list;
  elapsed_s : float;
}
type error = Store_unavailable of string | Original_invalid of string
  | Authority_changed of string | Execution_pending of string
type retained = {record : Owner.retained; original : V.t; run : run_identity}

let invalid detail = Error (Original_invalid detail)
let decode result = Result.map_error (fun detail -> Original_invalid detail) result
let text key fields = Json_util.require_field_string ~surface:scope key fields
let field key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error (scope ^ "." ^ key ^ " is required")
let object_fields allowed = function
  | `Assoc fields -> let* () = Json_util.reject_unknown_fields ~surface:scope ~allowed fields in Ok fields
  | _ -> Error (scope ^ " must be an object")
let run_json (run : run_identity) =
  `Assoc ["run_id", `String run.run_id; "started_at", `Float run.started_at]
let run_of_json json =
  let* fields = object_fields ["run_id"; "started_at"] json in
  let* run_id = text "run_id" fields in
  let* started_at = Json_util.require_field_float ~surface:scope "started_at" fields in
  if Float.is_finite started_at then Ok {run_id; started_at}
  else Error "Goal verifier run time must be finite"

(* The staged successor and its published owner name the very same complete
   request bytes. In particular, recovery cannot invent another run after the
   parent intent has become durable. The summary remains an observation index. *)
let request_json original run =
  `Assoc ["schema", `String "goal_verifier_request/v1";
    "original", V.to_json original; "run", run_json run]

let request_of_json json =
  let* fields = object_fields ["schema"; "original"; "run"] json in
  let* version = text "schema" fields in
  let* original_json = field "original" fields in
  let* original = V.of_json original_json in
  let* encoded_run = field "run" fields in
  let* run = run_of_json encoded_run in
  if version = "goal_verifier_request/v1" then Ok (original, run)
  else Error "unknown Goal verifier request schema"

let key ~goal_id ~request_id ~attempt =
  if String.trim goal_id = "" || String.trim request_id = "" || attempt < 0 then
    Error "Goal verifier original requires its exact nonblank subject and nonnegative attempt"
  else Ok (Yojson.Safe.to_string (`List [`String goal_id; `String request_id; `Int attempt]))
let original_key original =
  let subject = V.subject original in
  key ~goal_id:subject.goal_id ~request_id:subject.request_id ~attempt:(V.attempt original)
let summary original run =
  let* digest = V.digest original in
  let* _ = run_of_json (run_json run) in
  Ok (`Assoc ["schema", `String "goal_verifier_owner/v1";
    "original_digest", `String digest; "run", run_json run])

let validate_record ~installation_id ~package_id (record : Owner.retained) =
  let* original, run = decode (request_of_json record.request) in
  let* expected_key = decode (original_key original) in
  let* fields = decode (object_fields ["schema"; "original_digest"; "run"] record.summary) in
  let* summary_run = decode (field "run" fields) in
  let* summary_run = decode (run_of_json summary_run) in
  let* expected_summary = decode (summary original run) in
  let* expected_digest = decode (Owner.request_digest (request_json original run)) in
  if record.scope <> scope || record.tool <> tool_name || record.request_id <> expected_key
    || record.request_digest <> expected_digest || summary_run <> run
    || not (Yojson.Safe.equal expected_summary record.summary) then
    invalid "Goal verifier owner identity or complete original differs"
  else if record.installation_id <> installation_id || record.package_id <> package_id then
    Error (Authority_changed "Goal verifier original belongs to another destination")
  else Ok {record; original; run}

let load ~store ~installation_id ~package_id ~goal_id ~request_id ~attempt =
  let* owner_key = decode (key ~goal_id ~request_id ~attempt) in
  let* record = Owner.load ~store ~scope ~request_id:owner_key
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  match record with
  | None -> Ok None
  | Some record -> Result.map Option.some (validate_record ~installation_id ~package_id record)

let retain ~store ~installation_id ~package_id ~run original =
  let* request_id = decode (original_key original) in
  let* summary = decode (summary original run) in
  let* () = Owner.retain ~store ~scope ~request_id ~installation_id ~package_id
    ~tool:tool_name ~summary ~request:(request_json original run)
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  let subject = V.subject original in
  let* loaded = load ~store ~installation_id ~package_id ~goal_id:subject.goal_id
    ~request_id:subject.request_id ~attempt:(V.attempt original) in
  match loaded with Some retained -> Ok retained | None -> invalid "retained Goal original is absent"

let read_all ~store =
  let* records = Owner.load_scope ~store ~scope
    |> Result.map_error (fun e -> Store_unavailable (Owner.error_to_string e)) in
  let* reversed = List.fold_left (fun state (record : Owner.retained) ->
    let* acc = state in
    let* retained = validate_record ~installation_id:record.installation_id ~package_id:record.package_id record in
    Ok (retained::acc)) (Ok []) records in
  Ok (List.rev reversed)

let inventory ~store ~installation_id ~package_id =
  let* records = read_all ~store in
  Ok (List.filter (fun retained -> retained.record.installation_id = installation_id
    && retained.record.package_id = package_id) records)

let original (retained : retained) = retained.original
let run_identity (retained : retained) = retained.run
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
  let* tools = match tools_json with
    | `List values ->
      List.fold_right (fun value tail ->
        let* observation = Verification_run_registry.tool_observation_of_yojson value in
        let* tail = tail in Ok (observation::tail)) values (Ok [])
    | _ -> Error "Goal verifier receipt tools must be a list" in
  let* elapsed_s = Json_util.require_field_float ~surface:scope "elapsed_s" fields in
  if version <> "goal_verifier_receipt/v1" || digest <> expected_digest
    || run <> retained.run || not (Float.is_finite elapsed_s) || elapsed_s < 0. then
    Error "Goal verifier receipt differs from its original or fixed run"
  else Ok {run; result; tools; elapsed_s}

let refusal_receipt retained evidence =
  let* fields = object_fields ["schema"; "receipt"; "disposition"] evidence in
  let* version = text "schema" fields in
  let* receipt_json = field "receipt" fields in
  let* receipt = receipt_of_json retained receipt_json in
  let* disposition = field "disposition" fields in
  if version <> "goal_verifier_refusal/v1" || receipt.result.AR.verdict <> None then
    Error "Goal verifier refusal is not an original non-verdict"
  else Ok (receipt, disposition)

let restored_receipt retained =
  let decode_judgment json =
    let* receipt = decode (receipt_of_json retained json) in
    match receipt.result.AR.verdict with
    | Some _ -> Ok (Some receipt)
    | None -> invalid "Goal verifier judgment lacks a structured verdict" in
  match Progress.phase (progress retained) with
  | Progress.Judged json -> decode_judgment json
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    decode_judgment commit.judgment
  | Rejected refusal | Subdividing (refusal,_) | Subdivided (refusal,_) ->
    let* receipt, _ = decode (refusal_receipt retained refusal.evidence) in Ok (Some receipt)
  | Captured | Admission_wait _ | Dispatch_pending _ -> Ok None

let retained_judgment retained =
  let* judgment = match Progress.phase (progress retained) with
    | Progress.Judged judgment -> Ok judgment
    | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
      Ok commit.judgment
    | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
      Error (Execution_pending "Goal review has no retained structured judgment") in
  let* receipt = decode (receipt_of_json retained judgment) in
  match receipt.result.AR.verdict with
  | Some _ -> Ok judgment
  | None -> invalid "Goal judgment has no structured verdict"

let advance ~store retained event =
  match Owner.advance ~store ~expected:retained.record ~event with
  | Error error -> Error (Store_unavailable (Owner.update_error_to_string error))
  | Ok (Owner.Unconfirmed detail) -> Error (Store_unavailable
      ("Goal progress publication is unconfirmed; restore its original before effects: " ^ detail))
  | Ok (Owner.Already_stored _) when event = Progress.Dispatch_intended ->
    Error (Execution_pending "Goal dispatch intent already exists; restore its outcome")
  | Ok (Owner.Stored record | Owner.Already_stored record) -> Ok {retained with record}

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

let retryable_refusal retained evidence =
  let* receipt, disposition = decode (refusal_receipt retained evidence) in
  let* fields = decode (object_fields ["schema"; "certainty"; "observations"; "result"] disposition) in
  let* result = decode (field "result" fields) in
  let* () = if Yojson.Safe.equal result (Verifier_review_owner.result_to_json receipt.result)
    then Ok () else invalid "Goal refusal differs from its original result" in
  match receipt.result.AR.retryable_runtimes with
  | [] -> Ok false
  | _::_ -> let* () = decode (Verifier_review_owner.retry_result disposition) in Ok true

let frontier ~store ~installation_id ~package_id ~goal_id ~request_id ~new_run =
  let* _ = decode (key ~goal_id ~request_id ~attempt:0) in
  let* records = read_all ~store in
  let* related = List.fold_left (fun state retained ->
    let* related = state in
    let subject = V.subject retained.original in
    if subject.goal_id <> goal_id || subject.request_id <> request_id then Ok related
    else if retained.record.installation_id <> installation_id || retained.record.package_id <> package_id
    then Error (Authority_changed "Goal frontier belongs to another original destination")
    else Ok (retained::related)) (Ok []) records in
  let related = List.sort (fun left right -> Int.compare (V.attempt left.original) (V.attempt right.original)) related in
  let restore_child parent successor =
    let* encoded = Owner.load_successor_request ~store ~scope successor
      |> Result.map_error (fun error -> Store_unavailable (Owner.error_to_string error)) in
    let* child, run = decode (request_of_json encoded) in
    let* expected = decode (V.successor parent.original) in
    let* child_key = decode (original_key child) in
    let* () = if successor.Progress.request_id = child_key
        && Yojson.Safe.equal (V.to_json expected) (V.to_json child)
        && run.run_id <> parent.run.run_id then Ok ()
      else invalid "Goal successor changed its complete original or reused the previous run" in
    let* child = retain ~store ~installation_id ~package_id ~run child in
    let* _ = match Progress.phase (progress parent) with
      | Progress.Subdividing _ -> advance ~store parent (Progress.Successor_observed successor.request_id)
      | Subdivided _ -> Ok parent
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ -> invalid "Goal successor has no original parent intent" in
    Ok child in
  let rec walk parent rest =
    match Progress.phase (progress parent), rest with
    | (Progress.Subdividing (refusal, successor) | Subdivided (refusal, successor)), _ ->
      let* retryable = retryable_refusal parent refusal.evidence in
      let* () = if retryable then Ok () else invalid "Goal successor lacks a definite typed retry" in
      let* child = restore_child parent successor in
      (match rest with
       | [] -> walk child []
       | existing::tail ->
         if existing.record.request_digest = child.record.request_digest
           && existing.record.request_id = child.record.request_id
           && Yojson.Safe.equal existing.record.summary child.record.summary
         then walk child tail else invalid "Goal inventory differs from its original linked child")
    | Rejected {stage=Progress.Execution; evidence}, [] ->
      let* retryable = retryable_refusal parent evidence in
      if not retryable then Ok (Some parent)
      else
        let* child = decode (V.successor parent.original) in
        let run = new_run () in
        let* _ = decode (summary child run) in
        let* () = if run.run_id <> parent.run.run_id then Ok ()
          else invalid "Goal successor must have a distinct fixed run" in
        let* request_id = decode (original_key child) in
        let* successor = Owner.prepare_successor ~store ~scope ~request_id
          ~request:(request_json child run)
          |> Result.map_error (fun error -> Store_unavailable (Owner.error_to_string error)) in
        let* parent = advance ~store parent (Progress.Successor_intended successor) in
        let* child = restore_child parent successor in
        Ok (Some child)
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}), [] -> Ok (Some parent)
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected {stage=(Progress.Before_dispatch | Progress.Execution);_}), _::_ ->
      invalid "Goal child exists without the original successor intent" in
  match related with
  | [] -> Ok None
  | first::rest when V.attempt first.original = 0 -> walk first rest
  | _::_ -> invalid "Goal frontier is missing its first original attempt"

let run ?on_tool_result ?sw ~store ~retained ~authority ~provider_rest () =
  let* retained = reload ~store retained in
  let* restored = restored_receipt retained in
  match restored with
  | Some receipt -> Ok receipt
  | None ->
    let* () = match Progress.phase (progress retained) with
      | Captured -> Ok ()
      | Admission_wait evidence ->
        let* receipt, disposition = decode (refusal_receipt retained evidence) in
        let* () = decode (Verifier_review_owner.validate_admission disposition) in
        let agrees = match disposition with
          | `Assoc fields -> (match List.assoc_opt "result" fields with
              | Some json -> Yojson.Safe.equal json (Verifier_review_owner.result_to_json receipt.result)
              | None -> false)
          | _ -> false in
        if agrees then Ok () else invalid "Goal admission observation differs from its original receipt"
      | Dispatch_pending _ -> Error (Execution_pending "Goal reviewer may have dispatched; no automatic replay")
      | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected _ | Subdividing _ | Subdivided _ -> invalid "Goal review frontier changed" in
    let* () = if V.matches_authority retained.original authority then Ok ()
      else Error (Authority_changed "Goal subject or complete lookup authority differs") in
    let* () = if String.equal (V.output_contract retained.original)
        (Verifier_review_original.canonical_output_contract ()) then Ok ()
      else invalid "Goal retained output contract differs from the reviewer protocol" in
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
      | Attempt_failed {runtime_id; certainty; error} ->
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
      let disposition = `Assoc (["schema", `String (if !reached then "verifier_review_refusal/v1"
          else "verifier_admission_refusal/v1");
        "observations", `List (List.rev !facts); "result", Verifier_review_owner.result_to_json result]
        @ if !reached then ["certainty", `String "definite"] else []) in
      let refusal = `Assoc ["schema", `String "goal_verifier_refusal/v1";
        "receipt", encoded; "disposition", disposition] in
      let event = match !unknown, result.AR.verdict, !reached with
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
        (match Progress.phase (progress !current) with
         | Admission_wait evidence -> let* receipt, _ = decode (refusal_receipt !current evidence) in Ok receipt
         | Captured | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
         | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
           let* receipt = restored_receipt !current in
           match receipt with Some receipt -> Ok receipt | None -> invalid "Goal reviewer returned without retained reply")
    with
    | Retention_failed error -> Error error
    | Eio.Cancel.Cancelled _ as exn ->
      Eio.Cancel.protect (fun () ->
        match reload ~store retained with
        | Ok saved -> (match Progress.phase (progress saved) with
            | Dispatch_pending _ -> ignore (advance ~store saved (Progress.Execution_observed
                (Progress.Outcome_unknown (`Assoc ["cause", `String "review_cancelled";
                  "run", run_json retained.run;
                  "tools", `List (List.map Verification_run_registry.tool_observation_to_yojson (List.rev !tools));
                  "observations", `List (List.rev !facts)]))))
            | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
            | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> ())
        | Error _ -> ());
      raise exn

let commit ~store ~retained ~change ~observe ~apply =
  let* retained = reload ~store retained in
  let pending detail = Error (Execution_pending detail) in
  let validate commit =
    let* receipt = decode (receipt_of_json retained commit.Progress.judgment) in
    let* digest = decode (V.digest retained.original) in
    let* encoded = decode (receipt_json retained receipt) in
    let* () = match receipt.result.AR.verdict, commit.change.after with
      | Some _, `Assoc fields when List.assoc_opt "original_digest" fields = Some (`String digest)
          && (match List.assoc_opt "receipt" fields with
            | Some value -> Yojson.Safe.equal value encoded | None -> false) -> Ok ()
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
    let* saved = match Progress.phase (progress saved) with
      | Progress.Committing _ -> advance ~store saved (Progress.Commit_uncertain
          (`Assoc ["cause", `String "original_goal_commit_requires_observation"]))
      | Commit_unknown _ -> Ok saved
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
        invalid "Goal commit recovery lacks its original intent" in
    confirm saved commit in
  match Progress.phase (progress retained) with
  | Progress.Finished commit -> validate commit
  | Committing commit | Commit_unknown (commit, _) -> recover retained commit
  | Judged judgment ->
    let commit = {Progress.judgment; change} in
    let* () = validate commit in
    let* saved = advance ~store retained (Progress.Commit_intended change) in
    recover saved commit
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    pending "Goal proof cannot commit without its original retained judgment"
  | Conflicted _ -> pending "Goal proof is conflicted; the original host must resolve it"
