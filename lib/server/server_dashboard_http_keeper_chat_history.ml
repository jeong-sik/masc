(* See server_dashboard_http_keeper_chat_history.mli. *)

module Http = Http_server_eio
module Limits = Server_dashboard_http_keeper_read_limits
module Types = Server_dashboard_http_keeper_api_types
module String_map = Map.Make (String)

let keeper_chat_allowed_trace_ids (m : Keeper_meta_contract.keeper_meta) =
  [ Keeper_id.Trace_id.to_string m.runtime.trace_id ]
;;

(* The canonical autonomous User/Assistant/Tool exchange lives in the Keeper's
   AGENT_CORE checkpoint, not as duplicate chat-store rows. This read projection uses
   typed turn identity only for stable dashboard grouping and exact raw-trace
   lookup; it is not the Keeper's semantic continuity mechanism. Final text
   and work trace come from the same exact AGENT_CORE run. The [id] is required:
   the dashboard history schema drops any row without one. Its value is a pure
   schema satisfier -- the dashboard re-mints its entry id from
   [autonomous_turn.turn_id] and never reads this field. *)
let autonomous_turn_json (turn : Keeper_autonomous_turn_source.turn) =
  let trace_fields =
    match turn.trace with
    | [] -> []
    | trace ->
      [ ( "blocks"
        , Keeper_chat_blocks.blocks_to_yojson
            [ Keeper_chat_blocks.Trace { trace; omitted = 0 } ] ) ]
  in
  `Assoc
    ([ "id", `String ("autonomous:" ^ turn.turn_id)
     ; "role", `String "assistant"
     ; "ts", `Float turn.started_at
     ; ( "content"
       , match turn.final_text with
         | Some text -> `String text
         | None -> `Null )
     ; "autonomous_turn", `Assoc [ "turn_id", `String turn.turn_id ]
     ]
     @ trace_fields)
;;

let keeper_chat_trace_blocks config name =
  match Keeper_meta_store.read_meta config name with
  | Ok (Some m) ->
    Some
      (Server_dashboard_http_keeper_api_trace.chat_trace_block_by_turn_ref
         ~max_lines:Limits.trajectory_max_limit
         ~config
         ~keeper_name:name
         ~allowed_trace_ids:(keeper_chat_allowed_trace_ids m))
  | Ok None -> None
  | Error err ->
    Log.Keeper.warn
      "dashboard keeper chat history: read_meta failed for %s; trace enrichment skipped: %s"
      name
      err;
    None
;;

let keeper_chat_skill_projection_schema =
  "masc.keeper_chat.skill_activations.v2"
;;

let chat_row_turn_ref fields =
  match List.assoc_opt "turn_ref" fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | Some _ | None -> (
      match List.assoc_opt "autonomous_turn" fields with
      | Some (`Assoc autonomous) -> (
          match List.assoc_opt "turn_id" autonomous with
          | Some (`String value) when String.trim value <> "" -> Some value
          | Some _ | None -> None)
      | Some _ | None -> None)
;;

