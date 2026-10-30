(** Durable owner of one verifier review original. *)

module V = Verifier_review_original
module Owner = Lane_addon_tool_request_owner

open Result.Syntax

type store = Lane_addon_store.t

let scope = "verifier-reviews"
let tool_name = "verifier_review"

let attempt_request_id ~verification_id ~attempt =
  if attempt < 0
  then Error "verifier review attempt must be a non-negative integer"
  else Ok (Printf.sprintf "%s:attempt-%d" verification_id attempt)

(* The owner record requires a summary. It must be a short canonical digest of
   the fixed subject and lookup grants, never a mutable pointer to current
   state, so the stored record names the same original the caller prepared.
   The digest is canonical, so equal originals have equal summaries. *)
let summary_of (original : V.t) : (Yojson.Safe.t, string) result =
  let* digest = V.digest original in
  Ok
    (`Assoc
      [ "schema", `String V.schema
      ; "verification_id", `String (V.verification_id original)
      ; "attempt", `Int (V.attempt original)
      ; "original_digest", `String digest
      ])

type retain_error =
  | Original_invalid of string
  | Identity_mismatch of string
  | Retain_store_unavailable of string
  | Already_retained of string

(* [load_error] deliberately names its store failure differently from
   [retain_error]'s [Retain_store_unavailable]: the two error types are not a
   recursion group, and sharing a constructor name here made the type-checker
   merge them, hiding [Already_retained] from [retain]'s mapping. *)
type load_error =
  | Load_store_unavailable of string
  | Not_found
  | Corrupt_original of string

type verification_scope = All_verifications | Verification of string

let map_retain_error ~request_id (err : Owner.error) : retain_error =
  match err with
  | Owner.Binding_conflict -> Already_retained request_id
  | Owner.Store_unavailable detail -> Retain_store_unavailable detail
  | Owner.Invalid_identity detail -> Identity_mismatch detail
  | Owner.Invalid_request detail -> Original_invalid detail

let retain ~store ~verification_id ~attempt ~installation_id ~package_id original =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Identity_mismatch detail)
  in
  (* The original's internal identity must match the key it is stored under,
     so a value prepared for one verification cannot be applied to a different
     attempt's slot. *)
  let* () =
    if String.equal (V.verification_id original) verification_id
       && V.attempt original = attempt
    then Ok ()
    else
      Error
        (Identity_mismatch
           (Printf.sprintf
              "original identity %s:%d does not match key %s:%d"
              (V.verification_id original)
              (V.attempt original)
              verification_id
              attempt))
  in
  let* request_json =
    (match V.to_json original with
     | json -> Ok json
     | exception exn -> Error (Printexc.to_string exn))
    |> Result.map_error (fun detail -> Original_invalid detail)
  in
  let* summary =
    summary_of original |> Result.map_error (fun detail -> Original_invalid detail)
  in
  (* Delegate the keep-exactly-one guarantee to [Owner.retain]: it compares the
     whole record (scope, request_id, installation, package, tool, digest,
     summary and body) and is idempotent only when every destination field
     matches, so a retain aimed at a different installation, package or tool
     is a [Binding_conflict], never an overwrite. We add nothing on top. *)
  Owner.retain
    ~store
    ~scope
    ~request_id
    ~installation_id
    ~package_id
    ~tool:tool_name
    ~summary
    ~request:request_json
  |> Result.map_error (map_retain_error ~request_id)

let load ~store ~verification_id ~attempt =
  let* request_id =
    attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Load_store_unavailable detail)
  in
  let* existing =
    Owner.load ~store ~scope ~request_id
    |> Result.map_error (function
      | Owner.Store_unavailable detail -> Load_store_unavailable detail
      | Owner.Binding_conflict -> Load_store_unavailable "verifier review owner binding conflict"
      | Owner.Invalid_identity detail -> Load_store_unavailable detail
      | Owner.Invalid_request detail -> Load_store_unavailable detail)
  in
  match existing with
  | None -> Error Not_found
  | Some record ->
    (match V.of_json record.Owner.request with
     | Ok original ->
       if String.equal (V.verification_id original) verification_id
          && V.attempt original = attempt
       then Ok original
       else
         Error
           (Corrupt_original
              (Printf.sprintf
                 "stored original identity %s:%d does not match key %s:%d"
                 (V.verification_id original)
                 (V.attempt original)
                 verification_id
                 attempt))
     | Error detail -> Error (Corrupt_original detail))

let load_for_destination ~store ~verification_id ~attempt ~installation_id ~package_id =
  let* original = load ~store ~verification_id ~attempt in
  let* request_id = attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun detail -> Corrupt_original detail) in
  let* existing = Owner.load ~store ~scope ~request_id
    |> Result.map_error (fun error -> Load_store_unavailable (Owner.error_to_string error)) in
  match existing with
  | None -> Error Not_found
  | Some record ->
    let* expected_summary = summary_of original
      |> Result.map_error (fun detail -> Corrupt_original detail) in
    let* expected_digest = V.digest original
      |> Result.map_error (fun detail -> Corrupt_original detail) in
    if String.equal record.installation_id installation_id
      && String.equal record.package_id package_id && String.equal record.tool tool_name
      && String.equal record.request_digest expected_digest
      && Yojson.Safe.equal record.summary expected_summary
    then Ok original
    else Error (Corrupt_original "retained verifier destination or summary does not match")

module Progress = Lane_addon_request_progress
module AR = Task.Anti_rationalization
type retained = { record : Owner.retained; original : V.t }
let original retained = retained.original
let progress retained = retained.record.progress
let load_retained ~store ~verification_id ~attempt ~installation_id ~package_id =
  let* original = load_for_destination ~store ~verification_id ~attempt ~installation_id ~package_id in
  let* request_id = attempt_request_id ~verification_id ~attempt
    |> Result.map_error (fun d -> Corrupt_original d) in
  let* record = Owner.load ~store ~scope ~request_id
    |> Result.map_error (fun e -> Load_store_unavailable (Owner.error_to_string e)) in
  match record with
  | None -> Error Not_found
  | Some record ->
    let* digest = V.digest original |> Result.map_error (fun d -> Corrupt_original d) in
    if record.request_digest = digest then Ok {record;original}
    else Error (Corrupt_original "verifier original changed during restore")

let advance_events_with ~publish ~store retained events =
  match publish ~store ~expected:retained.record ~events with
  | Error error -> Error (Load_store_unavailable (Owner.update_error_to_string error))
  | Ok (Owner.Unconfirmed detail) -> Error (Load_store_unavailable
      ("verifier progress publication unconfirmed; restore original before any effect: " ^ detail))
  | Ok (Owner.Already_stored _) when List.exists (function Progress.Dispatch_intended -> true
      | Admission_declined _ | Execution_observed _ | Judgment_retained _
      | Preparation_intended _ | Preparation_observed _ | Replacement_intended _
      | Replacement_observed _ | Commit_intended _ | Commit_uncertain _
      | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _ | Refused _
      | Successor_intended _ | Successor_observed _ | Observer _ -> false) events ->
    Error (Load_store_unavailable "dispatch intention was already retained; dispatch outcome must be restored")
  | Ok (Owner.Stored record | Owner.Already_stored record) -> Ok {retained with record}

let advance_events = advance_events_with ~publish:Owner.advance_events
let advance ~store retained event = advance_events ~store retained [event]
module For_testing = struct
  let advance_events = advance_events_with
end

let result_to_json (result:AR.review_result) =
  let optional = function None -> `Null | Some value -> `String value in
  let verdict = match result.verdict with None -> `Null
    | Some (AR.Approve reason) -> `Assoc ["decision",`String "approve";"reason",`String reason]
    | Some (AR.Reject reason) -> `Assoc ["decision",`String "reject";"reason",`String reason] in
  `Assoc ["schema",`String "verifier_review_result/v2";"verdict",verdict;
    "evaluator_runtime",`String result.evaluator_runtime;
    "generator_runtime",optional result.generator_runtime;
    "evaluator_execution",(match result.evaluator_execution with None -> `Null
      | Some identity -> Runtime_response_identity.to_yojson identity);
    "gate",`String (AR.gate_to_string result.gate);
    "fallback_reason",optional result.fallback_reason;
    "retryable_runtimes",`List (List.map (fun x -> `String x) result.retryable_runtimes);
    "model_absent_runtimes",`List (List.map (fun x -> `String x) result.model_absent_runtimes)]

let result_of_json json =
  let open Yojson.Safe.Util in
  let decode () =
    let fields = to_assoc json in
    let* () = if List.sort String.compare (List.map fst fields) =
      ["evaluator_execution";"evaluator_runtime";"fallback_reason";"gate";"generator_runtime";
       "model_absent_runtimes";"retryable_runtimes";"schema";"verdict"]
      && member "schema" json = `String "verifier_review_result/v2"
      then Ok () else Error "invalid retained verifier result fields" in
    let optional = function `Null -> None | value -> Some (to_string value) in
    let verdict = match member "verdict" json with
      | `Null -> Ok None
      | `Assoc fields when List.sort String.compare (List.map fst fields)=["decision";"reason"] ->
        (match List.assoc "decision" fields,List.assoc "reason" fields with
         | `String "approve",`String reason -> Ok (Some (AR.Approve reason))
         | `String "reject",`String reason when String.trim reason <> "" -> Ok (Some (AR.Reject reason))
         | _ -> Error "invalid retained verifier decision")
      | _ -> Error "invalid retained verifier verdict" in
    let* verdict = verdict in
    let* gate = match member "gate" json with
      | `String "structured_tool" -> Ok AR.Structured_tool
      | `String "invalid_verdict" -> Ok AR.Invalid_verdict
      | `String "evaluator_unavailable" -> Ok AR.Evaluator_unavailable
      | _ -> Error "invalid retained verifier result gate" in
    let* () = match verdict,gate with
      | Some _,AR.Structured_tool | None,(AR.Invalid_verdict | AR.Evaluator_unavailable) -> Ok ()
      | Some _,(AR.Invalid_verdict | AR.Evaluator_unavailable) | None,AR.Structured_tool ->
        Error "retained verifier decision and gate disagree" in
    let* evaluator_execution = match member "evaluator_execution" json with
      | `Null -> Ok None
      | json -> Runtime_response_identity.of_yojson json |> Result.map Option.some in
    let strings key = member key json |> to_list |> List.map to_string in
    Ok {AR.verdict;evaluator_runtime=member "evaluator_runtime" json |> to_string;
      generator_runtime=optional (member "generator_runtime" json);evaluator_execution;gate;
      fallback_reason=optional (member "fallback_reason" json);
      retryable_runtimes=strings "retryable_runtimes";
      model_absent_runtimes=strings "model_absent_runtimes"} in
  try decode () with Type_error _ | Undefined _ | Not_found -> Error "malformed retained verifier result"

let judgment_to_json ~original ~notes result =
  let* digest=V.digest original in
  Ok (`Assoc ["schema",`String "verifier_host_judgment/v1";
    "original_digest",`String digest;"result",result_to_json result;"notes",`String notes])

let judgment_of_json ~original json =
  let* digest=V.digest original in
  match json with
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["notes";"original_digest";"result";"schema"]
      && List.assoc "schema" fields=`String "verifier_host_judgment/v1"
      && List.assoc "original_digest" fields=`String digest ->
    let* result=result_of_json (List.assoc "result" fields) in
    (match result.AR.verdict,List.assoc "notes" fields with
     | Some _,`String notes when String.trim notes<>"" -> Ok (result,notes)
     | None,_ | Some _,_ -> Error "retained host judgment lacks a verdict or its complete domain notes")
  | _ -> Error "retained host judgment differs from its complete original"

let known_observations = function
  | `List (_::_ as observations) ->
    List.fold_left (fun state observation ->
      let* reached,failed=state in
      match observation with
      | `Assoc fields when List.sort String.compare (List.map fst fields)=["fact"]
          && List.assoc "fact" fields=`String "admission_refused" -> Ok (reached,failed)
      | `Assoc fields when List.sort String.compare (List.map fst fields)=["fact";"runtime_id"] ->
        (match List.assoc "fact" fields,List.assoc "runtime_id" fields with
         | `String "reply_received",`String id when String.trim id<>"" -> Ok (true,failed)
         | _ -> Error "invalid retained reviewer reply observation")
      | `Assoc fields when List.sort String.compare (List.map fst fields)=["error_category";"fact";"runtime_id"] ->
        (match List.assoc "fact" fields,List.assoc "runtime_id" fields,List.assoc "error_category" fields with
         | `String "before_dispatch",`String id,`String category when String.trim id<>"" && String.trim category<>"" ->
           Ok (reached,id::failed)
         | `String "definite_refusal",`String id,`String category when String.trim id<>"" && String.trim category<>"" ->
           Ok (true,id::failed)
         | _ -> Error "retained reviewer failure is not definitely resolved")
      | _ -> Error "invalid retained reviewer execution observations") (Ok (false,[])) observations
  | _ -> Error "retained reviewer disposition has no concrete admission observations"

let validate_admission evidence =
  match evidence with
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["observations";"result";"schema"]
      && List.assoc "schema" fields=`String "verifier_admission_refusal/v1" ->
    let* reached,_failed=known_observations (List.assoc "observations" fields) in
    let* result=result_of_json (List.assoc "result" fields) in
    (match reached,result.AR.verdict,result.gate with
     | false,None,AR.Evaluator_unavailable -> Ok ()
     | true,_,_ | false,Some _,_ | false,None,(Structured_tool | Invalid_verdict) ->
       Error "retained admission refusal includes execution or a model reply")
  | _ -> Error "invalid retained reviewer admission refusal"

let terminal_review_result evidence =
  match evidence with
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["certainty";"observations";"result";"schema"]
      && List.assoc "schema" fields = `String "verifier_review_refusal/v1"
      && List.assoc "certainty" fields = `String "definite" ->
    let* reached,failed=known_observations (List.assoc "observations" fields) in
    let* result = result_of_json (List.assoc "result" fields) in
    (match result.AR.verdict with
     | None when (reached || (failed<>[] && result.gate=AR.Evaluator_unavailable))
         && List.for_all (fun id -> List.mem id failed) result.retryable_runtimes -> Ok result
     | None | Some _ -> Error "terminal reviewer retry lacks its definite execution observations")
  | _ -> Error "original refusal does not establish a definite terminal retry"

let terminal_result evidence = Result.map (fun _ -> ()) (terminal_review_result evidence)
let retry_result evidence =
  let* result = terminal_review_result evidence in
  match result.AR.retryable_runtimes with
  | _::_ -> Ok ()
  | [] -> Error "original refusal has no typed safe retry"

(* Routing metadata proves only which verification owns these immutable bytes.
   It never constructs an Original or grants execution of an unsupported body. *)
let routing_verification (record : Owner.retained) =
  let invalid detail = Error (Corrupt_original detail) in
  let text key fields = match List.assoc_opt key fields with
    | Some (`String value) when String.trim value <> "" -> Ok value
    | Some _ | None -> invalid ("invalid verifier routing " ^ key) in
  let attempt fields = match List.assoc_opt "attempt" fields with
    | Some (`Int value) when value >= 0 -> Ok value
    | Some _ | None -> invalid "invalid verifier routing attempt" in
  let* summary = match record.summary with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        ["attempt"; "original_digest"; "schema"; "verification_id"] -> Ok fields
    | _ -> invalid "invalid verifier routing summary" in
  let* body = match record.request with
    | `Assoc fields when List.length fields =
        List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> invalid "invalid verifier routing body" in
  let* schema = text "schema" summary in
  let* verification_id = text "verification_id" summary in
  let* number = attempt summary in
  let* digest = text "original_digest" summary in
  let* body_schema = text "schema" body in
  let* body_verification_id = text "verification_id" body in
  let* body_attempt = attempt body in
  let* request_id = attempt_request_id ~verification_id ~attempt:number
    |> Result.map_error (fun detail -> Corrupt_original detail) in
  if record.scope = scope && record.tool = tool_name
    && record.request_id = request_id && digest = record.request_digest
    && schema = body_schema && verification_id = body_verification_id
    && number = body_attempt
  then Ok verification_id
  else invalid "verifier routing metadata differs from its original key or body"

let selected_records ~store ~selection =
  let* records = Owner.load_scope ~store ~scope
    |> Result.map_error (fun e -> Load_store_unavailable (Owner.error_to_string e)) in
  match selection with
  | All_verifications -> Ok records
  | Verification verification_id when String.trim verification_id = "" ->
    Error (Corrupt_original "verifier selection requires a non-blank verification_id")
  | Verification verification_id ->
    let* selected = List.fold_left (fun acc record ->
      let* selected = acc in
      let* owner = routing_verification record in
      Ok (if owner = verification_id then record :: selected else selected)) (Ok []) records in
    Ok (List.rev selected)

let next_attempt ~store ~verification_id ~installation_id ~package_id =
  let* records = selected_records ~store ~selection:(Verification verification_id) in
  let* related = List.fold_left (fun acc (record:Owner.retained) ->
    let* acc = acc in
    let* original = V.of_json record.request |> Result.map_error (fun d -> Corrupt_original d) in
    let* expected_summary = summary_of original |> Result.map_error (fun d -> Corrupt_original d) in
    let* expected_key = attempt_request_id ~verification_id:(V.verification_id original) ~attempt:(V.attempt original)
      |> Result.map_error (fun d -> Corrupt_original d) in
    let* () = if record.tool=tool_name && record.request_id=expected_key
      && Yojson.Safe.equal record.summary expected_summary then Ok ()
      else Error (Corrupt_original "verifier inventory differs from its full original") in
    if V.verification_id original <> verification_id then Ok acc
    else if record.installation_id<>installation_id || record.package_id<>package_id
      then Error (Corrupt_original "verifier inventory belongs to another destination")
    else Ok ({record;original}::acc)) (Ok []) records in
  let related = List.sort (fun left right -> Int.compare (V.attempt left.original) (V.attempt right.original)) related in
  let retain_child parent successor child =
    let* expected = V.successor parent.original |> Result.map_error (fun d -> Corrupt_original d) in
    let* digest = V.digest child |> Result.map_error (fun d -> Corrupt_original d) in
    if not (Yojson.Safe.equal (V.to_json expected) (V.to_json child))
      || successor.Progress.request_digest<>digest then
      Error (Corrupt_original "verifier successor changed its frozen semantic input")
    else
      let* () = retain ~store ~verification_id ~attempt:(V.attempt child)
        ~installation_id ~package_id child |> Result.map_error (function
          | Original_invalid d | Identity_mismatch d | Retain_store_unavailable d | Already_retained d -> Corrupt_original d) in
      let* _ = match Progress.phase parent.record.progress with
        | Progress.Subdividing _ -> advance ~store parent (Progress.Successor_observed successor.request_id)
        | Progress.Subdivided _ -> Ok parent
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
        | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _ ->
          Error (Corrupt_original "verifier successor lacks original terminal authorization") in
      load_retained ~store ~verification_id ~attempt:(V.attempt child) ~installation_id ~package_id in
  let rec walk parent rest =
    match Progress.phase parent.record.progress,rest with
    | (Progress.Subdividing (refusal,successor) | Subdivided (refusal,successor)),_ ->
      let* () = retry_result refusal.evidence |> Result.map_error (fun d -> Corrupt_original d) in
      let* child = match rest with
        | child::_ -> Ok child.original
        | [] -> let* json = Owner.load_successor_request ~store ~scope successor
            |> Result.map_error (fun e -> Load_store_unavailable (Owner.error_to_string e)) in
          V.of_json json |> Result.map_error (fun d -> Corrupt_original d) in
      let* expected_key=attempt_request_id ~verification_id ~attempt:(V.attempt child)
        |> Result.map_error (fun d -> Corrupt_original d) in
      let* ()=if expected_key=successor.request_id then Ok ()
        else Error (Corrupt_original "verifier successor key differs") in
      let* child=retain_child parent successor child in
      walk child (match rest with [] -> [] | _::tail -> tail)
    | Progress.Rejected ({stage=Progress.Execution;evidence} as _refusal),[] ->
      (match retry_result evidence with
       | Error _ -> Ok (V.attempt parent.original)
       | Ok () ->
         let* child=V.successor parent.original |> Result.map_error (fun d -> Corrupt_original d) in
         let* request_id=attempt_request_id ~verification_id ~attempt:(V.attempt child)
           |> Result.map_error (fun d -> Corrupt_original d) in
         let* successor=Owner.prepare_successor ~store ~scope ~request_id ~request:(V.to_json child)
           |> Result.map_error (fun e -> Load_store_unavailable (Owner.error_to_string e)) in
         let* parent=advance ~store parent (Progress.Successor_intended successor) in
         let* child=retain_child parent successor child in Ok (V.attempt child.original))
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected {stage=Progress.Before_dispatch;_}),[] -> Ok (V.attempt parent.original)
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
      | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected {stage=(Progress.Before_dispatch | Progress.Execution);_}),_::_ ->
      Error (Corrupt_original "verifier child exists without its original successor intent") in
  match related with
  | [] -> Ok 0
  | first::rest when V.attempt first.original=0 -> walk first rest
  | _::_ -> Error (Corrupt_original "verifier inventory is missing its original first attempt")

let retained_commits ~store ~selection ~installation_id ~package_id =
  let* records = selected_records ~store ~selection in
  List.fold_left (fun acc (record:Owner.retained) ->
    let* acc=acc in
    let* original=V.of_json record.request |> Result.map_error (fun d -> Corrupt_original d) in
    let* retained=load_retained ~store ~verification_id:(V.verification_id original)
      ~attempt:(V.attempt original) ~installation_id ~package_id in
    match Progress.phase (progress retained) with
    | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ -> Ok (retained::acc)
    | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _
    | Subdividing _ | Subdivided _ -> Ok acc) (Ok []) records

let pending_commits ~terminal_pending ~store ~selection ~installation_id ~package_id =
  let* records=retained_commits ~store ~selection ~installation_id ~package_id in
  List.fold_right (fun retained acc ->
    let* acc=acc in
    match Progress.phase (progress retained) with
    | Finished _ | Conflicted _ ->
      let* pending=terminal_pending retained |> Result.map_error (fun detail -> Corrupt_original detail) in
      Ok (if pending then retained::acc else acc)
    | Judged _ | Committing _ | Commit_unknown _ -> Ok (retained::acc)
    | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _
    | Subdividing _ | Subdivided _ -> Ok acc) records (Ok [])
