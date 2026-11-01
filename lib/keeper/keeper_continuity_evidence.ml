let schema = "masc.keeper-continuity-evidence.v1"
let max_request_scan_rows = 4096

let available ?(fields = []) value =
  `Assoc (("kind", `String "available") :: ("value", value) :: fields)

let unavailable ?(fields = []) reason =
  `Assoc (("kind", `String "unavailable") :: ("reason", `String reason) :: fields)

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
  let scanned_rows = ref 0 in
  let skipped_unattributed_rows = ref 0 in
  let stop detail = failure := Some detail; Some () in
  let scan entry =
    if !scanned_rows >= max_request_scan_rows then
      stop "continuity request scan exceeded bounded lookback window"
    else (
      incr scanned_rows;
      match entry with
      | Dated_jsonl.Malformed_json _ -> stop "unidentifiable continuity request row"
      | Dated_jsonl.Parsed json ->
        match member "schema" json with
        | Some (`String ("masc.continuity-request.v1" | "masc.continuity-request.v2")) ->
          incr skipped_unattributed_rows;
          if !rows <> [] then Some () else None
        | Some (`String "masc.continuity-request.v3") ->
          if member "keeper" json <> Some (`String keeper) then
            stop "continuity request owner mismatch"
          else (
            match member "turn_ref" json with
            | Some `Null ->
              (* The writer records an explicit null for an unattributed
                 request; only that shape is a legitimate skip. A v3 row
                 missing the field entirely is corrupted: it cannot be
                 attributed to any turn, so the observation must fail rather
                 than return a partial list as complete. *)
              incr skipped_unattributed_rows;
              None
            | None -> stop "continuity request missing turn identity field"
            | Some value ->
              match Ids.Turn_ref.of_yojson value with
              | Error _ -> stop "malformed continuity request turn identity"
              | Ok reference when Ids.Turn_ref.equal reference turn_ref ->
                rows := json :: !rows;
                None
              | Ok reference
                when !rows <> []
                     || (String.equal
                           (Ids.Turn_ref.trace_id reference)
                           (Ids.Turn_ref.trace_id turn_ref)
                         && Ids.Turn_ref.absolute_turn reference
                            < Ids.Turn_ref.absolute_turn turn_ref) ->
                Some ()
              | Ok _ -> None)
        | _ -> stop "unsupported continuity request schema")
  in
  let diagnostics () =
    [ "scanned_rows", `Int !scanned_rows
    ; "skipped_unattributed_rows", `Int !skipped_unattributed_rows
    ]
  in
  match Dated_jsonl.find_latest_entry_result (Dated_jsonl.open_store location) scan with
  | Error error ->
    unavailable ~fields:(diagnostics ()) (Dated_jsonl.read_error_to_string error)
  | Ok _ ->
    match !failure, !rows with
    | Some detail, _ -> unavailable ~fields:(diagnostics ()) detail
    | None, [] ->
      unavailable
        ~fields:(diagnostics ())
        "no attributed serializations retained for this turn"
    | None, rows -> available ~fields:(diagnostics ()) (`List rows)

let saved ~config ~keeper =
  match Keeper_librarian_continuity.read ~config ~keeper_name:keeper with
  | Error detail -> unavailable detail
  | Ok None -> unavailable "no saved working state"
  | Ok (Some snapshot) -> available
      (Keeper_continuity_request.selection_to_json (Summarized snapshot))

let read ~config ~keeper ~turn_ref =
  Result.map (fun manifest ->
    `Assoc ["schema", `String schema;
      "keeper", `String keeper; "turn_ref", Ids.Turn_ref.to_yojson turn_ref;
      "wire", Llm_provider.Request_wire_observer.observation_to_yojson
        manifest.Keeper_provider_input_snapshot.mf_snapshot.wire;
      "requests", requests ~config ~keeper ~turn_ref;
      "completed_boundary", completed_boundary ~config ~keeper ~turn_ref;
      "saved_readiness_only", saved ~config ~keeper])
    (Keeper_provider_input_snapshot.read_manifest ~config ~keeper ~turn_ref)
