(** Execute the exact retained review; authority and commitment stay on host. *)
module AR = Task.Anti_rationalization
module O = Verifier_review_owner
module V = Verifier_review_original
module Authority = Verification_authority_tools
module Progress = Lane_addon_request_progress
open Result.Syntax

type error =
  | Original_not_found
  | Original_corrupt of string
  | Authority_unavailable of string
  | Grants_mismatch of string
  | Execution_pending of string
  | Execution_repair_required of string
  | Persistence_unavailable of string

let map_load_error = function
  | O.Not_found -> Original_not_found
  | O.Load_store_unavailable detail -> Persistence_unavailable detail
  | O.Corrupt_original detail -> Original_corrupt detail

let run_attempt_with ~advance_events ?prepare_observer_registration ?on_verdict ?on_tool_result ?sw ~store ~verification_id ~attempt
    ~installation_id ~package_id ~prepare_notes ~base_path ~prepare_authority ~provider_rest () =
  let expected_store = Lane_addon_store.create ~root:
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "lane-addons") in
  let* () = if Lane_addon_store.root store = Lane_addon_store.root expected_store
    then Ok () else Error (Grants_mismatch "review execution workspace differs from its original owner store") in
  let* retained = O.load_retained ~store ~verification_id ~attempt
    ~installation_id ~package_id |> Result.map_error map_load_error in
  let original = O.original retained in
  let restored json = O.judgment_of_json ~original json
    |> Result.map fst |> Result.map_error (fun detail -> Original_corrupt detail) in
  let save record event = advance_events ~store record [event] |> Result.map_error map_load_error in
  let retain_judgment retained result =
    let* judgment = O.judgment_to_json ~original ~notes:(prepare_notes result) result
      |> Result.map_error (fun detail -> Original_corrupt detail) in
    let* events = match prepare_observer_registration with
      | None -> Ok [Progress.Judgment_retained judgment]
      | Some prepare ->
        let* receipt = prepare result |> Result.map_error (fun detail -> Original_corrupt detail) in
        Ok [Progress.Judgment_retained judgment;Progress.Observer
          (Lane_addon_request_receipt.Intended (Registration,receipt))] in
    advance_events ~store retained events |> Result.map_error map_load_error in
  let observe_pending retained =
    let* observation = Verifier_review_execution.observe
      ~base_path ~original (O.progress retained)
      |> Result.map_error (fun detail -> Execution_repair_required detail) in
    match observation with
    | Verifier_review_execution.Awaiting -> Error (Execution_pending "original execution has no terminal observation")
    | Repair_required detail -> Error (Execution_repair_required detail)
    | Verdict result ->
      let* _ = retain_judgment retained result in
      Ok result in
  let restore_refusal evidence = match evidence with
    | `Assoc fields -> (match List.assoc_opt "result" fields with
        | Some json -> O.result_of_json json |> Result.map_error (fun detail -> Original_corrupt detail)
        | None -> Error (Original_corrupt "retained reviewer refusal has no exact result"))
    | _ -> Error (Original_corrupt "retained reviewer refusal is malformed") in
  let* result = match Progress.phase (O.progress retained) with
  | Progress.Judged json -> restored json
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    restored commit.judgment
  | Rejected refusal | Subdividing (refusal,_) | Subdivided (refusal,_) -> restore_refusal refusal.evidence
  | Dispatch_pending _ -> observe_pending retained
  | Captured | Admission_wait _ ->
  let* ()=match Progress.phase (O.progress retained) with
    | Admission_wait evidence -> O.validate_admission evidence |> Result.map_error (fun d -> Original_corrupt d)
    | Captured -> Ok ()
    | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
    | Rejected _ | Subdividing _ | Subdivided _ -> Error (Original_corrupt "reviewer admission state changed") in
  let* authority = prepare_authority () |> Result.map_error (fun detail -> Authority_unavailable detail) in
  let* () = if Authority.task_review_base_path authority = base_path then Ok ()
    else Error (Grants_mismatch "prepared authority belongs to another execution workspace") in
  let subject = Authority.task_review_subject authority in
  let req = V.review_request original in
  let lookup = Authority.task_review_lookup authority in
  (* The binding covers the host ownership root, route, subject, schemas and
     submitted evidence. A frozen inventory observation is not lookup authority. *)
  let* () =
    if String.equal subject.id verification_id
      && String.equal subject.task_id req.AR.task_id
      && String.equal subject.worker req.agent_name
      && String.equal (V.lookup_binding original) (Authority.task_review_binding authority)
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
    let provider_reached = ref false in
    let observations = ref [] in
    let execution_bound = ref false in
    let on_execution = function
      | AR.Admission_refused -> observations := `Assoc ["fact",`String "admission_refused"] :: !observations
      | Reply_received {runtime_id} -> provider_reached := true;
        observations := `Assoc ["fact",`String "reply_received";"runtime_id",`String runtime_id] :: !observations
      | Attempt_failed {runtime_id;certainty;error} ->
        let fact=match certainty with
          | AR.Outcome_unknown -> unknown:=true;provider_reached:=true;"outcome_unknown"
          | Definite_refusal -> provider_reached:=true;"definite_refusal"
          | Before_dispatch -> "before_dispatch" in
        observations := `Assoc ["fact",`String fact;"runtime_id",`String runtime_id;
          "error_category",`String Agent_core.Error.(category error |> category_label)] :: !observations in
    let exception Retention_failed of error in
    let* keeper_name = Verifier_review_execution.keeper_name original
      |> Result.map_error (fun detail -> Original_corrupt detail) in
    let* session_root = Verifier_review_execution.session_root ~base_path original
      |> Result.map_error (fun detail -> Original_corrupt detail) in
    let execution_owner : AR.execution_owner = {keeper_name;session_root;
      on_execution_ready=(fun ~runtime_id ~execution ->
        let* evidence = Verifier_review_execution.capture ~original ~runtime_id ~execution in
        match save !current (Progress.Execution_observed (Waiting evidence)) with
        | Ok saved -> current:=saved; execution_bound:=true; Ok ()
        | Error _ -> Error "original execution ownership publication was not confirmed")} in
    let retain_result result =
      let json = O.result_to_json result in
      let event = match result.AR.verdict with
        | Some _ ->
          let judgment=O.judgment_to_json ~original ~notes:(prepare_notes result) result in
          (match judgment with Ok judgment -> Progress.Judgment_retained judgment
           | Error detail -> raise (Retention_failed (Original_corrupt detail)))
        | None when !unknown -> Progress.Execution_observed (Progress.Outcome_unknown
            (`Assoc ["schema",`String "verifier_review_unknown/v1";"result",json]))
        | None when not !provider_reached && not !execution_bound -> Progress.Admission_declined (`Assoc [
            "schema",`String "verifier_admission_refusal/v1";
            "observations",`List (List.rev !observations);"result",json])
        | None -> Progress.Refused {stage=Progress.Execution;evidence=`Assoc [
            "schema",`String "verifier_review_refusal/v1";"certainty",`String "definite";
            "observations",`List (List.rev !observations);"result",json]} in
      let events = match event,prepare_observer_registration with
        | Progress.Judgment_retained _,Some prepare ->
          (match prepare result with
           | Ok receipt -> [event;Progress.Observer
               (Lane_addon_request_receipt.Intended (Registration,receipt))]
           | Error detail -> raise (Retention_failed (Original_corrupt detail)))
        | _,None | (Dispatch_intended | Admission_declined _ | Execution_observed _
          | Preparation_intended _ | Preparation_observed _ | Replacement_intended _
          | Replacement_observed _ | Commit_intended _ | Commit_uncertain _
          | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _ | Refused _
          | Successor_intended _ | Successor_observed _ | Observer _),Some _ -> [event] in
      (match advance_events ~store !current events |> Result.map_error map_load_error with
       | Error error -> raise (Retention_failed error)
       | Ok saved -> current := saved);
      Option.iter (fun callback -> callback result) on_verdict in
    try
      let result = AR.review_rendered ~execution_owner ~generator_runtime:(V.generator_runtime original) ~system_prompt:(V.system_instructions original) ~on_execution ~on_verdict:retain_result
        ?on_tool_result ?sw ~prompt:(V.system_prompt_text original)
        ~lookup ~provider_rest ~base_path:(Authority.task_review_base_path authority) req in
      if !unknown then observe_pending !current
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
  in
  Ok (original, result)

let run_attempt = run_attempt_with ~advance_events:O.advance_events
module For_testing = struct
  let run_attempt = run_attempt_with
end

type 'error apply_failure =
  | Outcome_unknown of { error : 'error; detail : string }
  | Authority_refused of { error : 'error; detail : string }

type 'error commit_error =
  | Worker_error of error
  | Apply_failed of 'error
  | Commit_conflicted of { commit : Progress.commit; observed : Yojson.Safe.t }

let commit_attempt ~store ~verification_id ~attempt ~installation_id ~package_id
    ~change ~observe ~apply =
  let* retained = O.load_retained ~store ~verification_id ~attempt ~installation_id ~package_id
    |> Result.map_error (fun error -> Worker_error (map_load_error error)) in
  let save record event = O.advance ~store record event
    |> Result.map_error (fun error -> Worker_error (map_load_error error)) in
  let pending detail = Error (Worker_error (Execution_pending detail)) in
  let conflicted record commit observed =
    let* _ = save record (Progress.Commit_conflicted observed) in
    Error (Commit_conflicted {commit; observed}) in
  let observe_refusal record commit error =
    match observe commit.Progress.change with
    | Ok observed when Yojson.Safe.equal observed commit.change.after ->
      let* _ = save record (Progress.Commit_observed observed) in Ok ()
    | Ok observed when Yojson.Safe.equal observed commit.change.before ->
      Error (Apply_failed error)
    | Ok observed -> conflicted record commit observed
    | Error _ -> Error (Apply_failed error) in
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
       | Error (Outcome_unknown {error; detail}) ->
         let* _ = save record (Progress.Commit_uncertain (`String detail)) in
         Error (Apply_failed error)
       | Error (Authority_refused {error; detail}) ->
         let* record = save record (Progress.Commit_uncertain (`String detail)) in
         observe_refusal record commit error)
    | Ok observed -> conflicted record commit observed in
  let authenticate record commit =
    let original=O.original record in
    let* result,notes=O.judgment_of_json ~original commit.Progress.judgment
      |> Result.map_error (fun d -> Worker_error (Original_corrupt d)) in
    let* digest=V.digest original |> Result.map_error (fun d -> Worker_error (Original_corrupt d)) in
    let* ()=match commit.Progress.change.after with
      | `Assoc fields when List.assoc_opt "original_digest" fields=Some (`String digest)
        && (match List.assoc_opt "review" fields with
          | Some json -> Yojson.Safe.equal json (O.result_to_json result)
          | None -> false)
        && List.assoc_opt "notes" fields=Some (`String notes) -> Ok ()
      | _ -> Error (Worker_error (Original_corrupt "commit intent does not bind its exact original and judgment")) in
    Ok () in
  let recover record commit =
    let* () = authenticate record commit in
    let* record = match Progress.phase (O.progress record) with
      | Progress.Committing _ -> save record (Progress.Commit_uncertain
          (`Assoc ["cause",`String "commit_completion_not_yet_confirmed"]))
      | Commit_unknown _ -> Ok record
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
        Error (Worker_error (Original_corrupt "commit recovery lacks retained original intent")) in
    read record commit in
  match Progress.phase (O.progress retained) with
  | Progress.Finished commit -> authenticate retained commit
  | Committing commit | Commit_unknown (commit,_) -> recover retained commit
  | Judged judgment ->
    let* result,_notes = O.judgment_of_json ~original:(O.original retained) judgment
      |> Result.map_error (fun d -> Worker_error (Original_corrupt d)) in
    (match result.AR.verdict with
     | None -> Error (Worker_error (Original_corrupt "non-verdict cannot authorize domain commit"))
     | Some _ ->
       let* record = save retained (Progress.Commit_intended change) in
       (* Treat even first admission as possible until its exact before-state
          is re-read. This is also the restart path after intention save. *)
       recover record {Progress.judgment;change})
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    pending "review has no retained judgment to commit"
  | Conflicted (commit, observed) ->
    let* () = authenticate retained commit in
    Error (Commit_conflicted {commit; observed})