let chat_row_reports_skill_activation fields =
  let is_skill_activation fields =
    match List.assoc_opt "name" fields with
    | Some (`String name) ->
      String.equal name Keeper_tool_composition_catalog.skill_tool_name
      || Option.is_some
           (Keeper_tool_composition_catalog.skill_source_of_tool_name name)
    | Some _ | None -> false
  in
  match List.assoc_opt "blocks" fields with
  | Some (`List blocks) ->
    List.exists
      (function
        | `Assoc block -> (
            match List.assoc_opt "t" block, List.assoc_opt "trace" block with
            | Some (`String "trace"), Some (`List steps) ->
              List.exists
                (function
                  | `Assoc step -> is_skill_activation step
                  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _
                  | `Null | `String _ -> false)
                steps
            | Some _, Some _ | Some _, None | None, _ -> false)
        | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
        | `String _ -> false)
      blocks
  | Some _ | None -> false
;;

let composition_execution_projection ~config ~keeper_name activations =
  let module Execution = Keeper_skill_execution_projection in
  let execution_ids = List.filter_map (fun (activation : Keeper_skill_activation_ledger.activation) ->
    match activation.invocation with
    | Composition_invocation { execution_id; _ } -> Some (Ids.Execution_id.to_string execution_id)
    | Instruction_invocation _ | Nested_composition_invocation _ -> None) activations in
  let rows = match execution_ids with
    | [] -> Ok []
    | _ ->
      let store = Dated_jsonl.open_store
          (Dated_jsonl.Store.at (Workspace.dated_store_root config) Dated_jsonl.Store.Root.Tool_calls) in
      Keeper_tool_call_index.by_execution_ids ~store ~keeper_name ~execution_ids in
  fun (activation : Keeper_skill_activation_ledger.activation) ->
    match activation.invocation with
    | Instruction_invocation _ -> None
    | Composition_invocation _ | Nested_composition_invocation _ ->
      Some (Execution.of_rows ~keeper_name ~rows activation)
;;

let keeper_chat_skill_activations_json ~status ?detail
    ?(execution_for_activation = fun _ -> None) activations =
  `Assoc
    ([ "schema", `String keeper_chat_skill_projection_schema
     ; "status", `String status
     ; ( "activations"
       , `List
           (List.map (fun activation ->
              let json = Keeper_skill_activation_ledger.activation_to_yojson activation in
              match json, execution_for_activation activation with
              | `Assoc fields, Some execution ->
                `Assoc (("execution", Keeper_skill_execution_projection.to_yojson execution) :: fields)
              | _, None -> json
              | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _), Some _ -> json)
              activations) )
     ]
     @ Json_util.string_field_if_present "detail" detail)
;;

let attach_keeper_chat_skill_activations ~config ~keeper_name rows =
  let resolved_by_trace = ref String_map.empty in
  let resolve_trace trace_id =
    match String_map.find_opt trace_id !resolved_by_trace with
    | Some outcome -> outcome
    | None ->
      let outcome =
        Keeper_skill_activation_projection.resolve_trace_string ~config trace_id
      in
      resolved_by_trace := String_map.add trace_id outcome !resolved_by_trace;
      outcome
  in
  let enrich = function
    | `Assoc fields as row -> (
        match List.assoc_opt "role" fields, chat_row_turn_ref fields with
        | Some (`String "assistant"), Some turn_ref_raw ->
          let reports_skill = chat_row_reports_skill_activation fields in
          let projection =
            match Ids.Turn_ref.of_string turn_ref_raw with
            | None ->
              if reports_skill then
                Some
                  (keeper_chat_skill_activations_json
                     ~status:"invalid_turn_ref"
                     ~detail:"The chat row carries an invalid exact turn_ref"
                     [])
              else None
            | Some turn_ref ->
              let trace_id = Ids.Turn_ref.trace_id turn_ref in
              (match resolve_trace trace_id with
               | Error detail ->
                 if reports_skill then
                   Some
                     (keeper_chat_skill_activations_json ~status:"unavailable"
                        ~detail:detail [])
                 else None
               | Ok
                   (Keeper_skill_activation_projection.Trace_available
                      { ledger; _ }) ->
                 let activations =
                   Keeper_skill_activation_ledger.activations ledger
                   |> List.filter
                        (fun
                          (activation :
                            Keeper_skill_activation_ledger.activation)
                        -> Ids.Turn_ref.equal activation.turn_ref turn_ref)
                 in
                 (match activations, reports_skill with
                  | _ :: _, _ ->
                    Some
                      (keeper_chat_skill_activations_json ~status:"available"
                         ~execution_for_activation:(composition_execution_projection ~config ~keeper_name activations)
                         activations)
                  | [], true ->
                    Some
                      (keeper_chat_skill_activations_json ~status:"missing"
                         ~detail:
                           "The exact turn ledger contains no activation for the recorded Skill call"
                         [])
                  | [], false -> None)
               | Ok
                   (Keeper_skill_activation_projection.Trace_not_recorded _) ->
                 if reports_skill then
                   Some
                     (keeper_chat_skill_activations_json ~status:"not_recorded"
                        ~detail:
                          "No retained Skill activation ledger exists for this exact trace"
                        [])
                 else None
               | Ok
                   (Keeper_skill_activation_projection.Trace_unavailable
                      { reason; detail; _ }) ->
                 if reports_skill then
                   Some
                     (keeper_chat_skill_activations_json ~status:"unavailable"
                        ~detail:(reason ^ ": " ^ detail) [])
                 else None)
          in
          (match projection with
           | None -> row
           | Some projection ->
             `Assoc
               (("skill_activations", projection)
                :: List.remove_assoc "skill_activations" fields))
        | Some _, Some _ | Some _, None | None, _ -> row)
    | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
      as row -> row
  in
  match rows with
  | `List rows -> `List (List.map enrich rows)
  | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
    as other -> other
;;

let render_keeper_chat_history config name messages autonomous_turns =
  let base_dir = (config : Workspace.config).base_path in
  let trace_block_by_turn_ref = keeper_chat_trace_blocks config name in
  let chat_rows = Keeper_chat_store.to_json_array ~base_dir ?trace_block_by_turn_ref messages in
  (* Appended without pretending the two stores share a wall clock. Each
     autonomous row and every completed direct turn carry a persisted
     [turn_ref] whose absolute turn is the client's structural cross-store
     order. Rows without that authority remain in their producer order. *)
  let autonomous_rows =
    List.map autonomous_turn_json autonomous_turns
  in
  let rows =
    match autonomous_rows, chat_rows with
    | [], _ -> chat_rows
    | _ :: _, `List rows -> `List (rows @ autonomous_rows)
    | _ :: _, other ->
      Log.Keeper.warn
        "dashboard keeper chat history: chat store for %s did not emit an array; %d \
         autonomous turn(s) omitted"
        name
        (List.length autonomous_rows);
      other
  in
  attach_keeper_chat_skill_activations ~config ~keeper_name:name rows
;;

let keeper_chat_history_json config name =
  Server_keeper_chat_history_read.read_json ~config ~keeper_name:name
    ~render:(render_keeper_chat_history config name)
;;

(* Exact pages keep every role in file append order. The role-based transcript
   tail remains separate; a timestamp cannot represent a position after clock
   regression or among rows stamped at the same instant. *)
let keeper_chat_history_page_json ?max_total config name ~cursor =
  let base_dir = (config : Workspace.config).base_path in
  let open Result.Syntax in
  let* { Keeper_chat_store.history_messages; next_cursor } =
    Keeper_chat_store.load_history_page_result ~base_dir ~keeper_name:name
      ?cursor ?max_total ()
  in
  let trace_block_by_turn_ref = keeper_chat_trace_blocks config name in
  let messages =
    Keeper_chat_store.to_json_array ~omit_stream_contract:true ~base_dir
      ?trace_block_by_turn_ref history_messages
    |> attach_keeper_chat_skill_activations ~config ~keeper_name:name
  in
  Ok (`Assoc
    [ "schema", `String "masc.keeper_chat_history.page.v2"
    ; "messages", messages
    ; "has_more", `Bool (Option.is_some next_cursor)
    ; "next_cursor", (match next_cursor with
        | Some cursor -> `String (Keeper_chat_history_page.cursor_to_string cursor)
        | None -> `Null)
    ])
;;

let cached_keeper_chat_history_json config name =
  Server_keeper_chat_history_read.cached_json ~config ~keeper_name:name
    ~ttl:Limits.keeper_hot_path_cache_ttl_s ~render:(render_keeper_chat_history config name)
;;

let keeper_chat_initial_reply_json config name =
  Server_keeper_chat_history_read.initial_reply_json ~config ~keeper_name:name
    ~render:(fun turn -> `List (Option.to_list (Option.map autonomous_turn_json turn)))
;;

let handle_page_get state req request reqd name =
  if not (Keeper_config.validate_name name) then
    Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
      (Types.error_json (Printf.sprintf "invalid keeper name: %s" name))
  else (
    let module Page = Keeper_chat_history_page in
    let parsed_cursor =
      match Server_utils.query_param req "cursor" with
      | None -> Ok None
      | Some raw -> Page.cursor_of_string raw |> Result.map Option.some
    in
    let limit_raw = Server_utils.query_param req "limit" in
    match parsed_cursor, limit_raw with
    | Error error, _ ->
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (Types.error_json (Page.error_to_string error))
    | _, Some raw when int_of_string_opt (String.trim raw) = None ->
      Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
        (Types.error_json "limit must be an integer")
    | Ok cursor, limit_raw ->
      let max_total = Option.bind limit_raw (fun raw -> int_of_string_opt (String.trim raw)) in
      let config = Mcp_server.workspace_config state in
      let page = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        keeper_chat_history_page_json ?max_total config name ~cursor) in
      (match page with
       | Ok page -> Server_auth.respond_json_value_with_cors ~status:`OK request reqd page
       | Error error ->
         let status = match error with
           | Page.Invalid_cursor _ -> `Bad_request
           | Page.Stale_cursor -> `Conflict
           | Page.Invalid_row _ | Page.Row_exceeds_window | Page.Io_error _ -> `Internal_server_error
         in
         Server_auth.respond_json_value_with_cors ~status request reqd
           (Types.error_json (Page.error_to_string error))))
;;

let handle_read read state request reqd name =
  if not (Keeper_config.validate_name name) then
    (* Reject before touching the cache: the cache key embeds the raw
       name, so unvalidated garbage names would mint unbounded
       process-global cache entries (the sibling /tool-calls route
       already validates). *)
    Server_auth.respond_json_value_with_cors ~status:`Bad_request request reqd
      (Types.error_json (Printf.sprintf "invalid keeper name: %s" name))
  else
    let config = Mcp_server.workspace_config state in
    (* The body is hundreds of KB for a tool-heavy keeper (845 KB measured)
       and the TUI polls it. Serialising it, hashing it for its validator
       and compressing it held the main domain on every poll, so that runs
       on the CPU executor. Responses in general stay on the serving fiber:
       the executor also runs dashboard computes, and a timeout or error
       answer must not wait behind them. *)
    (match read config name with
     | Ok body ->
       Http.Response.json_value_on_cpu
         ~status:`OK ~request
         ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin request))
         body reqd
     | Error error ->
       let status = match error with
         | Server_keeper_chat_history_read.Unknown_keeper -> `Not_found
         | Server_keeper_chat_history_read.History_unavailable detail ->
           Log.Keeper.warn "dashboard keeper chat history unavailable for %s: %s" name detail;
           `Service_unavailable
       in
       Server_auth.respond_json_value_with_cors ~status request reqd
         (Types.error_json (Server_keeper_chat_history_read.error_to_string error)))
;;

let handle_get = handle_read cached_keeper_chat_history_json
let handle_initial_reply_get = handle_read keeper_chat_initial_reply_json
