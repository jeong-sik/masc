let available value = `Assoc ["kind", `String "available"; "value", value]
let unavailable reason = `Assoc ["kind", `String "unavailable"; "reason", `String reason]
let member name = function `Assoc fields -> List.assoc_opt name fields | _ -> None

let completed_boundary ~config ~keeper ~turn_ref =
  let module B = Keeper_turn_boundaries in
  match B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper with
  | Error detail -> unavailable detail
  | Ok lines ->
    let trace_id = Ids.Turn_ref.trace_id turn_ref in
    let result = List.fold_left (fun result (line, record) ->
      match result, record with
      | Error _ as error, _ -> error
      | Ok _, Error error -> Error (B.read_error_to_string error)
      | Ok (generation, found), Ok record ->
        let generation, found =
          if B.restarts_history ~trace_id record then line, None else generation, found in
        let found = match B.atom_position_stated ~trace_id record with
          | Some (reference, _, _) when Ids.Turn_ref.equal reference turn_ref -> Some (line, record)
          | Some _ | None -> found in
        Ok (generation, found)) (Ok (0, None)) lines in
    (match result with
     | Error detail -> unavailable detail
     | Ok (_, None) -> unavailable "completed atom boundary not retained in this history generation"
     | Ok (generation, Some (line, record)) ->
       available (`Assoc ["history_start_boundary_line", `Int generation;
         "boundary_line", `Int line; "record", B.record_to_json record]))

let requests ~config ~keeper ~turn_ref =
  let location = Dated_jsonl.Store.keeper (Workspace.dated_store_root config)
      ~keeper Dated_jsonl.Store.Keeper.Continuity_requests in
  let rows = ref [] in
  let failure = ref None in
  let stop detail = failure := Some detail; Some () in
  let scan = function
    | Dated_jsonl.Malformed_json _ -> stop "unidentifiable continuity request row"
    | Dated_jsonl.Parsed json ->
      if member "schema" json <> Some (`String "masc.continuity-request.v3") then
        stop "unsupported continuity request schema"
      else match Option.bind (member "turn_ref" json) (fun value ->
        match Ids.Turn_ref.of_yojson value with Ok reference -> Some reference | Error _ -> None) with
      | None -> stop "continuity request lacks a turn identity"
      | Some reference when Ids.Turn_ref.equal reference turn_ref ->
        if member "keeper" json <> Some (`String keeper) then stop "continuity request owner mismatch"
        else (rows := json :: !rows; None)
      | Some reference when String.equal (Ids.Turn_ref.trace_id reference) (Ids.Turn_ref.trace_id turn_ref)
          && Ids.Turn_ref.absolute_turn reference < Ids.Turn_ref.absolute_turn turn_ref -> Some ()
      | Some _ -> None
  in
  match Dated_jsonl.find_latest_entry_result (Dated_jsonl.open_store location) scan with
  | Error error -> unavailable (Dated_jsonl.read_error_to_string error)
  | Ok _ ->
    match !failure, !rows with
    | Some detail, _ -> unavailable detail
    | None, [] -> unavailable "no attributed serializations retained for this turn"
    | None, rows -> available (`List rows)

let saved ~config ~keeper =
  match Keeper_librarian_continuity.read ~config ~keeper_name:keeper with
  | Error detail -> unavailable detail
  | Ok None -> unavailable "no saved working state"
  | Ok (Some snapshot) -> available
      (Keeper_continuity_request.selection_to_json (Summarized snapshot))

let read ~config ~keeper ~turn_ref =
  Result.map (fun manifest ->
    `Assoc ["schema", `String "masc.keeper-continuity-evidence.v1";
      "keeper", `String keeper; "turn_ref", Ids.Turn_ref.to_yojson turn_ref;
      "wire", Llm_provider.Request_wire_observer.observation_to_yojson
        manifest.Keeper_provider_input_snapshot.mf_snapshot.wire;
      "requests", requests ~config ~keeper ~turn_ref;
      "completed_boundary", completed_boundary ~config ~keeper ~turn_ref;
      "saved_readiness_only", saved ~config ~keeper])
    (Keeper_provider_input_snapshot.read_manifest ~config ~keeper ~turn_ref)
