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
let render_keeper_chat_history_page config name
    ({ history_messages; next_cursor } : Keeper_chat_store.history_page) =
  let base_dir = (config : Workspace.config).base_path in
  let trace_block_by_turn_ref = keeper_chat_trace_blocks config name in
  let messages =
    Keeper_chat_store.to_json_array ~omit_stream_contract:true ~base_dir
      ?trace_block_by_turn_ref history_messages
  in
  `Assoc
    [ "schema", `String "masc.keeper_chat_history.page.v2"
    ; "messages", messages
    ; "has_more", `Bool (Option.is_some next_cursor)
    ; "next_cursor", (match next_cursor with
        | Some cursor -> `String (Keeper_chat_history_page.cursor_to_string cursor)
        | None -> `Null)
    ]
;;

let keeper_chat_history_page_json ?max_total config name ~cursor =
  let base_dir = (config : Workspace.config).base_path in
  Keeper_chat_store.load_history_page_result ~base_dir ~keeper_name:name
    ?cursor ?max_total ()
  |> Result.map (render_keeper_chat_history_page config name)
;;

let cached_keeper_chat_history_json config name =
  Server_keeper_chat_history_read.cached_json ~config ~keeper_name:name
    ~ttl:Limits.keeper_hot_path_cache_ttl_s ~render:(render_keeper_chat_history config name)
;;

let head_page_source_stamp ~path =
  match Keeper_chat_history_page.inspect_source ~path with
  | Error error -> Error error
  | Ok chat_source when not (Keeper_chat_history_page.source_is_present chat_source) ->
    Ok None
  | Ok chat_source -> Ok (Some (Keeper_chat_history_page.source_fingerprint chat_source))
;;

(* Dedicated bounded cache for cursorless physical head pages. Redaction,
   trace enrichment, and audio file status are resolved on every response.
   Kept separate from [Dashboard_cache] so page reads cannot evict shared
   fleet/dashboard hot keys, and keyed by clamped page limit ([1, 400])
   matching [Keeper_chat_store.load_history_page_result]. *)
module Head_page_cache = struct
  type entry =
    { stamp : string
    ; page : Keeper_chat_history_page.page
    ; expires_at : float
    ; seq : int
    }

  type t =
    { mu : Stdlib.Mutex.t
    ; max_entries : int
    ; ttl_s : float
    ; next_seq : int ref
    ; entries : (string, entry) Hashtbl.t
    ; order : (string * int) Queue.t
    }

  let create ~max_entries ~ttl_s =
    { mu = Stdlib.Mutex.create ()
    ; max_entries
    ; ttl_s
    ; next_seq = ref 0
    ; entries = Hashtbl.create max_entries
    ; order = Queue.create ()
    }
  ;;

  let with_lock t f =
    Stdlib.Mutex.lock t.mu;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mu) f
  ;;

  let rec prune_order_head t ~now =
    match Queue.peek_opt t.order with
    | None -> ()
    | Some (key, expected_seq) ->
      (match Hashtbl.find_opt t.entries key with
       | Some { seq; expires_at; _ } when seq = expected_seq && now <= expires_at -> ()
       | Some { seq; _ } when seq = expected_seq ->
         ignore (Queue.take_opt t.order);
         Hashtbl.remove t.entries key;
         prune_order_head t ~now
       | Some _ | None ->
         ignore (Queue.take_opt t.order);
         prune_order_head t ~now)
  ;;

  let compact_order_if_needed t ~now =
    if Queue.length t.order > t.max_entries * 2
    then (
      let live = Queue.create () in
      Queue.iter
        (fun ((key, expected_seq) as item) ->
          match Hashtbl.find_opt t.entries key with
          | Some { seq; expires_at; _ } when seq = expected_seq && now <= expires_at ->
            Queue.add item live
          | Some { seq; _ } when seq = expected_seq ->
            Hashtbl.remove t.entries key
          | Some _ | None -> ())
        t.order;
      Queue.clear t.order;
      Queue.transfer live t.order)
  ;;

  let rec evict_to_capacity t =
    if Hashtbl.length t.entries >= t.max_entries
    then (
      match Queue.take_opt t.order with
      | None -> ()
      | Some (oldest, expected_seq) ->
        (match Hashtbl.find_opt t.entries oldest with
         | Some { seq; _ } when seq = expected_seq -> Hashtbl.remove t.entries oldest
         | Some _ | None -> ());
        evict_to_capacity t)
  ;;

  let get t ~key ~stamp =
    let now = Time_compat.now () in
    with_lock t (fun () ->
      match Hashtbl.find_opt t.entries key with
      | Some { stamp = cached_stamp; page; expires_at; _ }
        when now <= expires_at && String.equal cached_stamp stamp ->
        Some page
      | Some _ ->
        Hashtbl.remove t.entries key;
        None
      | None -> None)
  ;;

  let set t ~key ~stamp ~page =
    let now = Time_compat.now () in
    let expires_at = now +. t.ttl_s in
    with_lock t (fun () ->
      prune_order_head t ~now;
      if not (Hashtbl.mem t.entries key) then evict_to_capacity t;
      incr t.next_seq;
      let seq = !(t.next_seq) in
      Queue.add (key, seq) t.order;
      Hashtbl.replace t.entries key { stamp; page; expires_at; seq };
      compact_order_if_needed t ~now)
  ;;

  let remove t ~key =
    with_lock t (fun () -> Hashtbl.remove t.entries key)
  ;;
end

let head_page_cache =
  Head_page_cache.create ~max_entries:32 ~ttl_s:Limits.keeper_hot_path_cache_ttl_s
;;

(* Match [Keeper_chat_store.load_history_page_result]'s clamping (at most 400
   rows) so equivalent [limit] values share one cache slot and arbitrary query
   ints cannot flood cache capacity. *)
let max_page_limit = 400

let normalize_page_limit max_total =
  match max_total with
  | None -> max_page_limit
  | Some n -> max 1 (min n max_page_limit)
;;

let cached_head_page ?max_total config name =
  let effective_limit = normalize_page_limit max_total in
  let key =
    Printf.sprintf "%s\000%s\000%d" (Workspace.masc_dir config) name effective_limit
  in
  let path =
    Keeper_chat_store.chat_path ~base_dir:config.Workspace.base_path ~keeper_name:name
  in
  let read () = Keeper_chat_history_page.read ~path ~owner:name ~max_rows:effective_limit () in
  match head_page_source_stamp ~path with
  | Error Keeper_chat_history_page.Stale_cursor | Ok None ->
    (* Fall back on pre-read races and avoid caching absent chat files. *)
    Head_page_cache.remove head_page_cache ~key;
    read ()
  | Error (Keeper_chat_history_page.Invalid_cursor _
          | Keeper_chat_history_page.Invalid_row _
          | Keeper_chat_history_page.Row_exceeds_window
          | Keeper_chat_history_page.Io_error _) as err ->
    Head_page_cache.remove head_page_cache ~key;
    err
  | Ok (Some stamp) ->
    (match Head_page_cache.get head_page_cache ~key ~stamp with
     | Some page -> Ok page
     | None ->
       (match read () with
        | Error _ as err ->
          Head_page_cache.remove head_page_cache ~key;
          err
        | Ok page ->
          (match head_page_source_stamp ~path with
           | Ok (Some after) when String.equal stamp after ->
             Head_page_cache.set head_page_cache ~key ~stamp ~page
           | Ok (Some _ | None) | Error _ ->
             Head_page_cache.remove head_page_cache ~key);
          Ok page))
;;

let cached_head_page_json ?max_total config name =
  let open Result.Syntax in
  let* page = cached_head_page ?max_total config name in
  let* page =
    Keeper_chat_store.project_history_page_result ~base_dir:config.Workspace.base_path
      ~keeper_name:name page
  in
  Ok (render_keeper_chat_history_page config name page)
;;

let keeper_chat_initial_reply_json config name =
  Server_keeper_chat_history_read.initial_reply_json ~config ~keeper_name:name
    ~render:(fun turn -> `List (Option.to_list (Option.map autonomous_turn_json turn)))
