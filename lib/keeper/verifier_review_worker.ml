(** Execute the exact retained review; authority and commitment stay on host. *)
module AR = Task.Anti_rationalization
module O = Verifier_review_owner
module V = Verifier_review_original
module Authority = Verification_authority_tools
module Progress = Lane_addon_request_progress
let ( let* ) = Result.bind

type error =
  | Original_not_found
  | Original_corrupt of string
  | Grants_mismatch of string
  | Execution_pending of string
  | Persistence_unavailable of string

let map_load_error = function
  | O.Not_found -> Original_not_found
  | O.Load_store_unavailable detail -> Persistence_unavailable detail
  | O.Corrupt_original detail -> Original_corrupt detail

let run_attempt ?on_verdict ?on_tool_result ?sw ~store ~verification_id ~attempt
    ~installation_id ~package_id ~prepare_notes ~authority ~provider_rest () =
  let* retained = O.load_retained ~store ~verification_id ~attempt
    ~installation_id ~package_id |> Result.map_error map_load_error in
  let original = O.original retained in
  let restored json = O.judgment_of_json ~original json
    |> Result.map fst |> Result.map_error (fun detail -> Original_corrupt detail) in
  let save record event = O.advance ~store record event |> Result.map_error map_load_error in
  let restore_refusal evidence = match evidence with
    | `Assoc fields -> (match List.assoc_opt "result" fields with
        | Some json -> O.result_of_json json |> Result.map_error (fun detail -> Original_corrupt detail)
        | None -> Error (Original_corrupt "retained reviewer refusal has no exact result"))
    | _ -> Error (Original_corrupt "retained reviewer refusal is malformed") in
  match Progress.phase (O.progress retained) with
  | Progress.Judged json -> restored json
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    restored commit.judgment
  | Rejected refusal | Subdividing (refusal,_) | Subdivided (refusal,_) -> restore_refusal refusal.evidence
  | Dispatch_pending _ -> Error (Execution_pending
      "original reviewer may have dispatched; no automatic provider replay")
  | Captured | Admission_wait _ ->
  let subject = Authority.task_review_subject authority in
  let req = V.review_request original in
  let lookup = Authority.task_review_lookup authority in
  let* () =
    if String.equal subject.id verification_id
      && String.equal subject.task_id req.AR.task_id
      && String.equal subject.worker req.agent_name
      && String.equal (V.lookup_binding original) (Authority.task_review_binding authority)
      && V.lookup_root original = Authority.task_review_root authority
      && V.lookup_schemas original =
        List.map (fun (schema : Types_core.tool_schema) -> schema.name) lookup.AR.schemas
    then Ok () else Error (Grants_mismatch "retained subject or lookup authority differs") in
  let* () = Authority.validate_task_review authority
    |> Result.map_error (fun detail -> Grants_mismatch detail) in
  let* () =
    if String.equal (V.output_contract original) (V.canonical_output_contract ()) then Ok ()
    else Error (Original_corrupt "retained output contract differs from the review protocol") in

    let* dispatching = save retained Progress.Dispatch_intended in
    let current = ref dispatching in
    let unknown = ref false in
    let on_execution_failure ~runtime_id:_ ~certainty _error =
      match certainty with
      | AR.Outcome_unknown -> unknown := true
      | Before_dispatch | Definite_refusal -> () in
    let exception Retention_failed of error in
    let retain_result result =
      let json = O.result_to_json result in
      let event = match result.AR.verdict with
        | Some _ ->
          let judgment=O.judgment_to_json ~original ~notes:(prepare_notes result) result in
          (match judgment with Ok judgment -> Progress.Judgment_retained judgment
           | Error detail -> raise (Retention_failed (Original_corrupt detail)))
        | None when !unknown -> Progress.Execution_observed (Progress.Outcome_unknown
            (`Assoc ["schema",`String "verifier_review_unknown/v1";"result",json]))
        | None -> Progress.Refused {stage=Progress.Execution;evidence=`Assoc [
            "schema",`String "verifier_review_refusal/v1";"certainty",`String "definite";"result",json]} in
      (match save !current event with
       | Error error -> raise (Retention_failed error)
       | Ok saved -> current := saved);
      Option.iter (fun callback -> callback result) on_verdict in
    try
      let result = AR.review_rendered ~system_prompt:(V.system_instructions original) ~on_execution_failure ~on_verdict:retain_result
        ?on_tool_result ?sw ~prompt:(V.system_prompt_text original)
        ~lookup ~provider_rest ~base_path:(Authority.task_review_base_path authority) req in
      if !unknown then Error (Execution_pending "reviewer outcome unknown; exact original retained")
      else Ok result
    with
    | Retention_failed error -> Error error
    | Eio.Cancel.Cancelled _ as exn ->
      Eio.Cancel.protect (fun () ->
        (* Reread after possible save cancellation: a saved judgment is kept,
           while a retained dispatch can only acquire uncertainty, not replay. *)
        match O.load_retained ~store ~verification_id ~attempt ~installation_id ~package_id with
        | Ok saved -> (match Progress.phase (O.progress saved) with
            | Dispatch_pending _ -> ignore (save saved (Progress.Execution_observed
                (Progress.Outcome_unknown (`Assoc ["cause",`String "review_cancelled"]))))
            | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
            | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> ())
        | Error _ -> ());
      raise exn

