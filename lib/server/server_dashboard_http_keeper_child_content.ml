module Journal = Keeper_child_content_journal
module Read = Keeper_child_content_read
let ( let* ) = Result.bind

type route = Receivers of string | Records of string | Hints of string
let permission = Masc_domain.CanAdmin

let route path =
  match String.split_on_char '/' path with
  | [""; "api"; "v1"; "keepers"; name; "child-content"; "receivers"] ->
      Some (Receivers (Uri.pct_decode name))
  | [""; "api"; "v1"; "keepers"; name; "child-content"; "records"] ->
      Some (Records (Uri.pct_decode name))
  | [""; "api"; "v1"; "keepers"; name; "child-content"; "hints"] ->
      Some (Hints (Uri.pct_decode name))
  | _ -> None

let error status code = status, Read.failure code

let store_error error_value =
  let code = Read.error_code_of_journal error_value in
  let status = match code with
    | Read.Store_missing -> `Not_found
    | Invalid_scope | Invalid_observation | Invalid_query | Invalid_keeper -> `Bad_request
    | Cursor_store_mismatch | Cursor_ahead | Conflicting_observation -> `Conflict
    | Store_corrupt | Sequence_exhausted | Io_failed | Directory_prepare_failed
    | Store_unavailable | Commit_unconfirmed -> `Service_unavailable in
  error status code

(* Query fields are protocol members. No spelling of their values grants
   invocation authority or selects a workspace. *)
let strict_query request allowed =
  let fields = Uri.query (Uri.of_string request.Httpun.Request.target) in
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
     || List.exists (fun (name, values) -> not (List.mem name allowed)
           || List.length values <> 1) fields then Error ()
  else Ok (List.map (fun (name, values) -> name, List.hd values) fields)

let records_query fields =
  match List.assoc_opt "receiver_generation" fields,
        List.assoc_opt "session_id" fields, List.assoc_opt "client_uuid" fields with
  | Some receiver_generation, Some session_id, Some client_uuid
      when receiver_generation <> "" && session_id <> "" && client_uuid <> "" ->
      let* after = match List.assoc_opt "store_id" fields,
                        List.assoc_opt "after_sequence" fields with
        | None, None -> Ok None
        | Some store_id, Some raw ->
            (match int_of_string_opt raw with
             | Some after_sequence when String.equal raw (string_of_int after_sequence) ->
                 Journal.cursor ~store_id ~after_sequence |> Result.map Option.some
                 |> Result.map_error (fun _ -> ())
             | Some _ | None -> Error ())
        | _ -> Error () in
      Ok (receiver_generation, session_id, client_uuid, after)
  | _ -> Error ()

let records_response ~base_path ~keeper_name request =
  let fields = strict_query request
    ["receiver_generation"; "session_id"; "client_uuid"; "store_id"; "after_sequence"] in
  match Result.bind fields records_query with
  | Error () -> error `Bad_request Read.Invalid_query
  | Ok (receiver_generation, session_id, client_uuid, after) ->
      match Journal.open_reader ~base_path ~keeper_name
          ~receiver_generation ~session_id ~client_uuid with
      | Error e -> store_error e
      | Ok reader ->
          let result = Journal.read ?after reader in
          match result.result with
          | Error e -> store_error e
          | Ok snapshot ->
              let redact_text = Keeper_secret_redaction.redact_text
                (Keeper_secret_redaction.snapshot ~base_path ~keeper_name) in
              let scope : Read.scope =
                {keeper_name; receiver={receiver_generation; session_id; client_uuid}} in
              `OK, Read.records_of_journal ~redact_text ~scope ~snapshot
                ~cleanup_failures:result.cleanup_failure

let receivers_response ~base_path ~keeper_name request =
  match strict_query request [] with
  | Error () -> error `Bad_request Read.Invalid_query
  | Ok _ ->
      let result = Journal.discover ~base_path ~keeper_name in
      match result.result with
      | Error e -> store_error e
      | Ok entries -> `OK, Read.receivers_of_journal ~keeper_name ~entries
          ~cleanup_failures:result.cleanup_failure

let hints_response ~base_path ~keeper_name request =
  match strict_query request [] with
  | Error () -> error `Bad_request Read.Invalid_query
  | Ok _ ->
      let result = Journal.discover_hints ~base_path ~keeper_name in
      match result.result with
      | Error e -> store_error e
      | Ok entries -> `OK, Read.hints_of_journal ~keeper_name ~entries
          ~cleanup_failures:result.cleanup_failure

let response state request route =
  let keeper_name = match route with Receivers name | Records name | Hints name -> name in
  if not (Keeper_config.validate_name keeper_name) then
    `Bad_request, Read.to_json (Read.failure Read.Invalid_keeper)
  else
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    let status, body = match route with
      | Receivers _ -> receivers_response ~base_path ~keeper_name request
      | Records _ -> records_response ~base_path ~keeper_name request
      | Hints _ -> hints_response ~base_path ~keeper_name request in
    status, Read.to_json body

let handle_get state request reqd route =
  let status, body = response state request route in
  Server_auth.respond_json_value_with_cors ~status request reqd body