;;

let history_page_error_response (error : Keeper_chat_history_page.error) =
  let status : Httpun.Status.t =
    match error with
    | Invalid_cursor _ -> `Bad_request
    | Stale_cursor -> `Conflict
    | Invalid_row _ | Row_exceeds_window | Io_error _ -> `Internal_server_error
  in
  status, Types.error_json (Keeper_chat_history_page.error_to_string error)
;;

let respond_head_page ?max_total config name request reqd =
  let extra_headers = Server_auth.admitted_cors_headers request in
  (* Project and encode the current page under one read worker admission. *)
  Http.Response.json_value_from_cpu ~name:__FUNCTION__ ~compress:true ~request ~extra_headers
    (fun () ->
       match cached_head_page_json ?max_total config name with
       | Ok page -> `OK, page
       | Error error -> history_page_error_response error)
    reqd
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
      (match cursor with
       | None -> respond_head_page ?max_total config name request reqd
       | Some _ ->
         let page =
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            keeper_chat_history_page_json ?max_total config name ~cursor)
         in
         (match page with
          | Ok page ->
            Http.Response.json_value_on_cpu
              ~status:`OK ~compress:true ~request
              ~extra_headers:(Server_auth.admitted_cors_headers request)
              page reqd
          | Error error ->
            let status, value = history_page_error_response error in
            Server_auth.respond_json_value_with_cors ~status request reqd value)))
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