let commit_attempt ~store ~verification_id ~attempt ~installation_id ~package_id
    ~change ~observe ~apply =
  let* retained = O.load_retained ~store ~verification_id ~attempt ~installation_id ~package_id
    |> Result.map_error map_load_error in
  let save record event = O.advance ~store record event |> Result.map_error map_load_error in
  let pending detail = Error (Execution_pending detail) in
  let read record commit =
    match observe commit.Progress.change with
    | Error detail -> pending ("commit observation unavailable: " ^ detail)
    | Ok observed when Yojson.Safe.equal observed commit.change.after ->
      let* _ = save record (Progress.Commit_observed observed) in Ok ()
    | Ok observed when Yojson.Safe.equal observed commit.change.before ->
      let* record = save record (Progress.Commit_retry_observed observed) in
      (match apply commit.change with
       | Ok () ->
         (* Even a successful RPC is confirmed from its authoritative domain. *)
         (match observe commit.change with
          | Ok after when Yojson.Safe.equal after commit.change.after ->
            let* _ = save record (Progress.Commit_observed after) in Ok ()
          | Ok value -> let* _ = save record (Progress.Commit_uncertain value) in
            pending "commit returned without matching authoritative after-state"
          | Error detail -> let* _ = save record (Progress.Commit_uncertain (`String detail)) in pending detail)
       | Error detail -> let* _ = save record (Progress.Commit_uncertain (`String detail)) in pending detail)
    | Ok observed -> let* _ = save record (Progress.Commit_conflicted observed) in
      pending "original commit conflicts with authoritative current Task" in
  let recover record commit =
    let original=O.original record in
    let* result,notes=O.judgment_of_json ~original commit.Progress.judgment
      |> Result.map_error (fun d -> Original_corrupt d) in
    let* digest=V.digest original |> Result.map_error (fun d -> Original_corrupt d) in
    let* ()=match commit.Progress.change.after with
      | `Assoc fields when List.assoc_opt "original_digest" fields=Some (`String digest)
        && (match List.assoc_opt "review" fields with
          | Some json -> Yojson.Safe.equal json (O.result_to_json result)
          | None -> false)
        && List.assoc_opt "notes" fields=Some (`String notes) -> Ok ()
      | _ -> Error (Original_corrupt "commit intent does not bind its exact original and judgment") in
    let* record = match Progress.phase (O.progress record) with
      | Progress.Committing _ -> save record (Progress.Commit_uncertain
          (`Assoc ["cause",`String "commit_completion_not_yet_confirmed"]))
      | Commit_unknown _ -> Ok record
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
        Error (Original_corrupt "commit recovery lacks retained original intent") in
    read record commit in
  match Progress.phase (O.progress retained) with
  | Progress.Finished _ -> Ok ()
  | Committing commit | Commit_unknown (commit,_) -> recover retained commit
  | Judged judgment ->
    let* result,_notes = O.judgment_of_json ~original:(O.original retained) judgment
      |> Result.map_error (fun d -> Original_corrupt d) in
    (match result.AR.verdict with
     | None -> Error (Original_corrupt "non-verdict cannot authorize domain commit")
     | Some _ ->
       let* record = save retained (Progress.Commit_intended change) in
       (* Treat even first admission as possible until its exact before-state
          is re-read. This is also the restart path after intention save. *)
       recover record {Progress.judgment;change})
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    pending "review has no retained judgment to commit"
  | Conflicted _ -> pending "original commit is conflicted; host resolution required"
