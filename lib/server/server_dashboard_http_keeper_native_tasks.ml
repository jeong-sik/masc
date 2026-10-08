module Journal = Keeper_native_task_journal

type route = Receivers of string | Records of string
let permission = Masc_domain.CanAdmin

let route path =
  match String.split_on_char '/' path with
  | [""; "api"; "v1"; "keepers"; name; "native-tasks"; "receivers"] ->
      Some (Receivers (Uri.pct_decode name))
  | [""; "api"; "v1"; "keepers"; name; "native-tasks"; "records"] ->
      Some (Records (Uri.pct_decode name))
  | _ -> None

let error status code = status, `Assoc
  ["schema", `String "masc.native_tasks.error.v1"; "error", `String code;
   "provider_completeness", `String "unknown";
   "historical_persistence_failures", `String "unknown"]

let store_error = function
  | Journal.Missing_store -> error `Not_found "store_missing"
  | Invalid_scope _ | Invalid_observation _ -> error `Bad_request "invalid_scope"
  | Cursor_store_mismatch -> error `Conflict "cursor_store_mismatch"
  | Cursor_ahead -> error `Conflict "cursor_ahead"
  | Corrupt _ -> error `Service_unavailable "store_corrupt"
  | Conflicting_uuid _ -> error `Conflict "conflicting_uuid"
  | Sequence_exhausted -> error `Service_unavailable "sequence_exhausted"
  | Io_failed _ -> error `Service_unavailable "io_failed"
  | Directory_prepare_failed _ -> error `Service_unavailable "directory_prepare_failed"
  | Store_unavailable _ -> error `Service_unavailable "store_unavailable"
  | Commit_unconfirmed _ -> error `Service_unavailable "commit_unconfirmed"

let strict_query request allowed =
  let fields = Uri.query (Uri.of_string request.Httpun.Request.target) in
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
     || List.exists (fun (name, values) -> not (List.mem name allowed)
           || List.length values <> 1) fields then Error ()
  else Ok (List.map (fun (name, values) -> name, List.hd values) fields)

let records_query fields =
  match List.assoc_opt "receiver_generation" fields, List.assoc_opt "session_id" fields with
  | Some generation, Some session when generation <> "" && session <> "" ->
      let cursor = match List.assoc_opt "store_id" fields, List.assoc_opt "after_sequence" fields with
        | None, None -> Ok None
        | Some store_id, Some raw ->
            (match int_of_string_opt raw with
             | Some after_sequence when String.equal raw (string_of_int after_sequence) ->
                 Journal.cursor ~store_id ~after_sequence |> Result.map Option.some
                 |> Result.map_error (fun _ -> ())
             | Some _ | None -> Error ())
        | _ -> Error () in
      Result.map (fun after -> generation, session, after) cursor
  | _ -> Error ()

let cleanup_json failures = `List (List.map (fun (f : Journal.cleanup_failure) ->
  `Assoc ["operation", `String f.operation; "status", `String "cleanup_failed"])
  failures)

let records_response ~base_path ~keeper_name request =
  match strict_query request ["receiver_generation"; "session_id"; "store_id"; "after_sequence"] with
  | Error () -> error `Bad_request "invalid_query"
  | Ok fields ->
      match records_query fields with
      | Error () -> error `Bad_request "invalid_query"
      | Ok (receiver_generation, session_id, after) ->
          match Journal.open_reader ~base_path ~keeper_name ~receiver_generation ~session_id with
          | Error e -> store_error e
          | Ok reader ->
              let result = Journal.read ?after reader in
              match result.result with
              | Error e -> store_error e
              | Ok snapshot ->
                  let redact_text = Keeper_secret_redaction.redact_text
                    (Keeper_secret_redaction.snapshot ~base_path ~keeper_name) in
                  let cursor = Journal.next_cursor snapshot in
                  `OK, `Assoc
                    ["schema", `String "masc.native_tasks.records.v1";
                     "keeper_name", `String keeper_name;
                     "receiver_generation", `String receiver_generation;
                     "session_id", `String session_id;
                     "records", `List (List.map (fun (r : Journal.record) -> `Assoc
                       ["seq", `Int r.seq; "recorded_at", `Float r.recorded_at;
                        "observation", Runtime_native_tasks.to_json
                          (Runtime_native_tasks.redact redact_text r.observation)]) snapshot.records);
                     "validation", `Assoc ["kind", `String "full_committed_history";
                       "through_sequence", `Int snapshot.validation.through_sequence];
                     "next_cursor", `Assoc ["store_id", `String cursor.store_id;
                       "after_sequence", `Int cursor.after_sequence];
                     "provider_completeness", `String "unknown";
                     "historical_persistence_failures", `String "unknown";
                     "terminal_without_observation", `String "unknown";
                     "cleanup_failures", cleanup_json result.cleanup_failure]

let receivers_response ~base_path ~keeper_name request =
  match strict_query request [] with
  | Error () -> error `Bad_request "invalid_query"
  | Ok _ ->
      let result = Journal.discover ~base_path ~keeper_name in
      match result.result with
      | Error e -> store_error e
      | Ok entries ->
          `OK, `Assoc ["schema", `String "masc.native_tasks.receivers.v1";
            "keeper_name", `String keeper_name;
            "receivers", `List (List.map (fun (entry : Journal.discovery_entry) ->
              let state = match entry.state with
                | Ok validation -> `Assoc ["status", `String "audited";
                    "store_id", `String validation.store_id;
                    "through_sequence", `Int validation.through_sequence]
                | Error e -> snd (store_error e) in
              `Assoc ["receiver_generation", `String entry.receiver.receiver_generation;
                "session_id", `String entry.receiver.session_id; "storage", state]) entries);
            "provider_completeness", `String "unknown";
            "historical_persistence_failures", `String "unknown";
            "cleanup_failures", cleanup_json result.cleanup_failure]

let observed_health ~base_path ~keeper_name =
  match Journal.issue_snapshot ~base_path ~keeper_name with
  | Error e -> `Assoc ["coverage", `String "unavailable"; "error", snd (store_error e)]
  | Ok snapshot -> `Assoc
      ["coverage", `String "issues_observed_in_this_process_only";
       "process_epoch", `String snapshot.process_epoch;
       "historical_failure_coverage", `String "unknown";
       "issues", `List (List.map (fun (entry : Journal.process_issue) ->
         let receiver = match entry.receiver with
           | None -> `Null
           | Some receiver -> `Assoc
               ["receiver_generation", `String receiver.receiver_generation;
                "session_id", `String receiver.session_id] in
         `Assoc ["receiver", receiver; "event_uuid", `String entry.issue.event_uuid;
           "error", (match entry.issue.error with None -> `Null
             | Some e -> snd (store_error e));
           "cleanup_failures", cleanup_json entry.issue.cleanup_failure]) snapshot.issues)]

let response state request route =
  let keeper_name = match route with Receivers name | Records name -> name in
  if not (Keeper_config.validate_name keeper_name) then error `Bad_request "invalid_keeper"
  else
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    let status, body = match route with
      | Receivers _ -> receivers_response ~base_path ~keeper_name request
      | Records _ -> records_response ~base_path ~keeper_name request in
    let fields = match body with `Assoc fields -> fields | _ -> [] in
    status, `Assoc (("observed_persistence_health", observed_health ~base_path ~keeper_name) :: fields)

let handle_get state request reqd route =
  let status, body = response state request route in
  Server_auth.respond_json_value_with_cors ~status request reqd body
