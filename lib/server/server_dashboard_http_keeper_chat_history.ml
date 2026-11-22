(* See server_dashboard_http_keeper_chat_history.mli. *)

module Http = Http_server_eio
module Limits = Server_dashboard_http_keeper_read_limits
module Types = Server_dashboard_http_keeper_api_types
module String_map = Map.Make (String)
module Chat_turn_map = Map.Make (struct
  type t = Ids.Turn_ref.t
  let compare left right =
    match String.compare (Ids.Turn_ref.trace_id left) (Ids.Turn_ref.trace_id right) with
    | 0 -> Int.compare (Ids.Turn_ref.absolute_turn left) (Ids.Turn_ref.absolute_turn right)
    | order -> order
end)

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
       and the TUI re-reads it on each chat change. Serialising it, hashing
       it for its validator and compressing it held the main domain on every
       read, so that runs
       on the CPU executor. Responses in general stay on the serving fiber:
       the executor also runs dashboard computes, and a timeout or error
       answer must not wait behind them. *)
    (match read config name with
     | Ok body ->
       Http.Response.json_value_on_cpu
         ~status:`OK ~request
         ~extra_headers:(Server_auth.admitted_cors_headers request)
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
