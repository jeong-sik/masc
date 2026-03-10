(** MASC MCP Server - Eio Native Entry Point
    MCP Streamable HTTP Transport with Eio concurrency (OCaml 5.x)

    Uses h2-eio for HTTP/2 with unlimited SSE streams per connection.
    HTTP/2 multiplexing eliminates browser's 6-connection-per-domain limit.
*)

[@@@warning "-32-69"]  (* Suppress unused values/fields during migration *)

open Cmdliner

(** Module aliases *)
module Http = Masc_mcp.Http_server_eio
module Http_h2 = Masc_mcp.Http_server_h2
module Mcp_session = Masc_mcp.Mcp_session
module Mcp_server = Masc_mcp.Mcp_server
module Mcp_eio = Masc_mcp.Mcp_server_eio
module Room = Masc_mcp.Room
module Room_utils = Masc_mcp.Room_utils
module Tool_keeper = Masc_mcp.Tool_keeper
module Tool_operator = Masc_mcp.Tool_operator
module Operator_control = Masc_mcp.Operator_control
module Command_plane_v2 = Masc_mcp.Command_plane_v2
module Dashboard_mission = Masc_mcp.Dashboard_mission
module Tool_audit = Masc_mcp.Tool_audit
module Graphql_api = Masc_mcp.Graphql_api
module Types = Masc_mcp.Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Board_listener = Masc_mcp.Board_listener
module Council = Masc_mcp.Council
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Masc_mcp.Mcp_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Masc_mcp.Safe_ops
module Context_manager = Masc_mcp.Context_manager
module Llm_client = Masc_mcp.Llm_client
module Tool_perpetual = Masc_mcp.Tool_perpetual
module Tool_mdal = Masc_mcp.Tool_mdal
module Tool_board = Masc_mcp.Tool_board
module Process_eio = Masc_mcp.Process_eio
module Mdal = Masc_mcp.Mdal

(** MCP Protocol Versions *)
(* ============================================ *)
(* HTTP Bearer Token Authentication             *)
(* ============================================ *)

(** Extract Bearer token from Authorization header *)
let extract_bearer_token request =
  match Httpun.Headers.get request.Httpun.Request.headers "authorization" with
  | Some auth_header ->
    if String.length auth_header > 7 &&
       String.lowercase_ascii (String.sub auth_header 0 7) = "bearer " then
      Some (String.sub auth_header 7 (String.length auth_header - 7))
    else
      None
  | None -> None

(** Verify Bearer token for MCP endpoints *)
let verify_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Types.enabled then
    Ok None  (* Auth disabled - allow all *)
  else
    match extract_bearer_token request with
    | None when not auth_config.require_token ->
      Ok None  (* Token not required *)
    | None ->
      Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token ->
      (* Try to find agent by token hash *)
      let token_hash = Auth.sha256_hash token in
      let creds = Auth.list_credentials base_path in
      match List.find_opt (fun c -> c.Types.token = token_hash) creds with
      | None -> Error "Invalid token"
      | Some cred ->
        (* Check expiry *)
        match cred.expires_at with
        | None -> Ok (Some cred)
        | Some exp_str ->
          let now = Types.now_iso () in
          if now > exp_str then
            Error ("Token expired for " ^ cred.agent_name)
          else
            Ok (Some cred)

let verify_operator_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Types.enabled then
    Error "/mcp/operator requires token auth to be enabled for this room."
  else if not auth_config.require_token then
    Error "/mcp/operator requires bearer token auth (require_token=true)."
  else
    match extract_bearer_token request with
    | None ->
        Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        match Auth.find_credential_by_token base_path ~token with
        | Ok cred -> Ok (Some cred)
        | Error err -> Error (Types.masc_error_to_string err))

let mcp_protocol_versions = Mcp_server.supported_protocol_versions

let mcp_protocol_version_default = Mcp_server.default_protocol_version

let protocol_version_by_session : (string, string) Hashtbl.t = Hashtbl.create 128
let mcp_profile_by_session : (string, Mcp_eio.tool_profile) Hashtbl.t = Hashtbl.create 128

(** Get default base path from ME_ROOT or current directory *)
let default_base_path () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some path -> path
  | None -> Sys.getcwd ()

(** Validate MCP-Protocol-Version *)
let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let remember_protocol_version session_id version =
  if is_valid_protocol_version version then
    Hashtbl.replace protocol_version_by_session session_id version

let remember_mcp_profile session_id profile =
  Hashtbl.replace mcp_profile_by_session session_id profile

let forget_mcp_session session_id =
  Hashtbl.remove protocol_version_by_session session_id;
  Hashtbl.remove mcp_profile_by_session session_id

let profile_label = function
  | Mcp_eio.Full -> "/mcp"
  | Mcp_eio.Operator_remote -> "/mcp/operator"

let validate_mcp_session_profile ~profile session_id =
  match Hashtbl.find_opt mcp_profile_by_session session_id with
  | None -> Ok ()
  | Some existing when existing = profile -> Ok ()
  | Some existing ->
      Error
        (Printf.sprintf "Session %s belongs to %s, not %s." session_id
           (profile_label existing) (profile_label profile))

let validate_mcp_session_delete_profile ~profile session_id =
  match profile with
  | Mcp_eio.Operator_remote -> (
      match Hashtbl.find_opt mcp_profile_by_session session_id with
      | Some Mcp_eio.Operator_remote -> Ok ()
      | Some existing ->
          Error
            (Printf.sprintf "Session %s belongs to %s, not %s." session_id
               (profile_label existing) (profile_label profile))
      | None ->
          Error
            (Printf.sprintf
               "Session %s is not registered on %s." session_id
               (profile_label profile)))
  | Mcp_eio.Full -> validate_mcp_session_profile ~profile session_id

(** Extract protocol version from initialize request body *)
let protocol_version_from_body body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    match Mcp_server.jsonrpc_request_of_yojson json with
    | Ok req when String.equal req.method_ "initialize" ->
        let version =
          Mcp_server.protocol_version_from_params req.params
          |> Mcp_server.normalize_protocol_version
        in
        Some version
    | _ -> None
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

(** Get session_id from query string *)
let get_session_id_query target =
  match String.split_on_char '?' target with
  | [_; query] ->
      query
      |> String.split_on_char '&'
      |> List.find_map (fun param ->
          match String.split_on_char '=' param with
          | ["session_id"; v] | ["sessionId"; v] -> Some v
          | _ -> None)
  | _ -> None

let capitalize_ascii (s : string) =
  if s = "" then s
  else
    let first = Char.uppercase_ascii s.[0] |> String.make 1 in
    let rest =
      if String.length s > 1 then
        String.sub s 1 (String.length s - 1) |> String.lowercase_ascii
      else
        ""
    in
    first ^ rest

let title_case_header_name (header_name : string) =
  header_name
  |> String.split_on_char '-'
  |> List.map capitalize_ascii
  |> String.concat "-"

let get_header_any_case (headers : Httpun.Headers.t) (name : string) =
  match Httpun.Headers.get headers name with
  | Some _ as value -> value
  | None ->
      let title_case = title_case_header_name name in
      (match Httpun.Headers.get headers title_case with
       | Some _ as value -> value
       | None -> Httpun.Headers.get headers (String.uppercase_ascii name))

let get_cookie_value (request : Httpun.Request.t) cookie_name =
  match get_header_any_case request.headers "cookie" with
  | None -> None
  | Some raw ->
      raw
      |> String.split_on_char ';'
      |> List.find_map (fun part ->
           match String.split_on_char '=' (String.trim part) with
           | key :: value_parts
             when String.lowercase_ascii (String.trim key)
                  = String.lowercase_ascii cookie_name ->
               let value = String.concat "=" value_parts |> String.trim in
               if value = "" then None else Some value
           | _ -> None)

(** Get session_id from either query param or header *)
let get_session_id_any (request : Httpun.Request.t) =
  match get_session_id_query request.target with
  | Some _ as id -> id
  | None ->
      (match get_header_any_case request.headers "mcp-session-id" with
       | Some _ as id -> id
       | None -> get_cookie_value request "mcp-session-id")

(** Build legacy SSE messages endpoint URL (event: endpoint) *)
let legacy_messages_endpoint_url (request : Httpun.Request.t) session_id =
  match Httpun.Headers.get request.headers "host" with
  | Some host ->
      let proto =
        match Httpun.Headers.get request.headers "x-forwarded-proto" with
        | Some p -> p
        | None ->
            (* Cloudflare tunnel domains are always HTTPS *)
            if String.length host >= 17 && String.sub host 0 17 = "masc.crying.pict" then "https"
            else "http"
      in
      Printf.sprintf "%s://%s/messages?session_id=%s" proto host session_id
  | None -> Printf.sprintf "/messages?session_id=%s" session_id

(** Get protocol version from headers *)
let get_protocol_version (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "mcp-protocol-version" with
  | Some v -> v
  | None -> mcp_protocol_version_default

let get_protocol_version_for_session ?session_id request =
  match session_id with
  | Some id ->
      (match Hashtbl.find_opt protocol_version_by_session id with
      | Some v -> v
      | None -> get_protocol_version request)
  | None -> get_protocol_version request

(** Parse query param from request target *)
let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key

let int_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s -> (try int_of_string s with Failure _ -> default)

let bool_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s ->
      let v = String.lowercase_ascii (String.trim s) in
      if v = "1" || v = "true" || v = "yes" || v = "y" then true
      else if v = "0" || v = "false" || v = "no" || v = "n" then false
      else default

let clamp ~min_v ~max_v v = max min_v (min max_v v)

let take n lst =
  let rec loop acc remaining xs =
    if remaining <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n lst

let drop n lst =
  let rec loop remaining xs =
    if remaining <= 0 then xs
    else
      match xs with
      | [] -> []
      | _ :: rest -> loop (remaining - 1) rest
  in
  loop n lst

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let board_sort_order_of_request request =
  let to_sort = function
    | "trending" -> Board_dispatch.Trending
    | "recent" | "new" -> Board_dispatch.Recent
    | "updated" | "active" -> Board_dispatch.Updated
    | "discussed" | "comments" -> Board_dispatch.Discussed
    | _ -> Board_dispatch.Hot
  in
  match query_param request "sort_by" with
  | None -> Board_dispatch.Hot
  | Some sort -> to_sort (String.lowercase_ascii (String.trim sort))

let board_sort_label = function
  | Board_dispatch.Hot -> "hot"
  | Board_dispatch.Trending -> "trending"
  | Board_dispatch.Recent -> "recent"
  | Board_dispatch.Updated -> "updated"
  | Board_dispatch.Discussed -> "discussed"

let is_system_board_author author =
  author = "lodge-system" || author = "team-session"

let filter_board_posts ~exclude_system posts =
  if not exclude_system then posts
  else
    List.filter
      (fun (p : Board.post) -> not (is_system_board_author (Board.Agent_id.to_string p.author)))
      posts

let max_filtered_board_window = 5200

let board_fetch_limit ~exclude_system ~limit ~offset =
  let base = limit + offset in
  if exclude_system then max base max_filtered_board_window else base

let board_title_of_content content =
  let trimmed = String.trim content in
  let without_flair =
    if String.length trimmed >= 7 && String.sub trimmed 0 7 = "[flair:" then
      match String.index_opt trimmed ']' with
      | Some idx when idx + 1 < String.length trimmed ->
          String.trim (String.sub trimmed (idx + 1) (String.length trimmed - idx - 1))
      | _ -> trimmed
    else
      trimmed
  in
  let first_line =
    match String.split_on_char '\n' without_flair with
    | line :: _ -> String.trim line
    | [] -> ""
  in
  let line = if first_line = "" then "Untitled post" else first_line in
  if String.length line <= 96 then line
  else String.sub line 0 93 ^ "..."

let board_post_dashboard_json ~author_karma (p : Board.post) : Yojson.Safe.t =
  let base_fields =
    match Board_dispatch.post_to_yojson_with_karma p ~author_karma with
    | `Assoc fields -> fields
    | _ -> []
  in
  let fields =
    base_fields
    |> List.remove_assoc "title"
    |> List.remove_assoc "votes"
    |> List.remove_assoc "comment_count"
    |> List.remove_assoc "created_at_iso"
    |> List.remove_assoc "updated_at_iso"
    |> List.remove_assoc "hearth_count"
  in
  let score = p.votes_up - p.votes_down in
  `Assoc
    ( fields
      @ [
          ("title", `String (board_title_of_content p.content));
          ("votes", `Int score);
          ("comment_count", `Int p.reply_count);
          ("created_at_iso", `String (iso8601_of_unix p.created_at));
          ("updated_at_iso", `String (iso8601_of_unix p.updated_at));
          ("hearth_count", `Int (match p.hearth with Some _ -> 1 | None -> 0));
        ] )

let dashboard_compact_mode request =
  match query_param request "mode" with
  | Some s -> String.equal "compact" (String.lowercase_ascii (String.trim s))
  | None -> false

let trpg_resolve_room_id ~config request =
  let fallback = Option.value ~default:"default" (Masc_mcp.Room.read_current_room config) in
  match query_param request "room_id" with
  | None -> fallback
  | Some raw -> (
      let room_id = String.trim raw in
      if room_id = "" then fallback else room_id)

type trpg_api_error_kind = [ `Bad_request | `Internal_server_error ]
type trpg_api_result = (Yojson.Safe.t, trpg_api_error_kind * string) result

let trpg_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]

let trpg_normalize_events_json
    ?(default_room_id = "")
    (json : Yojson.Safe.t) : Yojson.Safe.t =
  let normalize_room_id raw =
    let trimmed = String.trim raw in
    if trimmed = "" then default_room_id else trimmed
  in
  let int_of_json = function
    | `Int i -> Some i
    | `Intlit s -> (try Some (int_of_string s) with Failure _ -> None)
    | `Float f -> Some (int_of_float f)
    | `String s -> (
        let s = String.trim s in
        if s = "" then None else (try Some (int_of_string s) with Failure _ -> None))
    | _ -> None
  in
  let json_assoc_member key = function
    | `Assoc fields -> List.assoc_opt key fields
    | _ -> None
  in
  let event_seq idx ev =
    match Option.bind (json_assoc_member "seq" ev) int_of_json with
    | Some seq -> seq
    | None -> (
        match Option.bind (json_assoc_member "event_id" ev) int_of_json with
        | Some seq -> seq
        | None -> idx + 1)
  in
  let event_turn ev =
    let from_keys keys src =
      keys
      |> List.find_map (fun key -> Option.bind (json_assoc_member key src) int_of_json)
    in
    match from_keys [ "turn"; "turn_after"; "turn_before" ] ev with
    | Some turn -> turn
    | None -> (
        match json_assoc_member "payload" ev with
        | Some payload ->
            Option.value
              ~default:0
              (from_keys [ "turn"; "turn_after"; "turn_before" ] payload)
        | None -> 0)
  in
  let event_room_id ev =
    let direct =
      Option.bind
        (json_assoc_member "room_id" ev)
        (function
          | `String s -> Some s
          | _ -> None)
    in
    match direct with
    | Some room -> normalize_room_id room
    | None -> (
        match json_assoc_member "payload" ev with
        | Some payload -> (
            match json_assoc_member "room_id" payload with
            | Some (`String room) -> normalize_room_id room
            | _ -> default_room_id)
        | None -> default_room_id)
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "events" fields with
      | Some (`List events) ->
          let indexed =
            events
            |> List.mapi (fun idx ev ->
                   let room_id = event_room_id ev in
                   let turn = event_turn ev in
                   let seq = event_seq idx ev in
                   (room_id, turn, seq, idx, ev))
            |> List.sort (fun (room_a, turn_a, seq_a, idx_a, _) (room_b, turn_b, seq_b, idx_b, _) ->
                   let c_room = String.compare room_a room_b in
                   if c_room <> 0 then c_room
                   else
                     let c_turn = Int.compare turn_a turn_b in
                     if c_turn <> 0 then c_turn
                     else
                       let c_seq = Int.compare seq_a seq_b in
                       if c_seq <> 0 then c_seq else Int.compare idx_a idx_b)
          in
          let seen = Hashtbl.create (List.length indexed) in
          let deduped =
            indexed
            |> List.filter_map (fun (room_id, turn, seq, _idx, ev) ->
                   let key = Printf.sprintf "%s\x1f%d\x1f%d" room_id turn seq in
                   if Hashtbl.mem seen key then None
                   else (
                     Hashtbl.add seen key ();
                     Some ev))
          in
          let updated =
            ("events", `List deduped) :: List.remove_assoc "events" fields
          in
          let updated =
            if List.mem_assoc "count" fields then
              ("count", `Int (List.length deduped)) :: List.remove_assoc "count" updated
            else
              updated
          in
          `Assoc updated
      | _ -> json)
  | _ -> json

let trpg_rule_by_id (rule_id : string)
  : ((module Masc_mcp.Trpg_rule.S), trpg_api_error_kind * string) result =
  let normalized = String.trim rule_id |> String.lowercase_ascii in
  match normalized with
  | "" | "dnd5e-lite" -> Ok (module Masc_mcp.Trpg_rule_dnd5e_lite : Masc_mcp.Trpg_rule.S)
  | other -> Error (`Bad_request, Printf.sprintf "unsupported rule_module: %s" other)

let trpg_extract_config_from_events (events : Masc_mcp.Trpg_engine_event.t list)
  : Yojson.Safe.t =
  let rec find_room_created = function
    | [] -> `Assoc []
    | ev :: tl ->
        (match ev.Masc_mcp.Trpg_engine_event.event_type with
        | Masc_mcp.Trpg_engine_event.Room_created ->
            (match ev.payload with
            | `Assoc fields -> (
                match List.assoc_opt "config" fields with
                | Some cfg -> cfg
                | None -> ev.payload)
            | _ -> `Assoc [])
        | _ -> find_room_created tl)
  in
  find_room_created events

let trpg_parse_required_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s when String.trim s <> "" -> Ok (String.trim s)
  | `String _ -> Error (`Bad_request, Printf.sprintf "%s cannot be empty" key)
  | `Null -> Error (`Bad_request, Printf.sprintf "%s is required" key)
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be string" key)

let trpg_parse_optional_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let s = String.trim s in
      if s = "" then Ok None else Ok (Some s)
  | `Null -> Ok None
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be string" key)

let trpg_parse_optional_int key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Ok (Some i)
  | `Intlit s -> (
      try Ok (Some (int_of_string s))
      with _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key))
  | `Null -> Ok None
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key)

let trpg_parse_required_int key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Ok i
  | `Intlit s -> (
      try Ok (int_of_string s)
      with _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key))
  | `Null -> Error (`Bad_request, Printf.sprintf "%s is required" key)
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be int" key)

let trpg_parse_optional_bool key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Ok b
  | `Null -> Ok default
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be bool" key)

let trpg_parse_optional_string_list key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
      Ok (List.filter_map (function `String s -> Some s | _ -> None) items)
  | `Null -> Ok []
  | _ -> Error (`Bad_request, Printf.sprintf "%s must be array of strings" key)

let trpg_parse_optional_object key json =
  match Yojson.Safe.Util.member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | _ ->
      Error (`Bad_request, Printf.sprintf "%s must be object (객체여야 합니다)" key)

let trpg_validate_actor_role role =
  match role with
  | "dm" | "player" | "npc" -> Ok ()
  | other ->
      Error
        ( `Bad_request,
          Printf.sprintf "invalid role: %s (must be dm, player, or npc)" other
        )

let trpg_parse_event_type_filter event_type_filter =
  match event_type_filter with
  | None -> Ok None
  | Some raw -> (
      match Masc_mcp.Trpg_engine_event.event_type_of_string raw with
      | Ok et -> Ok (Some et)
      | Error _ ->
          Error (`Bad_request, Printf.sprintf "invalid event_type filter: %s" raw))

let trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter
  : (Masc_mcp.Trpg_engine_event.t list, trpg_api_error_kind * string) result =
  try
    let room_id = String.trim room_id in
    if room_id = "" then
      Error (`Bad_request, "room_id is required")
    else
      match trpg_parse_event_type_filter event_type_filter with
      | Error _ as e -> e
      | Ok event_type_opt ->
          let read_result =
            if after_seq > 0 then
              Masc_mcp.Trpg_engine_store_sqlite.read_events_after ~base_dir ~room_id ~after_seq
            else
              Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id
          in
          (match read_result with
          | Error e ->
              Printf.eprintf
                "[trpg] read_events failed room=%s after_seq=%d: %s; returning empty list\n%!"
                room_id after_seq e;
              Ok []
          | Ok events ->
              let events =
                match event_type_opt with
                | None -> events
                | Some et ->
                    List.filter
                      (fun (ev : Masc_mcp.Trpg_engine_event.t) -> ev.event_type = et)
                      events
              in
              Ok events)
  with exn ->
    Error
      ( `Internal_server_error,
        Printf.sprintf "trpg_read_events_list failed: %s"
          (Printexc.to_string exn) )

let trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter : trpg_api_result =
  let room_id = String.trim room_id in
  match trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as e -> e
  | Ok events ->
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("after_seq", `Int after_seq);
            ("count", `Int (List.length events));
            ("events", `List (List.map Masc_mcp.Trpg_engine_event.to_yojson events));
          ])

let trpg_next_seq ~base_dir ~room_id =
  match Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Ok events ->
      Ok
        (1
        + List.fold_left
            (fun acc (ev : Masc_mcp.Trpg_engine_event.t) -> max acc ev.seq)
            0 events)
  | Error e -> Error (`Internal_server_error, e)

let trpg_append_event
    ~base_dir ~room_id ~event_type ?actor_id ?ts ?seq ~payload () =
  let room_id = String.trim room_id in
  if room_id = "" then Error (`Bad_request, "room_id is required")
  else
    let seq_result =
      match seq with
      | Some s when s <= 0 -> Error (`Bad_request, "seq must be positive")
      | Some s -> Ok s
      | None -> trpg_next_seq ~base_dir ~room_id
    in
    match seq_result with
    | Error _ as e -> e
    | Ok seq ->
        let ts = Option.value ~default:(Masc_mcp.Types.now_iso ()) ts in
        let event =
          Masc_mcp.Trpg_engine_event.make
            ~seq ~room_id ~ts ~event_type ?actor_id ~payload ()
        in
        (match Masc_mcp.Trpg_engine_store_sqlite.append_event ~base_dir ~event with
        | Ok () -> Ok event
        | Error e -> Error (`Internal_server_error, e))

let trpg_append_event_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    match trpg_parse_required_string "room_id" json with
    | Error _ as e -> e
    | Ok room_id -> (
    match trpg_parse_required_string "event_type" json with
    | Error _ as e -> e
    | Ok event_type_str -> (
      match Masc_mcp.Trpg_engine_event.event_type_of_string event_type_str with
      | Error e -> Error (`Bad_request, e)
      | Ok event_type -> (
          match trpg_parse_optional_string "actor_id" json with
          | Error _ as e -> e
          | Ok actor_id -> (
              match trpg_parse_optional_string "ts" json with
              | Error _ as e -> e
              | Ok ts_opt -> (
                  match trpg_parse_optional_int "seq" json with
                  | Error _ as e -> e
                  | Ok seq_opt ->
                      let payload =
                        match Yojson.Safe.Util.member "payload" json with
                        | `Null -> `Assoc []
                        | v -> v
                      in
                      (match
                         trpg_append_event
                           ~base_dir
                           ~room_id
                           ~event_type
                           ?actor_id
                           ?ts:ts_opt
                           ?seq:seq_opt
                           ~payload
                           ()
                       with
                      | Error _ as e -> e
                      | Ok event ->
                          Ok
                            (`Assoc
                              [
                                ("ok", `Bool true);
                                ("event", Masc_mcp.Trpg_engine_event.to_yojson event);
                              ]))))))
      )
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_derive_state_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  try
    let room_id = String.trim room_id in
    if room_id = "" then
      Error (`Bad_request, "room_id is required")
    else
      match trpg_rule_by_id rule_module with
      | Error _ as e -> e
      | Ok rule ->
          let events, read_failed =
            match Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
            | Ok events -> (events, false)
            | Error e ->
                Printf.eprintf
                  "[trpg] derive_state read_events failed room=%s: %s; deriving from empty events\n%!"
                  room_id e;
                ([], true)
          in
          let config = trpg_extract_config_from_events events in
          let state =
            Masc_mcp.Trpg_engine_replay.derive_state ~rule ~config ~events
          in
          let module R = (val rule : Masc_mcp.Trpg_rule.S) in
          let warning_fields =
            if read_failed then
              [
                ( "warning",
                  `String
                    "event_store_unavailable: derived from empty event stream"
                );
              ]
            else []
          in
          Ok
            (`Assoc
              ([
                 ("ok", `Bool true);
                 ("room_id", `String room_id);
                 ("rule_module", `String R.id);
                 ("event_count", `Int (List.length events));
                 ("state", state);
               ]
              @ warning_fields))
  with exn ->
    Error
      ( `Internal_server_error,
        Printf.sprintf "trpg_derive_state_json failed: %s"
          (Printexc.to_string exn) )

let trpg_state_from_derived derived_json =
  try
    match Yojson.Safe.Util.member "state" derived_json with
    | `Null -> `Assoc []
    | v -> v
  with _ -> `Assoc []

let trpg_extract_state_int derived_json field ~default =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> i
    | _ -> default
  with _ -> default

let trpg_read_state_int derived_json field =
  try
    match Yojson.Safe.Util.member field (trpg_state_from_derived derived_json) with
    | `Int i -> Ok i
    | _ ->
        Error
          (`Internal_server_error, Printf.sprintf "state.%s must be int" field)
  with _ ->
    Error (`Internal_server_error, Printf.sprintf "state.%s missing" field)

(* ─── Actor state query helpers ─────────────────────────────── *)

type trpg_actor_spawn_cached = {
  fingerprint : string;
  response_json : Yojson.Safe.t;
  seq : int;
}

type trpg_actor_spawn_guard_state = {
  mutex : Mutex.t;
  room_mutexes : (string, Mutex.t) Hashtbl.t;
  idempotency_cache : (string, trpg_actor_spawn_cached) Hashtbl.t;
  mutable next_seq : int;
}

let trpg_actor_spawn_guard : trpg_actor_spawn_guard_state =
  {
    mutex = Mutex.create ();
    room_mutexes = Hashtbl.create 64;
    idempotency_cache = Hashtbl.create 2048;
    next_seq = 0;
  }

let trpg_with_actor_spawn_guard_lock f =
  Mutex.lock trpg_actor_spawn_guard.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock trpg_actor_spawn_guard.mutex) f

let trpg_with_actor_spawn_room_lock ~room_id f =
  let room_key = String.trim room_id in
  let room_key = if room_key = "" then "default" else room_key in
  let room_mutex =
    trpg_with_actor_spawn_guard_lock (fun () ->
        match Hashtbl.find_opt trpg_actor_spawn_guard.room_mutexes room_key with
        | Some m -> m
        | None ->
            let m = Mutex.create () in
            Hashtbl.replace trpg_actor_spawn_guard.room_mutexes room_key m;
            m)
  in
  Mutex.lock room_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock room_mutex) f

let trpg_actor_spawn_cache_key ~room_id ~idempotency_key =
  room_id ^ "\x1f" ^ idempotency_key

let trpg_actor_spawn_cache_lookup ~room_id ~idempotency_key =
  let key = trpg_actor_spawn_cache_key ~room_id ~idempotency_key in
  trpg_with_actor_spawn_guard_lock (fun () ->
      Hashtbl.find_opt trpg_actor_spawn_guard.idempotency_cache key)

let trpg_actor_spawn_cache_store ~room_id ~idempotency_key ~fingerprint
    ~response_json =
  let max_cache_entries = 4096 in
  let key = trpg_actor_spawn_cache_key ~room_id ~idempotency_key in
  trpg_with_actor_spawn_guard_lock (fun () ->
      trpg_actor_spawn_guard.next_seq <- trpg_actor_spawn_guard.next_seq + 1;
      Hashtbl.replace trpg_actor_spawn_guard.idempotency_cache key
        { fingerprint; response_json; seq = trpg_actor_spawn_guard.next_seq };
      while Hashtbl.length trpg_actor_spawn_guard.idempotency_cache
            > max_cache_entries
      do
        let oldest =
          Hashtbl.to_seq trpg_actor_spawn_guard.idempotency_cache
          |> Seq.fold_left
               (fun acc (k, v) ->
                 match acc with
                 | None -> Some (k, v.seq)
                 | Some (_old_key, old_seq) ->
                     if v.seq < old_seq then Some (k, v.seq) else acc)
               None
        in
        match oldest with
        | Some (old_key, _) ->
            Hashtbl.remove trpg_actor_spawn_guard.idempotency_cache old_key
        | None -> ()
      done)

let trpg_normalize_keeper_name s = s |> String.trim |> String.lowercase_ascii

let trpg_state_party_fields state =
  match Yojson.Safe.Util.member "party" state with
  | `Assoc fields -> fields
  | _ -> []

let trpg_actor_exists state actor_id =
  trpg_state_party_fields state |> List.mem_assoc actor_id

let trpg_sanitize_actor_id_seed (s : string) =
  let src = String.lowercase_ascii (String.trim s) in
  let out = Buffer.create (String.length src) in
  let prev_dash = ref true in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then (
        Buffer.add_char out c;
        prev_dash := false)
      else if not !prev_dash then (
        Buffer.add_char out '-';
        prev_dash := true))
    src;
  let collapsed = Buffer.contents out in
  let len = String.length collapsed in
  if len > 0 && collapsed.[len - 1] = '-' then
    let trimmed = String.sub collapsed 0 (len - 1) in
    if trimmed = "" then "actor" else trimmed
  else if collapsed = "" then "actor"
  else collapsed

let trpg_next_available_actor_id state base_actor_id =
  if not (trpg_actor_exists state base_actor_id) then base_actor_id
  else
    let rec loop n =
      let candidate = Printf.sprintf "%s-%d" base_actor_id n in
      if trpg_actor_exists state candidate then loop (n + 1) else candidate
    in
    loop 2

let trpg_actor_alive state actor_id =
  match trpg_state_party_fields state |> List.assoc_opt actor_id with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "alive" fields with
      | Some (`Bool b) -> b
      | _ -> true)
  | _ -> true

let trpg_state_actor_control_fields state =
  match Yojson.Safe.Util.member "actor_control" state with
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `String s when String.trim s <> "" -> Some (k, String.trim s)
          | _ -> None)
        fields
  | _ -> []

let rec trpg_canonicalize_json (value : Yojson.Safe.t) : Yojson.Safe.t =
  match value with
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.map (fun (k, v) -> (k, trpg_canonicalize_json v))
        |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map trpg_canonicalize_json items)
  | other -> other

let trpg_owner_for_actor state actor_id =
  trpg_state_actor_control_fields state |> List.assoc_opt actor_id

let trpg_actor_for_keeper state keeper =
  let norm = trpg_normalize_keeper_name keeper in
  trpg_state_actor_control_fields state
  |> List.find_opt (fun (_aid, kn) -> trpg_normalize_keeper_name kn = norm)
  |> Option.map fst

let trpg_actor_role state actor_id =
  match trpg_state_party_fields state |> List.assoc_opt actor_id with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "role" fields with
      | Some (`String role) when String.trim role <> "" ->
          String.lowercase_ascii (String.trim role)
      | _ -> "player")
  | _ -> "player"

let trpg_join_gate_phase_open state =
  match Yojson.Safe.Util.member "join_gate" state |> Yojson.Safe.Util.member "phase_open" with
  | `Bool b -> b
  | _ -> true

let trpg_join_gate_min_points state =
  match Yojson.Safe.Util.member "join_gate" state |> Yojson.Safe.Util.member "min_points" with
  | `Int n when n > 0 -> n
  | _ -> 3

let trpg_contribution_for_actor events actor_id =
  let score = ref 0 in
  let reasons = ref [] in
  let add delta reason =
    score := max (-10) (min 50 (!score + delta));
    reasons := !reasons @ [ reason ]
  in
  List.iter
    (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
      let payload = ev.payload in
      let event_actor_id =
        match payload |> Yojson.Safe.Util.member "actor_id" with
        | `String v when String.trim v <> "" -> Some (String.trim v)
        | _ -> ev.actor_id
      in
      match ev.event_type with
      | Masc_mcp.Trpg_engine_event.Turn_action_resolved ->
          if event_actor_id = Some actor_id then add 2 "turn.action.resolved +2"
      | Masc_mcp.Trpg_engine_event.Intervention_applied ->
          let target_actor =
            match payload |> Yojson.Safe.Util.member "target_actor" with
            | `String v when String.trim v <> "" -> Some (String.trim v)
            | _ -> event_actor_id
          in
          if target_actor = Some actor_id then
            add 1 "intervention.applied +1"
      | Masc_mcp.Trpg_engine_event.Dice_rolled ->
          if event_actor_id = Some actor_id then
            let passed =
              match payload |> Yojson.Safe.Util.member "passed" with
              | `Bool b -> b
              | _ -> false
            in
            if passed then add 1 "dice.rolled(pass) +1"
            else add (-1) "dice.rolled(fail) -1"
      | _ -> ())
    events;
  (!score, !reasons)

let trpg_dice_roll_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* _rule = trpg_rule_by_id rule_module in
    let* action = trpg_parse_required_string "action" json in
    let* stat_value = trpg_parse_required_int "stat_value" json in
    let* dc = trpg_parse_required_int "dc" json in
    let* raw_opt = trpg_parse_optional_int "raw_d20" json in
    let* raw_d20 =
      match raw_opt with
      | Some i ->
          if i < 1 || i > 20 then
            Error (`Bad_request, "raw_d20 must be between 1 and 20")
          else Ok i
      | None -> Ok (1 + Random.int 20)
    in
    let bonus = Masc_mcp.Trpg_rule_dnd5e_lite.stat_bonus stat_value in
    let total = raw_d20 + bonus in
    let classification =
      Masc_mcp.Trpg_rule_dnd5e_lite.classify_roll ~raw_d20 ~total
    in
    let payload =
      `Assoc
        [
          ("actor_id", `String actor_id);
          ("action", `String action);
          ("stat_value", `Int stat_value);
          ("dc", `Int dc);
          ("raw_d20", `Int raw_d20);
          ("bonus", `Int bonus);
          ("total", `Int total);
          ( "tier",
            `String
              (Masc_mcp.Trpg_rule_dnd5e_lite.roll_tier_to_string
                 classification.tier) );
          ("label", `String classification.label);
          ("passed", `Bool classification.passed);
        ]
    in
    let* event =
      trpg_append_event
        ~base_dir
        ~room_id
        ~event_type:Masc_mcp.Trpg_engine_event.Dice_rolled
        ~actor_id
        ~payload
        ()
    in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("event", Masc_mcp.Trpg_engine_event.to_yojson event);
          ( "roll",
            `Assoc
              [
                ("raw_d20", `Int raw_d20);
                ("bonus", `Int bonus);
                ("total", `Int total);
                ("dc", `Int dc);
                ("passed", `Bool classification.passed);
                ("label", `String classification.label);
              ] );
          ("state", trpg_state_from_derived derived);
        ])
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

(* ─── Actor REST wrappers ───────────────────────────────────── *)

let trpg_actor_spawn_extract_idempotency_key ~(header_key : string option)
    (json : Yojson.Safe.t) : string option =
  let normalize = function
    | None -> None
    | Some raw ->
        let trimmed = String.trim raw in
        if trimmed = "" then None else Some trimmed
  in
  match normalize header_key with
  | Some _ as key -> key
  | None -> (
      match Yojson.Safe.Util.member "idempotency_key" json with
      | `String raw -> normalize (Some raw)
      | _ -> None)

let trpg_actor_spawn_request_fingerprint ~room_id ~rule_module ~actor_id_opt
    ~name_opt ~role ~archetype ~persona ~portrait ~background ~stats_opt ~hp
    ~max_hp ~alive ~traits ~skills ~inventory =
  let fields =
    ref
      [
        ("room_id", `String room_id);
        ("rule_module", `String rule_module);
        ("role", `String role);
        ("hp", `Int hp);
        ("max_hp", `Int max_hp);
        ("alive", `Bool alive);
        ("traits", `List (List.map (fun s -> `String s) traits));
        ("skills", `List (List.map (fun s -> `String s) skills));
        ("inventory", `List (List.map (fun s -> `String s) inventory));
      ]
  in
  let add_opt_string key = function
    | Some value -> fields := (key, `String value) :: !fields
    | None -> ()
  in
  add_opt_string "actor_id" actor_id_opt;
  add_opt_string "name" name_opt;
  add_opt_string "archetype" archetype;
  add_opt_string "persona" persona;
  add_opt_string "portrait" portrait;
  add_opt_string "background" background;
  (match stats_opt with
  | Some stats -> fields := ("stats", trpg_canonicalize_json stats) :: !fields
  | None -> ());
  `Assoc !fields |> trpg_canonicalize_json |> Yojson.Safe.to_string

let trpg_actor_spawn_json ~base_dir ~(idempotency_key : string option) ~body_str
    : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id_raw = trpg_parse_required_string "room_id" json in
    let room_id = String.trim room_id_raw in
    let* () =
      if room_id = "" then
        Error (`Bad_request, "room_id is required")
      else Ok ()
    in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id_opt = trpg_parse_optional_string "actor_id" json in
    let* name_opt = trpg_parse_optional_string "name" json in
    let* role_opt = trpg_parse_optional_string "role" json in
    let role =
      role_opt |> Option.value ~default:"player" |> String.lowercase_ascii
    in
    let* () = trpg_validate_actor_role role in
    let* archetype = trpg_parse_optional_string "archetype" json in
    let* persona = trpg_parse_optional_string "persona" json in
    let* portrait = trpg_parse_optional_string "portrait" json in
    let* background = trpg_parse_optional_string "background" json in
    let* stats_opt = trpg_parse_optional_object "stats" json in
    let* hp_opt = trpg_parse_optional_int "hp" json in
    let* max_hp_opt = trpg_parse_optional_int "max_hp" json in
    let max_hp = Option.value ~default:10 max_hp_opt in
    let* () =
      if max_hp <= 0 then
        Error (`Bad_request, "max_hp must be > 0")
      else Ok ()
    in
    let hp = Option.value ~default:max_hp hp_opt in
    let* () =
      if hp < 0 then Error (`Bad_request, "hp must be >= 0") else Ok ()
    in
    let hp = min hp max_hp in
    let* alive = trpg_parse_optional_bool "alive" json ~default:true in
    let* traits = trpg_parse_optional_string_list "traits" json in
    let* skills = trpg_parse_optional_string_list "skills" json in
    let* inventory = trpg_parse_optional_string_list "inventory" json in
    let idempotency_key =
      trpg_actor_spawn_extract_idempotency_key ~header_key:idempotency_key json
    in
    let request_fingerprint =
      trpg_actor_spawn_request_fingerprint ~room_id ~rule_module ~actor_id_opt
        ~name_opt ~role ~archetype ~persona ~portrait ~background ~stats_opt ~hp
        ~max_hp ~alive ~traits ~skills ~inventory
    in
    trpg_with_actor_spawn_room_lock ~room_id (fun () ->
      let run_spawn_once () =
        let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
        let state = trpg_state_from_derived derived in
        let actor_id =
          match actor_id_opt with
          | Some explicit -> explicit
          | None ->
              let seed = name_opt |> Option.value ~default:role in
              let base_actor_id = trpg_sanitize_actor_id_seed seed in
              trpg_next_available_actor_id state base_actor_id
        in
        let name = Option.value ~default:actor_id name_opt in
        if trpg_actor_exists state actor_id then
          Error (`Bad_request, Printf.sprintf "actor '%s' already exists" actor_id)
        else
          let actor_fields = ref [] in
          let add_field key value = actor_fields := (key, value) :: !actor_fields in
          let add_opt_string key = function
            | Some value -> add_field key (`String value)
            | None -> ()
          in
          let add_opt_json key = function
            | Some value -> add_field key value
            | None -> ()
          in
          add_field "inventory" (`List (List.map (fun s -> `String s) inventory));
          add_field "skills" (`List (List.map (fun s -> `String s) skills));
          add_field "traits" (`List (List.map (fun s -> `String s) traits));
          add_field "alive" (`Bool alive);
          add_field "max_hp" (`Int max_hp);
          add_field "hp" (`Int hp);
          add_opt_json "stats" stats_opt;
          add_opt_string "background" background;
          add_opt_string "portrait" portrait;
          add_opt_string "persona" persona;
          add_opt_string "archetype" archetype;
          add_field "role" (`String role);
          add_field "name" (`String name);
          let actor_json = `Assoc (List.rev !actor_fields) in
          let payload_fields =
            [
              ("actor_id", `String actor_id);
              ("name", `String name);
              ("role", `String role);
              ("hp", `Int hp);
              ("max_hp", `Int max_hp);
              ("alive", `Bool alive);
              ("traits", `List (List.map (fun s -> `String s) traits));
              ("skills", `List (List.map (fun s -> `String s) skills));
              ("inventory", `List (List.map (fun s -> `String s) inventory));
              ("actor", actor_json);
            ]
          in
          let payload_fields =
            payload_fields
            @
            (match archetype with
            | Some v -> [ ("archetype", `String v) ]
            | None -> [])
            @
            (match persona with
            | Some v -> [ ("persona", `String v) ]
            | None -> [])
            @
            (match portrait with
            | Some v -> [ ("portrait", `String v) ]
            | None -> [])
            @
            (match background with
            | Some v -> [ ("background", `String v) ]
            | None -> [])
            @ (match stats_opt with Some stats -> [ ("stats", stats) ] | None -> [])
          in
          let payload = `Assoc payload_fields in
          let* _event =
            trpg_append_event ~base_dir ~room_id
              ~event_type:Masc_mcp.Trpg_engine_event.Actor_spawned ~actor_id
              ~payload ()
          in
          let* derived2 = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("actor_id", `String actor_id);
                ("state", trpg_state_from_derived derived2);
              ])
      in
      let run_and_maybe_store () =
        let result = run_spawn_once () in
        (match (result, idempotency_key) with
        | Ok response_json, Some key ->
            trpg_actor_spawn_cache_store ~room_id ~idempotency_key:key
              ~fingerprint:request_fingerprint ~response_json
        | _ -> ());
        result
      in
      match idempotency_key with
      | Some key -> (
          match trpg_actor_spawn_cache_lookup ~room_id ~idempotency_key:key with
          | Some cached when String.equal cached.fingerprint request_fingerprint ->
              Ok cached.response_json
          | Some _ ->
              Error
                ( `Bad_request,
                  "idempotency key reused with different payload: code=idempotency_payload_mismatch"
                )
          | None -> run_and_maybe_store ())
      | None -> run_spawn_once ())
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_actor_claim_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* keeper = trpg_parse_required_string "keeper" json in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let state = trpg_state_from_derived derived in
    let* events =
      match Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
      | Ok events -> Ok events
      | Error e ->
          Error
            ( `Internal_server_error,
              Printf.sprintf "failed to read events: %s" e )
    in
    if not (trpg_actor_exists state actor_id) then
      Error (`Bad_request, Printf.sprintf "actor '%s' does not exist" actor_id)
    else if not (trpg_actor_alive state actor_id) then
      Error (`Bad_request, Printf.sprintf "actor '%s' is not alive" actor_id)
    else
      let actor_role = trpg_actor_role state actor_id in
      let phase_name =
        match Yojson.Safe.Util.member "phase" state with
        | `String phase -> String.lowercase_ascii (String.trim phase)
        | _ -> "round"
      in
      let* () =
        if actor_role <> "player" then Ok ()
        else if phase_name <> "round" then
          (* Initial party assignment (lobby/briefing) bypasses contribution gate *)
          Ok ()
        else
          let phase_open = trpg_join_gate_phase_open state in
          let required = trpg_join_gate_min_points state in
          let score, _ = trpg_contribution_for_actor events actor_id in
          if not phase_open then
            Error (`Bad_request, "join gate failed: code=join_window_closed")
          else if score < required then
            Error
              ( `Bad_request,
                Printf.sprintf
                  "join gate failed: code=insufficient_contribution score=%d required=%d"
                  score required )
          else Ok ()
      in
      let norm_keeper = trpg_normalize_keeper_name keeper in
      (* Check current ownership *)
      match trpg_owner_for_actor state actor_id with
      | Some current_keeper
        when trpg_normalize_keeper_name current_keeper = norm_keeper ->
          (* Idempotent re-claim by same keeper *)
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("already_claimed", `Bool true);
                ("actor_id", `String actor_id);
                ("keeper", `String keeper);
              ])
      | Some other_keeper ->
          Error
            ( `Bad_request,
              Printf.sprintf "actor '%s' already claimed by '%s'" actor_id
                other_keeper )
      | None -> (
          (* Check keeper doesn't already control another actor *)
          match trpg_actor_for_keeper state keeper with
          | Some other_actor ->
              Error
                ( `Bad_request,
                  Printf.sprintf "keeper '%s' already controls actor '%s'" keeper
                    other_actor )
          | None ->
              let payload = `Assoc [ ("keeper", `String keeper) ] in
              let* _event =
                trpg_append_event ~base_dir ~room_id
                  ~event_type:Masc_mcp.Trpg_engine_event.Actor_claimed
                  ~actor_id ~payload ()
              in
              let* derived2 =
                trpg_derive_state_json ~base_dir ~room_id
                  ~rule_module
              in
              Ok
                (`Assoc
                  [
                    ("ok", `Bool true);
                    ("actor_id", `String actor_id);
                    ("keeper", `String keeper);
                    ("state", trpg_state_from_derived derived2);
                  ]))
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_actor_release_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* actor_id = trpg_parse_required_string "actor_id" json in
    let* keeper = trpg_parse_required_string "keeper" json in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let state = trpg_state_from_derived derived in
    match trpg_owner_for_actor state actor_id with
    | None ->
        Error (`Bad_request, Printf.sprintf "actor '%s' is not claimed" actor_id)
    | Some current_keeper ->
        let norm_keeper = trpg_normalize_keeper_name keeper in
        if trpg_normalize_keeper_name current_keeper <> norm_keeper then
          Error
            ( `Bad_request,
              Printf.sprintf "actor '%s' is claimed by '%s', not '%s'" actor_id
                current_keeper keeper )
        else
          let payload = `Assoc [ ("keeper", `String keeper) ] in
          let* _event =
            trpg_append_event ~base_dir ~room_id
              ~event_type:Masc_mcp.Trpg_engine_event.Actor_released
              ~actor_id ~payload ()
          in
          let* derived2 =
            trpg_derive_state_json ~base_dir ~room_id ~rule_module
          in
          Ok
            (`Assoc
              [
                ("ok", `Bool true);
                ("actor_id", `String actor_id);
                ("released_by", `String keeper);
                ("state", trpg_state_from_derived derived2);
              ])
  with Yojson.Json_error e ->
    Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_turn_advance_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* _rule = trpg_rule_by_id rule_module in
    let* phase_opt_raw = trpg_parse_optional_string "phase" json in
    let* phase_opt =
      match phase_opt_raw with
      | None -> Ok None
      | Some p -> (
          match Masc_mcp.Trpg_engine_types.phase_of_string p with
          | Ok phase ->
              Ok (Some (Masc_mcp.Trpg_engine_types.string_of_phase phase))
          | Error e -> Error (`Bad_request, e))
    in
    let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let* current_turn = trpg_read_state_int derived "turn" in
    let next_turn = max 1 (current_turn + 1) in
    let turn_payload = `Assoc [ ("turn", `Int next_turn) ] in
    let* turn_event =
      trpg_append_event
        ~base_dir
        ~room_id
        ~event_type:Masc_mcp.Trpg_engine_event.Turn_started
        ~payload:turn_payload
        ()
    in
    let* phase_event_opt =
      match phase_opt with
      | None -> Ok None
      | Some phase ->
          let payload = `Assoc [ ("phase", `String phase) ] in
          let* ev =
            trpg_append_event
              ~base_dir
              ~room_id
              ~event_type:Masc_mcp.Trpg_engine_event.Phase_changed
              ~payload
              ()
          in
          Ok (Some ev)
    in
    let* next_derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
    let events_json =
      [ Some turn_event; phase_event_opt ]
      |> List.filter_map (fun x -> x)
      |> List.map Masc_mcp.Trpg_engine_event.to_yojson
    in
    Ok
      (`Assoc
        [
          ("ok", `Bool true);
          ("room_id", `String room_id);
          ("turn", `Int next_turn);
          ("events", `List events_json);
          ("state", trpg_state_from_derived next_derived);
        ])
  with Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)

let trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter : trpg_api_result =
  match trpg_read_events_list ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as e -> e
  | Ok events ->
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("stream", `Bool true);
            ("room_id", `String (String.trim room_id));
            ("after_seq", `Int after_seq);
            ("count", `Int (List.length events));
            ("events", `List (List.map Masc_mcp.Trpg_engine_event.to_yojson events));
          ])

let split_csv_nonempty (raw : string) : string list =
  let pieces =
    raw
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 8 in
  let out_rev =
    List.fold_left
      (fun acc item ->
        if Hashtbl.mem seen item then acc
        else (
          Hashtbl.replace seen item true;
          item :: acc))
      []
      pieces
  in
  List.rev out_rev

let has_nonempty_env name =
  match Sys.getenv_opt name with
  | Some value -> String.trim value <> ""
  | None -> false

let trpg_default_fast_keeper_models () : string list =
  let glm_available = has_nonempty_env "ZAI_API_KEY" in
  let gemini_available = has_nonempty_env "GEMINI_API_KEY" in
  match (glm_available, gemini_available) with
  | true, true ->
      [ "glm:glm-4.7"; "gemini:gemini-2.5-flash"; "ollama:glm-4.7-flash" ]
  | true, false -> [ "glm:glm-4.7"; "ollama:glm-4.7-flash" ]
  | false, true -> [ "gemini:gemini-2.5-flash"; "ollama:glm-4.7-flash" ]
  | false, false -> [ "ollama:glm-4.7-flash" ]

let trpg_keeper_models_override_csv () : string option =
  match Sys.getenv_opt "MASC_TRPG_KEEPER_MODELS" with
  | Some raw -> Some raw
  | None -> Sys.getenv_opt "KEEPER_MODELS"

let trpg_keeper_models_for_round () : string list =
  let configured_opt =
    match trpg_keeper_models_override_csv () with
    | Some raw ->
        let parsed = split_csv_nonempty raw in
        if parsed = [] then None else Some parsed
    | None -> None
  in
  let chosen =
    match configured_opt with
    | Some models -> models
    | None -> trpg_default_fast_keeper_models ()
  in
  match Tool_keeper.model_specs_of_strings chosen with
  | Ok _ -> chosen
  | Error e ->
      if chosen <> [] then
        Printf.eprintf "[trpg] invalid keeper model override ignored: %s\n%!" e;
      []

let trim_trailing_slashes (raw : string) : string =
  let rec loop value =
    let len = String.length value in
    if len > 0 && value.[len - 1] = '/' then
      loop (String.sub value 0 (len - 1))
    else
      value
  in
  loop (String.trim raw)

let trpg_json_assoc_find (key : string) = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let trpg_json_string_fields (keys : string list) (json : Yojson.Safe.t) : string option =
  let rec pick = function
    | [] -> None
    | key :: rest -> (
        match trpg_json_assoc_find key json with
        | Some (`String value) ->
            let trimmed = String.trim value in
            if trimmed = "" then pick rest else Some trimmed
        | _ -> pick rest)
  in
  pick keys

let trpg_json_string_list_field (key : string) = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List rows) ->
          rows
          |> List.filter_map (function
               | `String value ->
                   let trimmed = String.trim value in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
      | _ -> [])
  | _ -> []

let trpg_http_get_json_via_curl ?(timeout_sec = 2) (url : string) :
    (Yojson.Safe.t, string) result =
  let argv = ["curl"; "-sS"; "--max-time"; string_of_int timeout_sec; url] in
  try
    let status, raw =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Float.of_int timeout_sec +. 1.0)
        argv
    in
    match status with
    | Unix.WEXITED 0 -> (
        if String.trim raw = "" then Error "empty response"
        else
          try Ok (Yojson.Safe.from_string raw)
          with Yojson.Json_error msg ->
            Error (Printf.sprintf "invalid json: %s" msg))
    | Unix.WEXITED 7 -> Error "connection refused"
    | Unix.WEXITED 28 -> Error "request timed out"
    | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
    | Unix.WSIGNALED sig_num ->
        Error (Printf.sprintf "curl killed by signal %d" sig_num)
    | Unix.WSTOPPED _ -> Error "curl stopped unexpectedly"
  with exn ->
    Error (Printf.sprintf "http error: %s" (Printexc.to_string exn))

let trpg_custom_endpoint_urls_from_specs (specs : string list) : string list =
  specs
  |> List.filter_map (fun spec ->
         let spec = String.trim spec in
         if not (String.starts_with ~prefix:"custom:" spec) then None
         else
           match String.index_opt spec '@' with
           | Some at_idx when at_idx + 1 < String.length spec ->
               let url =
                 String.sub spec (at_idx + 1) (String.length spec - at_idx - 1)
                 |> trim_trailing_slashes
               in
               if url = "" then None else Some url
           | _ -> None)
  |> String.concat ","
  |> split_csv_nonempty

let trpg_string_contains ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let trpg_parse_flag_value ~(flag : string) (command : string) : string option =
  let trimmed = String.trim command in
  let with_equals = flag ^ "=" in
  let len = String.length trimmed in
  let rec find_equals idx =
    if idx >= len then None
    else if
      idx + String.length with_equals <= len
      && String.sub trimmed idx (String.length with_equals) = with_equals
    then
      let start = idx + String.length with_equals in
      let rec stop j =
        if j >= len then j
        else
          match trimmed.[j] with
          | ' ' | '\t' | '\n' | '\r' -> j
          | _ -> stop (j + 1)
      in
      let value = String.sub trimmed start (stop start - start) |> String.trim in
      if value = "" then None else Some value
    else find_equals (idx + 1)
  in
  match find_equals 0 with
  | Some _ as value -> value
  | None ->
      let with_space = flag ^ " " in
      let rec find_space idx =
        if idx >= len then None
        else if
          idx + String.length with_space <= len
          && String.sub trimmed idx (String.length with_space) = with_space
        then
          let start = idx + String.length with_space in
          let rec skip_spaces j =
            if j < len && (trimmed.[j] = ' ' || trimmed.[j] = '\t') then
              skip_spaces (j + 1)
            else
              j
          in
          let start = skip_spaces start in
          let rec stop j =
            if j >= len then j
            else
              match trimmed.[j] with
              | ' ' | '\t' | '\n' | '\r' -> j
              | _ -> stop (j + 1)
          in
          let value = String.sub trimmed start (stop start - start) |> String.trim in
          if value = "" then None else Some value
        else find_space (idx + 1)
      in
      find_space 0

let trpg_running_llama_cpp_urls () : string list =
  try
    let status, raw =
      Process_eio.run_argv_with_status ~timeout_sec:2.5 ["ps"; "ax"; "-o"; "command="]
    in
    match status with
    | Unix.WEXITED 0 ->
        raw
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let trimmed = String.trim line in
               if trimmed = "" || not (trpg_string_contains ~needle:"llama-server" trimmed)
               then None
               else
                 match trpg_parse_flag_value ~flag:"--port" trimmed with
                 | Some port when String.for_all (function '0' .. '9' -> true | _ -> false) port
                   ->
                     Some (Printf.sprintf "http://127.0.0.1:%s" port)
                 | _ -> None
               )
        |> String.concat ","
        |> split_csv_nonempty
    | _ -> []
  with _ -> []

let trpg_openai_compatible_urls () : string list =
  let env_urls =
    match Sys.getenv_opt "MASC_TRPG_CUSTOM_MODEL_ENDPOINTS" with
    | Some raw -> split_csv_nonempty raw |> List.map trim_trailing_slashes
    | None -> []
  in
  let spec_urls =
    trpg_keeper_models_for_round () |> trpg_custom_endpoint_urls_from_specs
  in
  let llama_cpp_urls = trpg_running_llama_cpp_urls () in
  env_urls @ spec_urls @ llama_cpp_urls
  |> List.map trim_trailing_slashes
  |> String.concat ","
  |> split_csv_nonempty

let trpg_discover_openai_compatible_models (base_url : string) :
    (string list, string) result =
  let base_url = trim_trailing_slashes base_url in
  let url = base_url ^ "/v1/models" in
  match trpg_http_get_json_via_curl url with
  | Error err -> Error err
  | Ok json ->
      let named_rows =
        let gather key =
          match trpg_json_assoc_find key json with
          | Some (`List entries) ->
              entries
              |> List.filter_map (fun entry ->
                     trpg_json_string_fields ["id"; "name"; "model"] entry)
          | _ -> []
        in
        gather "data" @ gather "models"
      in
      let names = split_csv_nonempty (String.concat "," named_rows) in
      if names = [] then Error "model ids not found in /v1/models"
      else
        Ok
          (List.map
             (fun model_id -> Printf.sprintf "custom:%s@%s" model_id base_url)
             names)

let trpg_discover_ollama_models () : (string list, string) result =
  let base_url = trim_trailing_slashes Llm_client.ollama_glm.api_url in
  let url = base_url ^ "/api/tags" in
  match trpg_http_get_json_via_curl url with
  | Error err -> Error err
  | Ok json -> (
      match trpg_json_assoc_find "models" json with
      | Some (`List entries) ->
          let names =
            entries
            |> List.filter_map (fun entry ->
                   trpg_json_string_fields ["name"; "model"] entry)
            |> List.map (fun model_id -> Printf.sprintf "ollama:%s" model_id)
            |> String.concat ","
            |> split_csv_nonempty
          in
          if names = [] then Error "no ollama models found"
          else Ok names
      | _ -> Error "ollama tag list missing models array")

let trpg_available_models_json_collect
    ?(warnings : string list = [])
    ?(include_live = true)
    () : Yojson.Safe.t =
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 64 in
  let models_rev = ref [] in
  let warnings_rev = ref [] in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_model ~spec ~source ~status ?detail () =
    let spec = String.trim spec in
    if spec = "" || Hashtbl.mem seen spec then ()
    else (
      Hashtbl.replace seen spec true;
      let fields =
        [
          ("spec", `String spec);
          ("source", `String source);
          ("status", `String status);
        ]
      in
      let fields =
        match detail with
        | Some detail when String.trim detail <> "" ->
            ("detail", `String (String.trim detail)) :: fields
        | _ -> fields
      in
      models_rev := `Assoc (List.rev fields) :: !models_rev)
  in
  let configured_override =
    match trpg_keeper_models_override_csv () with
    | Some raw -> split_csv_nonempty raw
    | None -> []
  in
  let default_models = trpg_default_fast_keeper_models () in
  let effective_models = trpg_keeper_models_for_round () in
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-default" ~status:"default" ())
    default_models;
  List.iter
    (fun spec -> add_model ~spec ~source:"env-override" ~status:"override" ())
    configured_override;
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-effective" ~status:"selected" ())
    effective_models;
  List.iter add_warning warnings;
  if include_live then (
    List.iter
      (fun base_url ->
        match trpg_discover_openai_compatible_models base_url with
        | Ok specs ->
            List.iter
              (fun spec ->
                add_model ~spec ~source:"openai-compatible" ~status:"live"
                  ~detail:base_url ())
              specs
        | Error err ->
            add_warning
              (Printf.sprintf "openai-compatible %s 조회 실패: %s" base_url err))
      (trpg_openai_compatible_urls ());
    match trpg_discover_ollama_models () with
    | Ok specs ->
        List.iter
          (fun spec ->
            add_model ~spec ~source:"ollama" ~status:"live"
              ~detail:Llm_client.ollama_glm.api_url ())
          specs
    | Error err ->
        add_warning
          (Printf.sprintf "ollama %s 조회 실패: %s" Llm_client.ollama_glm.api_url err));
  `Assoc
    [
      ("ok", `Bool true);
      ( "effective_models",
        `List (List.map (fun spec -> `String spec) effective_models) );
      ( "configured_override",
        `List (List.map (fun spec -> `String spec) configured_override) );
      ("models", `List (List.rev !models_rev));
      ("warnings", `List (List.rev_map (fun item -> `String item) !warnings_rev));
    ]

let trpg_available_models_json_uncached () : Yojson.Safe.t =
  trpg_available_models_json_collect ()

let trpg_available_models_json_base ?(warnings : string list = []) () : Yojson.Safe.t =
  trpg_available_models_json_collect ~warnings ~include_live:false ()

type trpg_model_catalog_cache = {
  mutex : Mutex.t;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
}

let trpg_model_catalog_cache_ttl_sec = 15.0

let trpg_model_catalog_cache : trpg_model_catalog_cache =
  {
    mutex = Mutex.create ();
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
  }

let trpg_available_models_json () : Yojson.Safe.t =
  let now = Unix.gettimeofday () in
  let cached, should_refresh =
    Mutex.lock trpg_model_catalog_cache.mutex;
    let snapshot = trpg_model_catalog_cache.cached_json in
    let fresh_snapshot =
      match trpg_model_catalog_cache.cached_json with
      | Some json
        when now -. trpg_model_catalog_cache.cached_at
             < trpg_model_catalog_cache_ttl_sec ->
          Some json
      | _ -> None
    in
    let should_refresh =
      match fresh_snapshot with
      | Some _ -> false
      | None when trpg_model_catalog_cache.refresh_in_flight -> false
      | None ->
          trpg_model_catalog_cache.refresh_in_flight <- true;
          true
    in
    Mutex.unlock trpg_model_catalog_cache.mutex;
    ((match fresh_snapshot with Some json -> Some json | None -> snapshot), should_refresh)
  in
  match (cached, should_refresh) with
  | Some json, false -> json
  | None, false ->
      trpg_available_models_json_base
        ~warnings:["가용 모델 조회 중입니다. 잠시 후 다시 시도하세요."] ()
  | cached_snapshot, true ->
      let fallback_json =
        Fun.protect
          ~finally:(fun () ->
            Mutex.lock trpg_model_catalog_cache.mutex;
            trpg_model_catalog_cache.refresh_in_flight <- false;
            Mutex.unlock trpg_model_catalog_cache.mutex)
          (fun () ->
            let outcome =
              try Ok (trpg_available_models_json_uncached ())
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn)
            in
            match outcome with
            | Ok fresh -> fresh
            | Error err -> (
                match cached_snapshot with
                | Some stale ->
                    stale
                | None ->
                    trpg_available_models_json_base
                      ~warnings:[Printf.sprintf "가용 모델 조회 실패: %s" err] ()))
      in
      Mutex.lock trpg_model_catalog_cache.mutex;
      trpg_model_catalog_cache.cached_json <- Some fallback_json;
      trpg_model_catalog_cache.cached_at <- Unix.gettimeofday ();
      Mutex.unlock trpg_model_catalog_cache.mutex;
      fallback_json

let trpg_json_string_opt_field (json : Yojson.Safe.t) (key : string) : string option =
  match Yojson.Safe.Util.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let trpg_json_int_field (json : Yojson.Safe.t) (key : string) ~(default : int) : int =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | _ -> default

let trpg_json_bool_field (json : Yojson.Safe.t) (key : string) ~(default : bool) : bool =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let trpg_take_right n lst =
  lst |> List.rev |> take n |> List.rev

let trpg_recent_events ~base_dir ~room_id ~limit =
  match Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
  | Ok events -> trpg_take_right limit events
  | Error _ -> []

let trpg_party_member_rows (state : Yojson.Safe.t) =
  trpg_state_party_fields state
  |> List.map (fun (actor_id, row) ->
         match row with
         | `Assoc _ ->
             let name =
               trpg_json_string_opt_field row "name" |> Option.value ~default:actor_id
             in
             let role =
               trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
             in
             let alive = trpg_json_bool_field row "alive" ~default:true in
             let hp = trpg_json_int_field row "hp" ~default:0 in
             let max_hp = trpg_json_int_field row "max_hp" ~default:hp in
             let keeper =
               trpg_owner_for_actor state actor_id |> Option.value ~default:""
             in
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String name);
                 ("role", `String role);
                 ("alive", `Bool alive);
                 ("hp", `Int hp);
                 ("max_hp", `Int max_hp);
                 ("keeper", `String keeper);
                 ("claimed", `Bool (String.trim keeper <> ""));
               ]
         | _ ->
             `Assoc
               [
                 ("actor_id", `String actor_id);
                 ("name", `String actor_id);
                 ("role", `String "player");
                 ("alive", `Bool true);
                 ("hp", `Int 0);
                 ("max_hp", `Int 0);
                 ("keeper", `String "");
                 ("claimed", `Bool false);
               ])

let trpg_actor_control_rows (state : Yojson.Safe.t) =
  trpg_party_member_rows state
  |> List.filter_map (fun row ->
         let role = trpg_json_string_opt_field row "role" |> Option.value ~default:"player" in
         let claimed = trpg_json_bool_field row "claimed" ~default:false in
         if String.equal role "dm" || claimed then Some row else None)

let trpg_keeper_summary_rows (config : Room.config) =
  let dir = Tool_keeper.keeper_dir config in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.map Filename.remove_extension
    |> List.filter Tool_keeper.validate_name
    |> List.sort String.compare
    |> List.filter_map (fun name ->
           match Tool_keeper.read_meta config name with
           | Error _ -> None
           | Ok None -> None
           | Ok (Some (m : Tool_keeper.keeper_meta)) ->
               let agent = Tool_keeper.parse_agent_status config ~agent_name:m.agent_name in
               let agent_exists = trpg_json_bool_field agent "exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field agent "status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field agent "is_zombie" ~default:false in
               let keepalive_running = Hashtbl.mem Tool_keeper.keepalives m.name in
               Some
                 (`Assoc
                   [
                     ("name", `String m.name);
                     ("agent_name", `String m.agent_name);
                     ("models", `List (List.map (fun item -> `String item) m.models));
                     ("goal", `String m.goal);
                     ("agent_exists", `Bool agent_exists);
                     ("agent_status", `String agent_status);
                     ("is_zombie", `Bool is_zombie);
                     ("keepalive_running", `Bool keepalive_running);
                   ]))

let trpg_lobby_catalog_json ~base_dir ~(config : Room.config) ~room_id ~rule_module :
    trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let preset_catalog =
    match Masc_mcp.Trpg_preset_store.load_catalog ~base_dir with
    | Ok catalog -> catalog
    | Error _ -> Masc_mcp.Trpg_preset_store.default_catalog
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let current_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let current_phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let current_turn = trpg_json_int_field state "turn" ~default:0 in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("rule_module", `String rule_module);
        ("keepers", `List (List.map (fun name -> `String name) keeper_names));
        ("keeper_rows", `List keepers);
        ( "world_presets",
          `List
            (List.map Masc_mcp.Trpg_preset_store.world_preset_to_yojson
               preset_catalog.world_presets) );
        ( "dm_presets",
          `List
            (List.map Masc_mcp.Trpg_preset_store.dm_preset_to_yojson
               preset_catalog.dm_presets) );
        ("model_catalog", trpg_available_models_json ());
        ("occupancy", `List (trpg_actor_control_rows state));
        ( "current_room",
          `Assoc
            [
              ("status", `String current_status);
              ("phase", `String current_phase);
              ("turn", `Int current_turn);
            ] );
      ])

let trpg_preflight_row ~id ~label ~ok ?hint detail =
  let status = if ok then "ok" else "fail" in
  let fields =
    [
      ("id", `String id);
      ("label", `String label);
      ("ok", `Bool ok);
      ("status", `String status);
      ("detail", `String detail);
    ]
  in
  match hint with
  | Some value when String.trim value <> "" ->
      `Assoc (fields @ [("hint", `String (String.trim value))])
  | _ -> `Assoc fields

let trpg_lobby_preflight_json ~base_dir ~(config : Room.config) ~room_id ~rule_module
    ~(dm_keeper : string option) ~(player_keepers : string list) ~(models : string list) :
    trpg_api_result =
  let selected_dm = Option.value ~default:"" dm_keeper |> String.trim in
  let players = player_keepers |> List.map String.trim |> List.filter (( <> ) "") in
  let selected_keepers =
    split_csv_nonempty (String.concat "," (selected_dm :: players))
  in
  let keepers = trpg_keeper_summary_rows config in
  let keeper_names =
    keepers
    |> List.filter_map (fun row -> trpg_json_string_opt_field row "name")
  in
  let keeper_lookup : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun row ->
      match trpg_json_string_opt_field row "name" with
      | Some name -> Hashtbl.replace keeper_lookup name row
      | None -> ())
    keepers;
  let preset_catalog_result = Masc_mcp.Trpg_preset_store.load_catalog ~base_dir in
  let preset_ok = Result.is_ok preset_catalog_result in
  let derived =
    match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
    | Ok json -> Some json
    | Error _ -> None
  in
  let state = derived |> Option.map trpg_state_from_derived |> Option.value ~default:(`Assoc []) in
  let room_status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let blocking_rev = ref [] in
  let warnings_rev = ref [] in
  let actions_rev = ref [] in
  let add_blocking message =
    let trimmed = String.trim message in
    if trimmed <> "" then blocking_rev := trimmed :: !blocking_rev
  in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_action message =
    let trimmed = String.trim message in
    if trimmed <> "" then actions_rev := trimmed :: !actions_rev
  in
  let selection_ok =
    selected_dm <> "" && players <> [] && not (List.mem selected_dm players)
  in
  if selected_dm = "" then add_blocking "DM keeper를 선택하세요.";
  if players = [] then add_blocking "플레이어 keeper를 1명 이상 선택하세요.";
  if List.mem selected_dm players then
    add_blocking "DM keeper와 플레이어 keeper를 중복 선택할 수 없습니다.";
  if models = [] then add_blocking "AI 모델을 하나 이상 입력하세요.";
  let missing_keepers =
    selected_keepers
    |> List.filter (fun name -> not (List.mem name keeper_names))
  in
  if missing_keepers <> [] then
    add_blocking
      (Printf.sprintf "keeper pool 없음: %s"
         (String.concat ", " missing_keepers));
  let boot_required =
    selected_keepers
    |> List.filter_map (fun name ->
           match Hashtbl.find_opt keeper_lookup name with
           | None -> None
           | Some row ->
               let agent_exists = trpg_json_bool_field row "agent_exists" ~default:false in
               let agent_status =
                 trpg_json_string_opt_field row "agent_status"
                 |> Option.value ~default:"unknown"
               in
               let is_zombie = trpg_json_bool_field row "is_zombie" ~default:false in
               let keepalive_running =
                 trpg_json_bool_field row "keepalive_running" ~default:false
               in
               if (not agent_exists) || is_zombie then Some (Printf.sprintf "%s: boot 필요" name)
               else if not (List.mem agent_status [ "active"; "busy"; "listening" ]) then
                 Some (Printf.sprintf "%s: status=%s" name agent_status)
               else if not keepalive_running then
                 Some (Printf.sprintf "%s: keepalive off" name)
               else None)
  in
  if boot_required <> [] then
    add_warning
      (Printf.sprintf "선택 keeper 준비 필요: %s"
         (String.concat ", " boot_required));
  let occupied =
    trpg_actor_control_rows state
    |> List.filter_map (fun row ->
           let keeper = trpg_json_string_opt_field row "keeper" |> Option.value ~default:"" in
           let actor_id =
             trpg_json_string_opt_field row "actor_id" |> Option.value ~default:""
           in
           if List.mem keeper selected_keepers then
             Some (Printf.sprintf "%s→%s" keeper actor_id)
           else None)
  in
  if occupied <> [] then (
    add_blocking
      (Printf.sprintf "이미 점유 중: %s" (String.concat ", " occupied));
    add_action "새 room id로 바꾸거나 기존 actor 점유를 해제하세요.");
  if not preset_ok then add_blocking "프리셋 catalog를 불러오지 못했습니다.";
  if not selection_ok then add_action "Lobby에서 DM 1명과 플레이어를 다시 선택하세요.";
  if models = [] then add_action "Lobby에서 AI 모델을 입력하거나 칩에서 선택하세요.";
  if room_status = "ended" then
    add_warning "현재 room은 종료 상태입니다. 새 room id 사용을 권장합니다.";
  let checks =
    [
      trpg_preflight_row ~id:"server" ~label:"서버 연결" ~ok:true "MASC 서버 응답 정상";
      trpg_preflight_row ~id:"presets" ~label:"프리셋" ~ok:preset_ok
        (if preset_ok then "월드/DM 프리셋 로드 가능" else "프리셋 catalog를 불러오지 못했습니다.");
      trpg_preflight_row ~id:"keeper-pool" ~label:"키퍼 풀"
        ~ok:(keeper_names <> [])
        (Printf.sprintf "%d명 사용 가능" (List.length keeper_names));
      trpg_preflight_row ~id:"selection" ~label:"선택 키퍼"
        ~ok:(selected_keepers <> [] && missing_keepers = [] && selection_ok)
        (if selected_keepers = [] then "DM/플레이어 keeper를 선택하세요."
         else
           Printf.sprintf "DM %s · 플레이어 %d명"
             (if selected_dm = "" then "-" else selected_dm)
             (List.length players));
      trpg_preflight_row ~id:"models" ~label:"AI 모델" ~ok:(models <> [])
        (if models = [] then "입력된 모델이 없습니다."
         else Printf.sprintf "%d개 선택" (List.length models));
      trpg_preflight_row ~id:"occupancy" ~label:"점유 충돌" ~ok:(occupied = [])
        (if occupied = [] then "선택 keeper 모두 비점유"
         else Printf.sprintf "충돌 %s" (String.concat ", " occupied));
      trpg_preflight_row ~id:"room" ~label:"룸 상태" ~ok:true
        (Printf.sprintf "room %s · %s" room_id room_status);
    ]
  in
  let dedupe_list items = String.concat "," items |> split_csv_nonempty in
  let blocking = List.rev !blocking_rev |> dedupe_list in
  let warnings = List.rev !warnings_rev |> dedupe_list in
  let recommended_actions = List.rev !actions_rev |> dedupe_list in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ("ready", `Bool (blocking = []));
        ("checks", `List checks);
        ("blocking", `List (List.map (fun item -> `String item) blocking));
        ("warnings", `List (List.map (fun item -> `String item) warnings));
        ( "recommended_actions",
          `List (List.map (fun item -> `String item) recommended_actions) );
      ])

let trpg_build_alarm ~level ~code ~message =
  `Assoc
    [
      ("level", `String level);
      ("code", `String code);
      ("message", `String message);
    ]

let trpg_overview_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let recent_events = trpg_recent_events ~base_dir ~room_id ~limit:12 in
  let party = trpg_party_member_rows state in
  let players =
    party
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let player_count = List.length players in
  let alive_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "alive" ~default:true)
    |> List.length
  in
  let claimed_players =
    players |> List.filter (fun row -> trpg_json_bool_field row "claimed" ~default:false)
    |> List.length
  in
  let unclaimed_players = max 0 (player_count - claimed_players) in
  let active_keepers =
    trpg_state_actor_control_fields state
    |> List.map snd |> String.concat "," |> split_csv_nonempty |> List.length
  in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let scenario =
    trpg_json_string_fields [ "current_scenario"; "scenario"; "world" ] state
    |> Option.value ~default:""
  in
  let node =
    trpg_json_string_fields
      [ "current_node"; "node"; "current_area"; "area"; "scene" ]
      state
    |> Option.value ~default:""
  in
  let alarms_rev = ref [] in
  let add_alarm level code message =
    alarms_rev := trpg_build_alarm ~level ~code ~message :: !alarms_rev
  in
  if status = "unavailable" then
    add_alarm "error" "room_unavailable" "TRPG 엔진 상태를 읽지 못했습니다.";
  if status = "ended" then
    add_alarm "warn" "room_ended" "이 room은 종료 상태입니다.";
  if unclaimed_players > 0 && status <> "lobby" then
    add_alarm "warn" "unclaimed_players"
      (Printf.sprintf "player actor %d명이 아직 keeper와 연결되지 않았습니다."
         unclaimed_players);
  List.iter
    (fun ev ->
      match ev.Masc_mcp.Trpg_engine_event.event_type with
      | Masc_mcp.Trpg_engine_event.Turn_timeout ->
          add_alarm "warn" "turn_timeout" "최근 턴 timeout 이벤트가 기록되었습니다."
      | Masc_mcp.Trpg_engine_event.Keeper_unavailable ->
          add_alarm "warn" "keeper_unavailable" "최근 keeper unavailable 이벤트가 기록되었습니다."
      | _ -> ())
    recent_events;
  let next_actions =
    let items = ref [] in
    let add item =
      let trimmed = String.trim item in
      if trimmed <> "" then items := trimmed :: !items
    in
    if status = "lobby" then add "Lobby에서 세션을 시작하세요.";
    if unclaimed_players > 0 then add "Control에서 actor 점유 상태를 확인하세요.";
    if status = "stopped" then add "세션 재개 또는 라운드 실행 여부를 결정하세요.";
    if !items = [] then add "Timeline에서 최근 이벤트를 확인하세요.";
    String.concat "," (List.rev !items) |> split_csv_nonempty
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ("scenario", `String scenario);
              ("node", `String node);
              ("player_count", `Int player_count);
              ("alive_players", `Int alive_players);
              ("claimed_players", `Int claimed_players);
              ("unclaimed_players", `Int unclaimed_players);
              ("active_keepers", `Int active_keepers);
            ] );
        ("alarms", `List (List.rev !alarms_rev));
        ( "next_actions",
          `List (List.map (fun item -> `String item) next_actions) );
        ("party", `List party);
        ( "recent_events",
          `List
            (List.map Masc_mcp.Trpg_engine_event.to_yojson recent_events) );
      ])

let trpg_control_state_json ~base_dir ~room_id ~rule_module : trpg_api_result =
  let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
  let* derived = trpg_derive_state_json ~base_dir ~room_id ~rule_module in
  let state = trpg_state_from_derived derived in
  let status =
    trpg_json_string_opt_field state "status" |> Option.value ~default:"lobby"
  in
  let phase =
    trpg_json_string_opt_field state "phase"
    |> Option.value ~default:"dm_narration"
  in
  let actor_control = trpg_actor_control_rows state in
  let player_rows =
    trpg_party_member_rows state
    |> List.filter (fun row ->
           trpg_json_string_opt_field row "role" |> Option.value ~default:"player"
           |> String.lowercase_ascii = "player")
  in
  let unclaimed_players =
    player_rows
    |> List.filter (fun row -> not (trpg_json_bool_field row "claimed" ~default:false))
  in
  let recent_interventions =
    trpg_recent_events ~base_dir ~room_id ~limit:20
    |> List.filter (fun ev ->
           match ev.Masc_mcp.Trpg_engine_event.event_type with
           | Masc_mcp.Trpg_engine_event.Intervention_submitted
           | Masc_mcp.Trpg_engine_event.Intervention_applied -> true
           | _ -> false)
  in
  let allowed_actions =
    [
      `Assoc
        [
          ("id", `String "run-round");
          ("label", `String "라운드 실행");
          ("enabled", `Bool (status <> "ended" && status <> "unavailable"));
          ( "reason",
            `String
              (if status = "ended" then "종료된 세션입니다."
               else if status = "unavailable" then "엔진 상태를 읽지 못했습니다."
               else "라운드 실행 가능") );
        ];
      `Assoc
        [
          ("id", `String "pause-session");
          ("label", `String "세션 멈춤");
          ("enabled", `Bool (status = "running"));
          ( "reason",
            `String (if status = "running" then "진행 중 세션입니다." else "running 상태에서만 사용") );
        ];
      `Assoc
        [
          ("id", `String "resume-session");
          ("label", `String "세션 재개");
          ("enabled", `Bool (status = "stopped"));
          ( "reason",
            `String (if status = "stopped" then "중단된 세션입니다." else "stopped 상태에서만 사용") );
        ];
    ]
  in
  let warnings =
    [
      (if unclaimed_players = [] then None
       else
         Some
           (Printf.sprintf "미점유 player actor %d명"
              (List.length unclaimed_players)));
      (if recent_interventions = [] then None
       else Some "최근 intervention 이벤트가 있습니다.");
    ]
    |> List.filter_map (fun item -> item)
  in
  Ok
    (`Assoc
      [
        ("ok", `Bool true);
        ("room_id", `String room_id);
        ( "summary",
          `Assoc
            [
              ("status", `String status);
              ("turn", `Int (trpg_json_int_field state "turn" ~default:0));
              ("phase", `String phase);
              ( "join_window_open",
                `Bool (trpg_join_gate_phase_open state) );
              ("join_gate_min_points", `Int (trpg_join_gate_min_points state));
            ] );
        ("actor_control", `List actor_control);
        ("unclaimed_players", `List unclaimed_players);
        ( "recent_interventions",
          `List
            (List.map Masc_mcp.Trpg_engine_event.to_yojson recent_interventions) );
        ("allowed_actions", `List allowed_actions);
        ("warnings", `List (List.map (fun item -> `String item) warnings));
      ])

let trpg_event_phase_matches (phase_filter : string option)
    (event : Masc_mcp.Trpg_engine_event.t) =
  match phase_filter with
  | None -> true
  | Some phase_filter ->
      let normalized = String.lowercase_ascii (String.trim phase_filter) in
      if normalized = "" then true
      else
        match
          trpg_json_string_fields
            [ "phase"; "phase_name"; "phase_after"; "phase_before" ]
            event.payload
        with
        | Some phase ->
            String.equal (String.lowercase_ascii (String.trim phase)) normalized
        | None -> false

let trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter ~actor_filter
    ~phase_filter ~limit : trpg_api_result =
  match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
  | Error _ as err -> err
  | Ok raw ->
      let normalized = trpg_normalize_events_json ~default_room_id:room_id raw in
      let events =
        match trpg_json_assoc_find "events" normalized with
        | Some (`List entries) ->
            entries
            |> List.filter_map (fun item ->
                   match Masc_mcp.Trpg_engine_event.of_yojson item with
                   | Ok event -> Some event
                   | Error _ -> None)
            |> List.filter (fun (event : Masc_mcp.Trpg_engine_event.t) ->
                   let actor_ok =
                     match actor_filter with
                     | Some actor when String.trim actor <> "" -> (
                         match event.actor_id with
                         | Some actor_id -> String.equal actor_id (String.trim actor)
                         | None -> false)
                     | _ -> true
                   in
                   actor_ok && trpg_event_phase_matches phase_filter event)
            |> take limit
        | _ -> []
      in
      let last_seq =
        events
        |> List.rev
        |> List.find_map (fun event -> Some event.Masc_mcp.Trpg_engine_event.seq)
        |> Option.value ~default:after_seq
      in
      Ok
        (`Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ( "filters",
              `Assoc
                [
                  ("after_seq", `Int after_seq);
                  ( "event_type",
                    match event_type_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "actor",
                    match actor_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ( "phase",
                    match phase_filter with
                    | Some value -> `String value
                    | None -> `Null );
                  ("limit", `Int limit);
                ] );
            ("count", `Int (List.length events));
            ("last_seq", `Int last_seq);
            ( "events",
              `List (List.map Masc_mcp.Trpg_engine_event.to_yojson events) );
          ])

let trpg_keeper_call_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
    ~message
    ~timeout_sec
  : Masc_mcp.Tool_trpg.keeper_call_result =
  let keeper_ctx : _ Masc_mcp.Tool_keeper.context = { config; sw; clock } in
  let forced_models = trpg_keeper_models_for_round () in
  let forced_models_field =
    if forced_models = [] then []
    else [ ("models", `List (List.map (fun m -> `String m) forced_models)) ]
  in
  let inline_goal =
    Printf.sprintf
      "TRPG runtime keeper for %s. You are an in-world keeper of this setting; avoid out-of-world meta narration, stay in character, keep continuity, answer concisely, and never output SKILL/STATE tags, prompt recalls, or raw visible_state_json."
      keeper_name
  in
  let turn_instructions =
    Masc_mcp.Tool_trpg.trpg_structured_action_system_instructions
  in
  let keeper_args =
    `Assoc
      (forced_models_field
      @ [
          ("name", `String keeper_name);
          ("message", `String message);
          ("goal", `String inline_goal);
          ("require_existing", `Bool true);
          ("timeout_sec", `Float timeout_sec);
          ("ollama_timeout_sec", `Float timeout_sec);
          ("turn_instructions", `String turn_instructions);
        ])
  in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      match
        Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:keeper_args
      with
      | None -> `Error "masc_keeper_msg dispatch unavailable"
      | Some (true, body) -> (
          try `Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            `Error (Printf.sprintf "keeper returned invalid json: %s" e))
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Timeout
  | exn -> `Error (Printexc.to_string exn)

type trpg_round_run_guard_state = {
  mutex : Mutex.t;
  inflight_rooms : (string, unit) Hashtbl.t;
  idempotency_cache : (string, Yojson.Safe.t) Hashtbl.t;
  mutable cache_writes : int;
}

let trpg_round_run_guard : trpg_round_run_guard_state =
  {
    mutex = Mutex.create ();
    inflight_rooms = Hashtbl.create 64;
    idempotency_cache = Hashtbl.create 512;
    cache_writes = 0;
  }
let trpg_keeper_probe_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
  : Masc_mcp.Tool_trpg.keeper_probe_result =
  let keeper_ctx : _ Masc_mcp.Tool_keeper.context = { config; sw; clock } in
  let keeper_args =
    `Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ]
  in
  try
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      match
        Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
          ~args:keeper_args
      with
      | None -> `Error "masc_keeper_status dispatch unavailable"
      | Some (true, _body) -> `Ok
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Error "timeout"
  | exn -> `Error (Printexc.to_string exn)
let trpg_round_run_json
    ~(state : Mcp_server.server_state)
    ~(agent_name : string)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~(idempotency_key : string option)
    ~body_str
  : trpg_api_result =
  let with_round_run_guard_lock f =
    Mutex.lock trpg_round_run_guard.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock trpg_round_run_guard.mutex) f
  in
  let trpg_round_run_extract_room_id (args : Yojson.Safe.t) : string =
    let pick key =
      match Yojson.Safe.Util.member key args with
      | `String raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
      | _ -> None
    in
    match pick "room_id" with
    | Some room_id -> room_id
    | None -> (
        match pick "room" with
        | Some room_id -> room_id
        | None -> "default")
  in
  let trpg_round_run_extract_idempotency_key
      ~(header_key : string option)
      (args : Yojson.Safe.t) : string option =
    let normalize = function
      | None -> None
      | Some raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
    in
    match normalize header_key with
    | Some _ as key -> key
    | None -> (
        match Yojson.Safe.Util.member "idempotency_key" args with
        | `String raw -> normalize (Some raw)
        | _ -> None)
  in
  let trpg_round_run_cache_key ~room_id ~idempotency_key =
    room_id ^ "\x1f" ^ idempotency_key
  in
  let trpg_round_run_cache_lookup ~room_id ~idempotency_key =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.find_opt trpg_round_run_guard.idempotency_cache key)
  in
  let trpg_round_run_cache_store ~room_id ~idempotency_key ~result_json =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.replace trpg_round_run_guard.idempotency_cache key result_json;
      trpg_round_run_guard.cache_writes <- trpg_round_run_guard.cache_writes + 1;
      if trpg_round_run_guard.cache_writes >= 1024
         && Hashtbl.length trpg_round_run_guard.idempotency_cache > 4096
      then (
        Hashtbl.reset trpg_round_run_guard.idempotency_cache;
        trpg_round_run_guard.cache_writes <- 0))
  in
  let trpg_round_run_try_acquire ~room_id =
    with_round_run_guard_lock (fun () ->
      if Hashtbl.mem trpg_round_run_guard.inflight_rooms room_id then false
      else (
        Hashtbl.replace trpg_round_run_guard.inflight_rooms room_id ();
        true))
  in
  let trpg_round_run_release ~room_id =
    with_round_run_guard_lock (fun () ->
      Hashtbl.remove trpg_round_run_guard.inflight_rooms room_id)
  in
  try
    let args = Yojson.Safe.from_string body_str in
    let room_id = trpg_round_run_extract_room_id args in
    let idempotency_key =
      trpg_round_run_extract_idempotency_key ~header_key:idempotency_key args
    in
    let run_once () =
      let keeper_call =
        trpg_keeper_call_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let keeper_probe =
        trpg_keeper_probe_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let trpg_ctx : Masc_mcp.Tool_trpg.context =
        {
          store = Masc_mcp.Trpg_store.make_sqlite ~base_dir:state.Mcp_server.room_config.base_path;
          agent_name;
          keeper_call = Some keeper_call;
          keeper_probe = Some keeper_probe;
          dm_voice_emit = None;
        }
      in
      match Masc_mcp.Tool_trpg.dispatch trpg_ctx ~name:"masc_trpg_round_run" ~args with
      | None ->
          Error (`Internal_server_error, "masc_trpg_round_run dispatch unavailable")
      | Some (false, msg) -> Error (`Bad_request, msg)
      | Some (true, body) -> (
          try Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            Error (`Internal_server_error, Printf.sprintf "invalid tool json: %s" e))
    in
    let run_with_single_flight () =
      if not (trpg_round_run_try_acquire ~room_id) then
        Error
          ( `Bad_request,
            Printf.sprintf
              "round run already in progress for room_id=%s (single-flight)"
              room_id )
      else
        Fun.protect
          ~finally:(fun () -> trpg_round_run_release ~room_id)
          (fun () ->
            let result = run_once () in
            (match (result, idempotency_key) with
            | Ok json, Some idem_key ->
                trpg_round_run_cache_store
                  ~room_id
                  ~idempotency_key:idem_key
                  ~result_json:json
            | _ -> ());
            result)
    in
    match idempotency_key with
    | Some idem_key -> (
        match trpg_round_run_cache_lookup ~room_id ~idempotency_key:idem_key with
        | Some json -> Ok json
        | None -> run_with_single_flight ())
    | None -> run_with_single_flight ()
  with
  | Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn -> Error (`Internal_server_error, Printexc.to_string exn)

let bearer_token_from_header value =
  let prefix = "Bearer " in
  let prefix_lower = "bearer " in
  if String.length value >= String.length prefix &&
     String.sub value 0 (String.length prefix) = prefix then
    Some (String.sub value (String.length prefix) (String.length value - String.length prefix))
  else if String.length value >= String.length prefix_lower &&
          String.sub value 0 (String.length prefix_lower) = prefix_lower then
    Some (String.sub value (String.length prefix_lower) (String.length value - String.length prefix_lower))
  else
    None

let auth_token_from_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "authorization" with
  | Some v -> bearer_token_from_header v
  | None -> query_param request "token"

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let http_auth_strict_enabled () = env_flag_enabled "MASC_HTTP_AUTH_STRICT"

(** TTS proxy — forwards text to ElevenLabs and returns audio/mpeg bytes.
    Reads ELEVENLABS_API_KEY from environment. *)
let trpg_tts_proxy ~body_str : (string, [> `Bad_request | `Internal_server_error] * string) result =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let text =
      match json |> member "text" |> to_string_option with
      | Some t when String.length (String.trim t) > 0 -> String.trim t
      | _ -> raise (Yojson.Json_error "missing or empty 'text' field")
    in
    let voice_id =
      match json |> member "voice_id" |> to_string_option with
      | Some v when String.length v > 0 -> v
      | _ -> "21m00Tcm4TlvDq8ikWAM"  (* Rachel *)
    in
    let model_id =
      match json |> member "voice_model" |> to_string_option with
      | Some m when String.length m > 0 -> m
      | _ -> "eleven_multilingual_v2"
    in
    match Sys.getenv_opt "ELEVENLABS_API_KEY" with
    | None | Some "" ->
        Error (`Internal_server_error, "ELEVENLABS_API_KEY not configured")
    | Some api_key ->
        let url = Printf.sprintf
          "https://api.elevenlabs.io/v1/text-to-speech/%s" voice_id in
        let req_body = Yojson.Safe.to_string (`Assoc [
          ("text", `String text);
          ("model_id", `String model_id);
          ("voice_settings", `Assoc [
            ("stability", `Float 0.5);
            ("similarity_boost", `Float 0.75);
            ("style", `Float 0.0);
          ]);
        ]) in
        let headers = [
          ("xi-api-key", api_key);
          ("Content-Type", "application/json");
          ("Accept", "audio/mpeg");
        ] in
        let header_args = List.concat_map (fun (k, v) ->
          ["-H"; Printf.sprintf "%s: %s" k v]
        ) headers in
        let argv = ["curl"; "-s"; "--max-time"; "30";
                    "-X"; "POST"; url] @ header_args @ ["-d"; "@-"] in
        let (status, raw) = Process_eio.run_argv_with_stdin_and_status
          ~timeout_sec:35.0
          ~stdin_content:req_body
          argv in
        (match status with
         | Unix.WEXITED 0 ->
             if String.length raw < 100 then
               (* ElevenLabs returns JSON error bodies which are short *)
               (try
                 let err_json = Yojson.Safe.from_string raw in
                 let detail = err_json |> member "detail" |> member "message"
                   |> to_string_option |> Option.value ~default:raw in
                 Error (`Internal_server_error,
                   Printf.sprintf "ElevenLabs error: %s" detail)
               with _ -> Ok raw)
             else
               Ok raw
         | Unix.WEXITED 28 ->
             Error (`Internal_server_error, "ElevenLabs request timed out")
         | Unix.WEXITED code ->
             Error (`Internal_server_error,
               Printf.sprintf "curl exit %d calling ElevenLabs" code)
         | _ ->
             Error (`Internal_server_error, "ElevenLabs request failed"))
  with
  | Yojson.Json_error e ->
      Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn ->
      Error (`Internal_server_error,
        Printf.sprintf "TTS proxy error: %s" (Printexc.to_string exn))

let agent_from_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "x-masc-agent" with
  | Some v -> Some v
  | None ->
      match Httpun.Headers.get request.Httpun.Request.headers "x-masc-agent-name" with
      | Some v -> Some v
      | None ->
          (match query_param request "agent" with
           | Some v -> Some v
           | None -> query_param request "agent_name")

let http_status_of_auth_error = function
  | Types.Unauthorized _ | Types.InvalidToken _ | Types.TokenExpired _ -> `Unauthorized
  | Types.Forbidden _ -> `Forbidden
  | _ -> `Internal_server_error

(** Server state - initialized at startup *)
let server_state : Mcp_server.server_state option ref = ref None

(** CORS origin *)
let get_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | Some o -> o
  | None -> "*"

(** CORS headers *)
let cors_allow_headers_value =
  "Content-Type, Accept, Origin, Authorization, Idempotency-Key, Mcp-Session-Id, \
   Mcp-Protocol-Version, Last-Event-Id, X-MASC-Agent, X-MASC-Agent-Name"

let cors_headers origin = [
  ("access-control-allow-origin", origin);
  ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
  ("access-control-allow-headers", cors_allow_headers_value);
  ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ("access-control-allow-credentials", "true");
]

let respond_json_with_cors ?(status = `OK) request reqd body =
  let origin = get_origin request in
  Http.Response.json ~status ~extra_headers:(cors_headers origin) body reqd

let auth_error_json err =
  Yojson.Safe.to_string
    (`Assoc [ ("error", `String (Types.masc_error_to_string err)) ])

let respond_auth_error request reqd err =
  let status = http_status_of_auth_error err in
  let origin = get_origin request in
  let body = auth_error_json err in
  let headers = Httpun.Headers.of_list (
    ("content-length", string_of_int (String.length body))
    :: cors_headers origin
  ) in
  let response = Httpun.Response.create ~headers status in
  Httpun.Reqd.respond_with_string reqd response body

(** Admin-only access - requires MASC_ADMIN_TOKEN.
    Uses timing-safe comparison (XOR-based constant-time) to prevent
    timing side-channel attacks that could leak token bytes. *)
let with_admin_auth handler request reqd =
  match !server_state with
  | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let admin_token = Sys.getenv_opt "MASC_ADMIN_TOKEN" in
      let provided = auth_token_from_request request in
      match admin_token, provided with
      | None, _ ->
          Http.Response.json ~status:`Forbidden
            {|{"error":"MASC_ADMIN_TOKEN not configured"}|} reqd
      | Some _, None ->
          Http.Response.json ~status:`Unauthorized
            {|{"error":"Admin token required"}|} reqd
      | Some expected, Some given ->
          (* Timing-safe comparison: XOR all bytes, accumulate differences.
             Runs in constant time regardless of where mismatch occurs. *)
          let len_eq = String.length expected = String.length given in
          let content_eq =
            if not len_eq then false
            else
              let diff = ref 0 in
              for i = 0 to String.length expected - 1 do
                diff := !diff lor (Char.code expected.[i] lxor Char.code given.[i])
              done;
              !diff = 0
          in
          if len_eq && content_eq then
            handler state request reqd
          else
            Http.Response.json ~status:`Forbidden
              {|{"error":"Invalid admin token"}|} reqd

(** Public read access - no auth required (dashboard, health) *)
let is_public_read_path path =
  String.equal path "/health"
  || String.equal path "/"
  || String.equal path "/dashboard"
  || String.equal path "/dashboard/"
  || String.equal path "/favicon.ico"
  || String.equal path "/favicon.svg"
  || String.starts_with ~prefix:"/dashboard/" path
  || String.starts_with ~prefix:"/static/" path
  || String.starts_with ~prefix:"/graphiql/" path

let resolve_agent_name_for_auth ~base_path request ~token :
    (string option, Types.masc_error) result =
  match agent_from_request request with
  | Some raw when String.trim raw <> "" -> Ok (Some (String.trim raw))
  | _ ->
      (match token with
       | None -> Ok None
       | Some t ->
           (match Auth.resolve_agent_from_token base_path ~token:t with
            | Ok agent_name -> Ok (Some agent_name)
            | Error (Types.InvalidToken _ as e) -> Error e
            | Error (Types.TokenExpired _ as e) -> Error e
            | Error _ -> Ok None))

let authorize_permission_request ~base_path ~permission request :
    (unit, Types.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  match resolve_agent_name_for_auth ~base_path request ~token with
  | Error err -> Error err
  | Ok agent_name_opt ->
      let agent_name = Option.value ~default:"dashboard" agent_name_opt in
      if auth_cfg.enabled && auth_cfg.require_token && token <> None && agent_name_opt = None then
        Error
          (Types.Unauthorized
             "Agent name required (X-MASC-Agent or token-bound credential)")
      else
        Auth.check_permission base_path ~agent_name ~token
          ~permission

let authorize_read_request ~base_path request : (unit, Types.masc_error) result =
  authorize_permission_request ~base_path ~permission:Types.CanReadState request

let rec with_public_read handler request reqd =
  let strict = http_auth_strict_enabled () in
  let path = Http.Request.path request in
  if strict && not (is_public_read_path path) then
    with_read_auth handler request reqd
  else
    match !server_state with
    | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
    | Some state -> handler state request reqd

and with_read_auth handler request reqd =
  match !server_state with
  | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      match authorize_read_request ~base_path request with
      | Ok () -> handler state request reqd
      | Error err -> respond_auth_error request reqd err

and with_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      match authorize_permission_request ~base_path ~permission request with
      | Ok () -> handler state request reqd
      | Error err -> respond_auth_error request reqd err

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

let bool_of_env name =
  match Sys.getenv_opt name with
  | None -> false
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y"

let bool_default_true_of_env name =
  match Sys.getenv_opt name with
  | None -> true
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let int_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        (try int_of_string (String.trim s) with _ -> default)
  in
  max min_v (min max_v v)

let dashboard_semantics_http_json () =
  Masc_mcp.Dashboard_semantics.json ()

let float_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        (try float_of_string (String.trim s) with _ -> default)
  in
  max min_v (min max_v v)

let bool_of_tag_value (raw : string) : bool =
  let v = String.trim raw |> String.lowercase_ascii in
  v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let parse_tool_call_detail (detail_opt : string option)
  : string * bool * int option =
  match detail_opt with
  | None -> ("unknown", false, None)
  | Some raw ->
      let parts = String.split_on_char '|' raw |> List.map String.trim in
      let tool_name =
        match parts with
        | head :: _ when head <> "" -> head
        | _ -> "unknown"
      in
      let timeout = ref false in
      let duration_ms = ref None in
      let parse_kv token =
        match String.split_on_char '=' token with
        | [k; v] -> Some (String.trim k, String.trim v)
        | _ -> None
      in
      let tags =
        match parts with
        | _ :: tl -> tl
        | [] -> []
      in
      List.iter
        (fun token ->
          match parse_kv token with
          | Some ("timeout", v) ->
              timeout := bool_of_tag_value v
          | Some ("duration_ms", v) ->
              (try duration_ms := Some (max 0 (int_of_string v)) with _ -> ())
          | _ -> ())
        tags;
      (tool_name, !timeout, !duration_ms)

let percentile_int (values : int list) ~(pct : float) : int option =
  match List.sort compare values with
  | [] -> None
  | sorted ->
      let n = List.length sorted in
      let idx =
        int_of_float (ceil (pct *. float_of_int n) -. 1.0)
        |> max 0
        |> min (n - 1)
      in
      Some (List.nth sorted idx)

let tool_call_health_json (config : Room.config) : Yojson.Safe.t =
  let window_hours =
    float_of_env_default
      "MASC_DASHBOARD_TOOL_CALL_WINDOW_HOURS"
      ~default:1.0
      ~min_v:0.1
      ~max_v:168.0
  in
  let since = Masc_mcp.Time_compat.now () -. (window_hours *. 3600.0) in
  let events = Tool_audit.read_audit_events config ~since in
  let total = ref 0 in
  let failures = ref 0 in
  let timeouts = ref 0 in
  let durations_rev = ref [] in
  let duration_count = ref 0 in
  let duration_sum = ref 0 in
  let keeper_status_calls = ref 0 in
  let keeper_status_failures = ref 0 in
  let keeper_status_timeouts = ref 0 in
  let keeper_msg_calls = ref 0 in
  let keeper_msg_failures = ref 0 in
  let keeper_msg_timeouts = ref 0 in
  List.iter
    (fun (e : Tool_audit.audit_event) ->
      if e.event_type = "tool_call" then begin
        incr total;
        if not e.success then incr failures;
        let (tool_name, timeout_now, duration_ms_opt) =
          parse_tool_call_detail e.detail
        in
        if timeout_now then incr timeouts;
        (match duration_ms_opt with
         | Some d ->
             incr duration_count;
             duration_sum := !duration_sum + d;
             durations_rev := d :: !durations_rev
         | None -> ());
        if tool_name = "masc_keeper_status" then begin
          incr keeper_status_calls;
          if not e.success then incr keeper_status_failures;
          if timeout_now then incr keeper_status_timeouts;
        end else if tool_name = "masc_keeper_msg" then begin
          incr keeper_msg_calls;
          if not e.success then incr keeper_msg_failures;
          if timeout_now then incr keeper_msg_timeouts;
        end
      end)
    events;
  let total_f = float_of_int !total in
  let failure_rate =
    if !total = 0 then 0.0 else float_of_int !failures /. total_f
  in
  let timeout_rate =
    if !total = 0 then 0.0 else float_of_int !timeouts /. total_f
  in
  let avg_duration_ms =
    if !duration_count = 0 then 0.0
    else float_of_int !duration_sum /. float_of_int !duration_count
  in
  let p95_duration_ms = percentile_int !durations_rev ~pct:0.95 in
  let keeper_msg_timeout_sec =
    int_of_env_default
      "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
      ~default:45
      ~min_v:10
      ~max_v:300
  in
  `Assoc [
    ("window_hours", `Float window_hours);
    ("tool_calls", `Int !total);
    ("failures", `Int !failures);
    ("timeouts", `Int !timeouts);
    ("failure_rate", `Float failure_rate);
    ("timeout_rate", `Float timeout_rate);
    ("duration_sample_count", `Int !duration_count);
    ("avg_duration_ms", `Float avg_duration_ms);
    ("p95_duration_ms", match p95_duration_ms with Some v -> `Int v | None -> `Null);
    ("keeper_msg_timeout_sec", `Int keeper_msg_timeout_sec);
    ("keeper_status", `Assoc [
      ("calls", `Int !keeper_status_calls);
      ("failures", `Int !keeper_status_failures);
      ("timeouts", `Int !keeper_status_timeouts);
    ]);
    ("keeper_msg", `Assoc [
      ("calls", `Int !keeper_msg_calls);
      ("failures", `Int !keeper_msg_failures);
      ("timeouts", `Int !keeper_msg_timeouts);
    ]);
  ]

let json_int_opt = function
  | Some v -> `Int v
  | None -> `Null

let safe_age_seconds_opt ~(now_ts : float) ~(event_ts : float) : int option =
  let delta = now_ts -. event_ts in
  if Float.is_nan delta || Float.is_infinite delta then None
  else
    let bounded = max 0.0 (min delta (float_of_int max_int)) in
    Some (int_of_float bounded)

let board_monitoring_json ~(now_ts : float) : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_SLO_SEC"
      ~default:900
      ~min_v:30
      ~max_v:86400
  in
  try
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:200 () in
    let total_posts = List.length posts in
    let new_posts_24h =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.created_at >= (now_ts -. (24.0 *. 3600.0)) then acc + 1 else acc)
        0 posts
    in
    let unanswered_posts =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.reply_count = 0 then acc + 1 else acc)
        0 posts
    in
    let latest_activity_ts_opt =
      List.fold_left
        (fun acc (p : Board.post) ->
          match acc with
          | None -> Some p.updated_at
          | Some prev -> Some (max prev p.updated_at))
        None posts
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let alert_level =
      match last_activity_age_s with
      | None -> "warn"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      match last_activity_age_s with
      | Some age -> age >= slo_target_age_s
      | None -> false
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("posts_total", `Int total_posts);
      ("new_posts_24h", `Int new_posts_24h);
      ("unanswered_posts", `Int unanswered_posts);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool slo_breached);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], true)
  with exn ->
    Printf.eprintf "[dashboard] board_monitoring_json failed: %s\n%!"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("posts_total", `Int 0);
      ("new_posts_24h", `Int 0);
      ("unanswered_posts", `Int 0);
      ("last_activity_age_s", `Null);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool false);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], false)

let council_monitoring_json ~(now_ts : float) ~(base_path : string)
  : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_quorum_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_SLO_SEC"
      ~default:1800
      ~min_v:30
      ~max_v:86400
  in
  try
    let cfg = Council.make_config ~base_path in
    let debates = Council.DebateApi.list_all ~config:cfg ~status_filter:None ~limit:200 () in
    let sessions = Council.ConsensusApi.list_active () in
    let debates_open =
      List.fold_left
        (fun acc (d : Council.Debate.debate) ->
          if d.status = Council.Debate.Open then acc + 1 else acc)
        0 debates
    in
    let debates_pending =
      List.fold_left
        (fun acc (d : Council.Debate.debate) ->
          if d.status = Council.Debate.Pending then acc + 1 else acc)
        0 debates
    in
    let sessions_active = List.length sessions in
    let sessions_without_quorum =
      List.fold_left
        (fun acc (s : Council.Consensus.session) ->
          if List.length s.votes < s.quorum then acc + 1 else acc)
        0 sessions
    in
    let oldest_open_debate_ts_opt =
      List.fold_left
        (fun acc (d : Council.Debate.debate) ->
          if d.status <> Council.Debate.Open then acc
          else
            match acc with
            | None -> Some d.created_at
            | Some prev -> Some (min prev d.created_at))
        None debates
    in
    let oldest_open_debate_age_s =
      match oldest_open_debate_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let latest_activity_ts_opt =
      let from_debates =
        List.fold_left
          (fun acc (d : Council.Debate.debate) ->
            match acc with
            | None -> Some d.created_at
            | Some prev -> Some (max prev d.created_at))
          None debates
      in
      List.fold_left
        (fun acc (s : Council.Consensus.session) ->
          match acc with
          | None -> Some s.created_at
          | Some prev -> Some (max prev s.created_at))
        from_debates sessions
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let base_alert =
      match last_activity_age_s with
      | None -> "warn"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      if sessions_without_quorum > 0 then
        match oldest_open_debate_age_s with
        | Some age -> age >= slo_target_quorum_age_s
        | None -> false
      else
        match last_activity_age_s with
        | Some age -> age >= slo_target_quorum_age_s
        | None -> false
    in
    let alert_level =
      if sessions_without_quorum <= 0 then base_alert
      else
        match oldest_open_debate_age_s with
        | Some age when age >= bad_age_s -> "bad"
        | _ -> "warn"
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("debates_open", `Int debates_open);
      ("debates_pending", `Int debates_pending);
      ("sessions_active", `Int sessions_active);
      ("sessions_without_quorum", `Int sessions_without_quorum);
      ("oldest_open_debate_age_s", json_int_opt oldest_open_debate_age_s);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_quorum_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool slo_breached);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], true)
  with exn ->
    Printf.eprintf "[dashboard] council_monitoring_json failed: %s\n%!"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("debates_open", `Int 0);
      ("debates_pending", `Int 0);
      ("sessions_active", `Int 0);
      ("sessions_without_quorum", `Int 0);
      ("oldest_open_debate_age_s", `Null);
      ("last_activity_age_s", `Null);
      ("slo_target_quorum_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool false);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], false)

type keeper_gen_window_stats = {
  mutable turns: int;
  mutable input_tokens: int;
  mutable output_tokens: int;
  mutable total_tokens: int;
  mutable handoffs: int;
  mutable compactions: int;
  mutable memory_compactions: int;
  mutable memory_trimmed: int;
  mutable memory_checks: int;
  mutable memory_passed: int;
  mutable memory_notes: int;
  mutable first_ts: float;
  mutable last_ts: float;
  models: (string, int) Hashtbl.t;
  tools: (string, int) Hashtbl.t;
}

let create_keeper_gen_window_stats () : keeper_gen_window_stats =
  {
    turns = 0;
    input_tokens = 0;
    output_tokens = 0;
    total_tokens = 0;
    handoffs = 0;
    compactions = 0;
    memory_compactions = 0;
    memory_trimmed = 0;
    memory_checks = 0;
    memory_passed = 0;
    memory_notes = 0;
    first_ts = 0.0;
    last_ts = 0.0;
    models = Hashtbl.create 8;
    tools = Hashtbl.create 8;
  }

let count_table_incr (tbl : (string, int) Hashtbl.t) (key : string) : unit =
  let key = String.trim key in
  if key <> "" then
    let cur = Option.value ~default:0 (Hashtbl.find_opt tbl key) in
    Hashtbl.replace tbl key (cur + 1)

let utf8_safe_prefix_bytes (s : string) ~(max_bytes : int) : string =
  if max_bytes <= 0 then ""
  else
    let len = String.length s in
    if len <= max_bytes then s
    else
      let rec loop i last_good =
        if i >= len || i >= max_bytes then last_good
        else
          let dec = String.get_utf_8_uchar s i in
          let dlen = Uchar.utf_decode_length dec in
          if dlen <= 0 then last_good
          else
            let next = i + dlen in
            if next > max_bytes then last_good
            else loop next next
      in
      let cut = loop 0 0 in
      if cut <= 0 then ""
      else String.sub s 0 cut

let truncate_text ~(max_len : int) (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else
    try
      ignore (Str.search_forward (Str.regexp_string n) h 0);
      true
    with Not_found ->
      false

let normalize_similarity_text (s : string) : string =
  s
  |> String.lowercase_ascii
  |> Str.global_replace (Str.regexp "[^0-9a-z가-힣]+") " "
  |> Str.global_replace (Str.regexp " +") " "
  |> String.trim

let token_set_of_text (s : string) : (string, unit) Hashtbl.t =
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let norm = normalize_similarity_text s in
  if norm <> "" then
    norm
    |> String.split_on_char ' '
    |> List.iter (fun tok ->
         let tok = String.trim tok in
         if tok <> "" then Hashtbl.replace tbl tok ());
  tbl

let jaccard_similarity_text (a : string) (b : string) : float =
  let sa = token_set_of_text a in
  let sb = token_set_of_text b in
  let na = Hashtbl.length sa in
  let nb = Hashtbl.length sb in
  if na = 0 || nb = 0 then 0.0
  else
    let inter =
      Hashtbl.fold
        (fun tok () acc -> if Hashtbl.mem sb tok then acc + 1 else acc)
        sa 0
    in
    let union = na + nb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let take_last (n : int) (xs : 'a list) : 'a list =
  let n = max 0 n in
  let len = List.length xs in
  let drop = max 0 (len - n) in
  let rec drop_n k ys =
    if k <= 0 then ys
    else
      match ys with
      | [] -> []
      | _ :: tl -> drop_n (k - 1) tl
  in
  drop_n drop xs

let proactive_preview_similarity_stats
    ?(window = 8)
    ?(warn_threshold = 0.90)
    (previews : string list) : int * int * float * float * bool =
  let previews =
    previews
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> take_last window
  in
  let sample_count = List.length previews in
  let rec pairwise acc = function
    | a :: (b :: _ as tl) ->
        let sim = jaccard_similarity_text a b in
        pairwise (sim :: acc) tl
    | _ -> List.rev acc
  in
  let sims = pairwise [] previews in
  let pair_count = List.length sims in
  let avg =
    if pair_count = 0 then 0.0
    else List.fold_left ( +. ) 0.0 sims /. float_of_int pair_count
  in
  let max_sim =
    if pair_count = 0 then 0.0
    else List.fold_left max 0.0 sims
  in
  let warn = pair_count >= 2 && max_sim >= warn_threshold in
  (sample_count, pair_count, avg, max_sim, warn)

type keeper_24h_bucket_stats = {
  mutable sample_points: int;
  mutable context_ratio_sum: float;
  mutable proactive_points: int;
  mutable proactive_fallback_count: int;
}

let create_keeper_24h_bucket_stats () : keeper_24h_bucket_stats =
  {
    sample_points = 0;
    context_ratio_sum = 0.0;
    proactive_points = 0;
    proactive_fallback_count = 0;
  }

let keeper_metrics_24h_json
    ~(metrics_path : string)
    ~(now_ts : float) : Yojson.Safe.t * Yojson.Safe.t =
  let max_lines =
    int_of_env_default
      "MASC_DASHBOARD_24H_MAX_LINES"
      ~default:12000
      ~min_v:200
      ~max_v:50000
  in
  let max_bytes =
    int_of_env_default
      "MASC_DASHBOARD_24H_MAX_BYTES"
      ~default:3000000
      ~min_v:200000
      ~max_v:20000000
  in
  let window_sec = 24.0 *. 3600.0 in
  let start_ts = now_ts -. window_sec in
  let lines =
    Tool_keeper.read_file_tail_lines
      metrics_path
      ~max_bytes
      ~max_lines
  in
  let buckets : (int, keeper_24h_bucket_stats) Hashtbl.t = Hashtbl.create 64 in
  let sample_points = ref 0 in
  let proactive_points = ref 0 in
  let proactive_fallback_count = ref 0 in
  List.iter
    (fun line ->
      try
        let j = Yojson.Safe.from_string line in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        if ts_unix >= start_ts && ts_unix <= (now_ts +. 60.0) then begin
          incr sample_points;
          let bucket_ts =
            int_of_float (floor (ts_unix /. 3600.0) *. 3600.0)
          in
          let b =
            match Hashtbl.find_opt buckets bucket_ts with
            | Some row -> row
            | None ->
                let row = create_keeper_24h_bucket_stats () in
                Hashtbl.replace buckets bucket_ts row;
                row
          in
          let context_ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
          b.sample_points <- b.sample_points + 1;
          b.context_ratio_sum <- b.context_ratio_sum +. context_ratio;
          let channel = Safe_ops.json_string ~default:"turn" "channel" j in
          if channel = "proactive" then begin
            incr proactive_points;
            b.proactive_points <- b.proactive_points + 1;
            let proactive_obj = Yojson.Safe.Util.member "proactive" j in
            let fallback_applied =
              Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
            in
            if fallback_applied then begin
              incr proactive_fallback_count;
              b.proactive_fallback_count <- b.proactive_fallback_count + 1;
            end
          end
        end
      with exn -> Printf.eprintf "[main] keeper log parse: %s\n%!" (Printexc.to_string exn))
    lines;
  let rows =
    buckets
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ta, _) (tb, _) -> compare ta tb)
    |> List.map (fun (bucket_ts, b) ->
         let context_ratio_avg =
           if b.sample_points = 0 then 0.0
           else b.context_ratio_sum /. float_of_int b.sample_points
         in
         let proactive_fallback_rate =
           if b.proactive_points = 0 then 0.0
           else
             float_of_int b.proactive_fallback_count
             /. float_of_int b.proactive_points
         in
         `Assoc [
           ("bucket_ts_unix", `Int bucket_ts);
           ("sample_points", `Int b.sample_points);
           ("context_ratio_avg", `Float context_ratio_avg);
           ("proactive_points", `Int b.proactive_points);
           ("proactive_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_numerator", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_denominator", `Int b.proactive_points);
         ])
  in
  let bucket_count = List.length rows in
  let proactive_fallback_rate =
    if !proactive_points = 0 then 0.0
    else
      float_of_int !proactive_fallback_count
      /. float_of_int !proactive_points
  in
  let summary =
    `Assoc [
      ("window_hours", `Float 24.0);
      ("source_max_lines", `Int max_lines);
      ("source_max_bytes", `Int max_bytes);
      ("sample_points", `Int !sample_points);
      ("bucket_count", `Int bucket_count);
      ("from_ts_unix", `Float start_ts);
      ("to_ts_unix", `Float now_ts);
      ("coverage_hours", `Float (float_of_int bucket_count));
      ("proactive_points", `Int !proactive_points);
      ("proactive_fallback_count", `Int !proactive_fallback_count);
      ("proactive_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_count", `Int !proactive_fallback_count);
      ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_numerator", `Int !proactive_fallback_count);
      ("proactive_template_fallback_denominator", `Int !proactive_points);
    ]
  in
  (`List rows, summary)

let keeper_history_summary_json
    ~(all_keeper_names : string list)
    ~(keeper_name : string)
    ~(history_path : string)
    ~(filter_fragments : bool)
  : Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int =
  let history_lines =
    Tool_keeper.read_file_tail_lines
      history_path
      ~max_bytes:120000
      ~max_lines:80
  in
  let mention_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let (conversation_rev, k2k_rev, raw_count, fragment_count, filtered_count) =
    List.fold_left (fun (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count) line ->
      try
        let j = Yojson.Safe.from_string line in
        let role = Safe_ops.json_string ~default:"" "role" j |> String.trim in
        let role_lc = String.lowercase_ascii role in
        let content = Safe_ops.json_string ~default:"" "content" j |> String.trim in
        let ts_unix =
          let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
          if ts0 > 0.0 then ts0 else Safe_ops.json_float ~default:0.0 "timestamp" j
        in
        if role = "" || content = "" then
          (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
        else
          let is_fragment =
            role_lc = "assistant"
            && Tool_keeper.looks_fragmentary_history_text content
          in
          let should_filter = filter_fragments && is_fragment in
          let mentions =
            all_keeper_names
            |> List.filter (fun candidate ->
                 candidate <> keeper_name && contains_ci content candidate)
          in
          let (conv_acc, k2k_acc) =
            if should_filter then
              (conv_acc, k2k_acc)
            else
              let () = List.iter (count_table_incr mention_counts) mentions in
              let preview = truncate_text ~max_len:280 content in
              let is_k2k = role_lc = "user" && mentions <> [] in
              let conversation_item =
                `Assoc [
                  ("role", `String role);
                  ("ts_unix", `Float ts_unix);
                  ("content", `String content);
                  ("preview", `String preview);
                  ("mentions", `List (List.map (fun s -> `String s) mentions));
                  ("k2k", `Bool is_k2k);
                  ("is_fragment", `Bool is_fragment);
                ]
              in
              let k2k_acc =
                match mentions with
                | mentioned_keeper :: _ when is_k2k ->
                    (`Assoc [
                       ("keeper", `String keeper_name);
                       ("mentioned", `String mentioned_keeper);
                       ("role", `String role);
                       ("ts_unix", `Float ts_unix);
                       ("preview", `String preview);
                     ]) :: k2k_acc
                | _ -> k2k_acc
              in
              (conversation_item :: conv_acc, k2k_acc)
          in
          ( conv_acc,
            k2k_acc,
            raw_count + 1,
            fragment_count + (if is_fragment then 1 else 0),
            filtered_count + (if should_filter then 1 else 0) )
      with _ ->
        (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
    ) ([], [], 0, 0, 0) history_lines
  in
  let conversation = `List (List.rev conversation_rev) in
  let k2k_recent = `List (List.rev k2k_rev) in
  let k2k_mentions =
    mention_counts
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c else String.compare ka kb)
    |> Tool_keeper.take 5
    |> List.map (fun (k, v) ->
         `Assoc [("keeper", `String k); ("count", `Int v)])
    |> fun xs -> `List xs
  in
  (conversation, k2k_recent, k2k_mentions, raw_count, fragment_count, filtered_count)

let top_counts_json
    ?(limit = 5)
    ~(name_key : string)
    (tbl : (string, int) Hashtbl.t) : Yojson.Safe.t list =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> Tool_keeper.take limit
  |> List.map (fun (k, v) ->
       `Assoc [ (name_key, `String k); ("count", `Int v) ])

let top_count_name_and_count
    (tbl : (string, int) Hashtbl.t) : (string * int) option =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> function
  | (k, v) :: _ -> Some (k, v)
  | [] -> None

let get_agent_identity (name : string) =
  let contains s sub =
    let len = String.length s in
    let sub_len = String.length sub in
    if sub_len > len then false
    else
      let rec loop i =
        if i + sub_len > len then false
        else if String.sub s i sub_len = sub then true
        else loop (i + 1)
      in
      loop 0
  in
  let name = String.lowercase_ascii name in
  if contains name "claude" then ("🧠", "클로드")
  else if contains name "gemini" then ("💎", "제미나이")
  else if contains name "codex" then ("🤖", "코덱스")
  else if contains name "lodge" then ("🏠", "롯지 키퍼")
  else if contains name "gardener" then ("🌿", "정원사")
  else if contains name "review" then ("🔍", "리뷰어")
  else if contains name "test" then ("🧪", "테스터")
  else ("🤖", name)

let keepers_dashboard_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let include_goals = bool_of_env "MASC_DASHBOARD_INCLUDE_GOALS" in
  let history_fragment_filter_enabled =
    bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
  in
  let series_points = 120 in
  let normalize_model_name s =
    let s = String.trim s in
    let s =
      match String.index_opt s ':' with
      | None -> s
      | Some i ->
          let prefix = String.sub s 0 i |> String.lowercase_ascii in
          if List.mem prefix ["ollama"; "glm"; "claude"; "gemini"; "openrouter"] then
            String.sub s (i + 1) (String.length s - i - 1)
          else
            s
    in
    if String.ends_with ~suffix:":latest" s then
      String.sub s 0 (String.length s - String.length ":latest")
    else
      s
  in
  let names =
    let dir = Tool_keeper.keeper_dir config in
    if not (Sys.file_exists dir) then []
    else
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter Tool_keeper.validate_name
      |> List.sort String.compare
  in
  let now_ts = Masc_mcp.Time_compat.now () in
  let summaries =
    List.filter_map (fun name ->
      match Tool_keeper.read_meta config name with
      | Error _ -> None
      | Ok None -> None
      | Ok (Some (m : Tool_keeper.keeper_meta)) ->
          let agent = Tool_keeper.parse_agent_status config ~agent_name:m.agent_name in

          let created_ts =
            Masc_mcp.Resilience.Time.parse_iso8601_opt m.created_at
            |> Option.value ~default:0.0
          in
          let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
          let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
          let last_handoff_ago_s =
            if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts
          in
          let last_compaction_ago_s =
            if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts
          in
          let last_proactive_ago_s =
            if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
          in
          let trace_history_count = List.length m.trace_history in
          let active_model = Tool_keeper.active_model_of_meta m in
          let next_model_hint = Tool_keeper.next_model_hint_of_meta m in
          let primary_model =
            match m.models with
            | model :: _ -> model
            | [] -> ""
          in
          let primary_model_norm = normalize_model_name primary_model in
          let last_compaction_saved_tokens =
            max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
          in

          let metrics_path = Tool_keeper.keeper_metrics_path config m.name in
          let (metrics_24h, metrics_24h_summary) =
            if compact then (`Null, `Null)
            else keeper_metrics_24h_json ~metrics_path ~now_ts
          in
            let metrics_window_max_bytes = 200000 in
            let metrics_lines =
              Tool_keeper.read_file_tail_lines
              metrics_path ~max_bytes:metrics_window_max_bytes ~max_lines:series_points
          in
          let parsed_metrics =
            List.filter_map (fun line ->
              try Some (Yojson.Safe.from_string line) with _ -> None
            ) metrics_lines
          in
	          let last_metrics =
	            match List.rev parsed_metrics with
	            | latest :: _ -> Some latest
	            | [] -> None
	          in
	          let (last_skill_primary, last_skill_secondary, last_skill_reason) =
	            let open Yojson.Safe.Util in
	            let rec find_latest = function
	              | [] -> (None, [], None)
	              | j :: tl ->
	                  (match Safe_ops.json_string_opt "skill_primary" j with
	                   | Some primary when String.trim primary <> "" ->
	                       let secondary =
	                         match j |> member "skill_secondary" with
	                         | `List xs ->
	                             xs
	                             |> List.filter_map (fun v ->
	                                    match v with
	                                    | `String s when String.trim s <> "" -> Some s
	                                    | _ -> None)
	                         | _ -> []
	                       in
	                       let reason = Safe_ops.json_string_opt "skill_reason" j in
	                       (Some primary, secondary, reason)
	                   | _ -> find_latest tl)
	            in
	            find_latest (List.rev parsed_metrics)
	          in

	          let (metrics_series, metrics_window_summary, last_handoff_event, last_compaction_event) =
            let open Yojson.Safe.Util in
            let handoff_count = ref 0 in
            let compaction_events = ref 0 in
            let compaction_saved_tokens = ref 0 in
            let compaction_before_tokens = ref 0 in
            let fallback_count = ref 0 in
            let proactive_fallback_count = ref 0 in
            let tool_call_count = ref 0 in
            let turn_points = ref 0 in
            let heartbeat_points = ref 0 in
            let proactive_points = ref 0 in
            let drift_applied_count = ref 0 in
            let auto_reflect_count = ref 0 in
            let auto_plan_count = ref 0 in
            let auto_compact_count = ref 0 in
            let auto_handoff_count = ref 0 in
            let guardrail_stop_count = ref 0 in
            let repetition_risk_sum = ref 0.0 in
            let repetition_risk_points = ref 0 in
            let goal_alignment_sum = ref 0.0 in
            let goal_alignment_points = ref 0 in
            let response_alignment_sum = ref 0.0 in
            let response_alignment_points = ref 0 in
            let goal_drift_sum = ref 0.0 in
            let goal_drift_points = ref 0 in
            let memory_checks = ref 0 in
            let memory_passed = ref 0 in
            let memory_corrections = ref 0 in
            let memory_correction_success = ref 0 in
            let memory_score_sum = ref 0.0 in
            let memory_weather_checks = ref 0 in
            let memory_weather_passed = ref 0 in
            let memory_threshold = ref 0.18 in
            let memory_notes_added = ref 0 in
            let memory_compaction_events = ref 0 in
            let memory_compaction_before_notes = ref 0 in
            let memory_compaction_dropped_notes = ref 0 in
            let memory_compaction_invalid_dropped = ref 0 in
            let work_kind_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let model_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let tool_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let memory_kind_counts_window : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let drift_reason_counts : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let compaction_trigger_counts : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let generation_stats : (int, keeper_gen_window_stats) Hashtbl.t =
              Hashtbl.create 8
            in
            let proactive_previews_rev = ref [] in
            let last_handoff = ref None in
            let last_compaction = ref None in
            let items = List.filter_map (fun j ->
              try
                let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                let ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
                let tokens = Safe_ops.json_int ~default:0 "context_tokens" j in
                let context_max = Safe_ops.json_int ~default:0 "context_max" j in
                let channel = Safe_ops.json_string ~default:"turn" "channel" j in
                let is_turn = channel = "turn" in
                let is_heartbeat = channel = "heartbeat" in
                let is_proactive = channel = "proactive" in
                let is_interaction = is_turn || is_proactive in
                let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                let gen = Safe_ops.json_int ~default:m.generation "generation" j in
                let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
                let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                let saved_tokens = max 0 (before_tokens - after_tokens) in
                let compaction_trigger_now =
                  Safe_ops.json_string_opt "compaction_trigger" j
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let handoff_obj = j |> member "handoff" in
                let handoff_performed = Safe_ops.json_bool ~default:false "performed" handoff_obj in
                let handoff_to_model = Safe_ops.json_string_opt "to_model" handoff_obj in
                let handoff_prev_trace_id =
                  Safe_ops.json_string_opt "prev_trace_id" handoff_obj
                in
                let handoff_new_trace_id =
                  Safe_ops.json_string_opt "new_trace_id" handoff_obj
                in
                let handoff_new_generation =
                  Safe_ops.json_int_opt "new_generation" handoff_obj
                in
                let usage_obj = j |> member "usage" in
                let input_tokens = Safe_ops.json_int ~default:0 "input_tokens" usage_obj in
                let output_tokens = Safe_ops.json_int ~default:0 "output_tokens" usage_obj in
                let total_tokens = Safe_ops.json_int ~default:0 "total_tokens" usage_obj in
                let latency_ms = Safe_ops.json_int ~default:0 "latency_ms" j in
                let cost_usd = Safe_ops.json_float ~default:0.0 "cost_usd" j in
                let model_used = Safe_ops.json_string ~default:"" "model_used" j in
                let message_count = Safe_ops.json_int ~default:0 "message_count" j in
                let model_used_norm = normalize_model_name model_used in
                let model_bucket =
                  if model_used_norm <> "" then model_used_norm else model_used
                in
                let work_kind_raw = Safe_ops.json_string ~default:"" "work_kind" j in
                let memory_check = j |> member "memory_check" in
                let memory_performed =
                  Safe_ops.json_bool ~default:false "performed" memory_check
                in
                let memory_query_kind =
                  Safe_ops.json_string ~default:"none" "query_kind" memory_check
                in
                let memory_passed_now =
                  Safe_ops.json_bool ~default:false "passed" memory_check
                in
                let memory_final_score =
                  Safe_ops.json_float ~default:0.0 "final_score" memory_check
                in
                let memory_threshold_now =
                  Safe_ops.json_float ~default:0.18 "threshold" memory_check
                in
                let memory_correction_applied_now =
                  Safe_ops.json_bool ~default:false "correction_applied" memory_check
                in
                let memory_correction_success_now =
                  Safe_ops.json_bool ~default:false "correction_success" memory_check
                in
                let memory_expected_topic =
                  Safe_ops.json_string_opt "expected_topic" memory_check
                in
                let proactive_obj = j |> member "proactive" in
                let proactive_fallback_applied_now =
                  Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
                in
                let proactive_preview_now =
                  Safe_ops.json_string_opt "preview" proactive_obj
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let drift_obj = j |> member "drift" in
                let drift_applied_now =
                  Safe_ops.json_bool ~default:false "applied" drift_obj
                in
                let drift_reason_now =
                  Safe_ops.json_string_opt "reason" drift_obj
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let auto_rules_obj = j |> member "auto_rules" in
                let auto_reflect_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules_obj)
                    "auto_reflect"
                    j
                in
                let auto_plan_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules_obj)
                    "auto_plan"
                    j
                in
                let auto_compact_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules_obj)
                    "auto_compact"
                    j
                in
                let auto_handoff_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules_obj)
                    "auto_handoff"
                    j
                in
                let guardrail_stop_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules_obj)
                    "guardrail_stop"
                    j
                in
                let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
                let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
                let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
                let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
                let memory_notes_added_now =
                  Safe_ops.json_int ~default:0 "memory_notes_added" j
                in
                let memory_top_kind_now =
                  Safe_ops.json_string_opt "memory_top_kind" j
                in
                let memory_note_kinds =
                  match j |> member "memory_note_kinds" with
                  | `List xs ->
                      List.filter_map
                        (function
                          | `String s when String.trim s <> "" -> Some (String.trim s)
                          | _ -> None)
                        xs
                  | _ -> []
                in
                let memory_compaction_performed_now =
                  Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                in
                let memory_compaction_before_notes_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                in
                let memory_compaction_dropped_notes_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                in
                let memory_compaction_invalid_dropped_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                in
                let tools_used =
                  match j |> member "tools_used" with
                  | `List xs ->
                      List.filter_map (function
                        | `String s when String.trim s <> "" -> Some s
                        | _ -> None) xs
                  | _ -> []
                in
                let tool_call_count_now =
                  Safe_ops.json_int ~default:(List.length tools_used) "tool_call_count" j
                in
                let work_kind =
                  if work_kind_raw <> "" then work_kind_raw
                  else if memory_performed then
                    if memory_query_kind <> "" && memory_query_kind <> "none" then
                      memory_query_kind
                    else
                      "memory_recall"
                  else
                    match memory_expected_topic with
                    | Some "weather" -> "weather_answer"
                    | Some "first_question" -> "first_question_answer"
                    | Some topic when topic <> "" -> topic
                    | _ -> "general_chat"
                in
                let memory_is_weather =
                  match memory_expected_topic with Some "weather" -> true | _ -> false
                in
                if handoff_performed then begin
                  if is_interaction then incr handoff_count;
                  last_handoff := Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("generation", `Int gen);
                    ("to_model",
                      match handoff_to_model with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("prev_trace_id",
                      match handoff_prev_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("new_trace_id",
                      match handoff_new_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("new_generation",
                      match handoff_new_generation with
                      | Some g -> `Int g
                      | None -> `Null);
                  ]);
                end;
                if compacted then begin
                  if is_interaction then begin
                    incr compaction_events;
                    compaction_saved_tokens := !compaction_saved_tokens + saved_tokens;
                    compaction_before_tokens := !compaction_before_tokens + before_tokens;
                    (match compaction_trigger_now with
                     | Some reason -> count_table_incr compaction_trigger_counts reason
                     | None -> ());
                  end;
                  last_compaction := Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("generation", `Int gen);
                    ("before_tokens", `Int before_tokens);
                    ("after_tokens", `Int after_tokens);
                    ("saved_tokens", `Int saved_tokens);
                    ("trigger",
                      match compaction_trigger_now with
                      | Some reason -> `String reason
                      | None -> `Null);
                  ]);
                end;
                if is_interaction
                   && primary_model_norm <> ""
                   && model_used_norm <> ""
                   && model_used_norm <> primary_model_norm
                then
                  incr fallback_count;
                if is_turn then incr turn_points;
                if is_proactive then incr proactive_points;
                if is_proactive && proactive_fallback_applied_now then
                  incr proactive_fallback_count;
                if is_proactive then
                  (match proactive_preview_now with
                   | Some preview ->
                       proactive_previews_rev := preview :: !proactive_previews_rev
                   | None -> ());
                if is_interaction then begin
                  if auto_reflect_now then incr auto_reflect_count;
                  if auto_plan_now then incr auto_plan_count;
                  if auto_compact_now then incr auto_compact_count;
                  if auto_handoff_now then incr auto_handoff_count;
                  if guardrail_stop_now then incr guardrail_stop_count;
                  (match repetition_risk_opt with
                   | Some v ->
                       repetition_risk_sum := !repetition_risk_sum +. v;
                       incr repetition_risk_points
                   | None -> ());
                  (match goal_alignment_opt with
                   | Some v ->
                       goal_alignment_sum := !goal_alignment_sum +. v;
                       incr goal_alignment_points
                   | None -> ());
                  (match response_alignment_opt with
                   | Some v ->
                       response_alignment_sum := !response_alignment_sum +. v;
                       incr response_alignment_points
                   | None -> ());
                  (match goal_drift_opt with
                   | Some v ->
                       goal_drift_sum := !goal_drift_sum +. v;
                       incr goal_drift_points
                   | None -> ());
                  if drift_applied_now then begin
                    incr drift_applied_count;
                    (match drift_reason_now with
                     | Some reason -> count_table_incr drift_reason_counts reason
                     | None -> ());
                  end;
                  tool_call_count := !tool_call_count + tool_call_count_now;
                  count_table_incr work_kind_counts work_kind;
                  count_table_incr model_counts_window model_bucket;
                  List.iter (count_table_incr tool_counts_window) tools_used;
                  memory_notes_added := !memory_notes_added + memory_notes_added_now;
                  if memory_compaction_performed_now then begin
                    incr memory_compaction_events;
                    memory_compaction_before_notes :=
                      !memory_compaction_before_notes + memory_compaction_before_notes_now;
                    memory_compaction_dropped_notes :=
                      !memory_compaction_dropped_notes + memory_compaction_dropped_notes_now;
                    memory_compaction_invalid_dropped :=
                      !memory_compaction_invalid_dropped
                      + memory_compaction_invalid_dropped_now;
                  end;
                  List.iter (count_table_incr memory_kind_counts_window) memory_note_kinds;
                  if memory_note_kinds = [] then
                    (match memory_top_kind_now with
                     | Some kind when String.trim kind <> "" ->
                         count_table_incr memory_kind_counts_window kind
                     | _ -> ());
                  if memory_performed then begin
                    incr memory_checks;
                    memory_score_sum := !memory_score_sum +. memory_final_score;
                    memory_threshold := memory_threshold_now;
                    if memory_passed_now then incr memory_passed;
                    if memory_correction_applied_now then incr memory_corrections;
                    if memory_correction_success_now then incr memory_correction_success;
                    if memory_is_weather then begin
                      incr memory_weather_checks;
                      if memory_passed_now then incr memory_weather_passed;
                    end;
                  end;
                  let gen_stats =
                    match Hashtbl.find_opt generation_stats gen with
                    | Some gs -> gs
                    | None ->
                        let gs = create_keeper_gen_window_stats () in
                        Hashtbl.add generation_stats gen gs;
                        gs
                  in
                  gen_stats.turns <- gen_stats.turns + 1;
                  gen_stats.input_tokens <- gen_stats.input_tokens + input_tokens;
                  gen_stats.output_tokens <- gen_stats.output_tokens + output_tokens;
                  gen_stats.total_tokens <- gen_stats.total_tokens + total_tokens;
                  if handoff_performed then gen_stats.handoffs <- gen_stats.handoffs + 1;
                  if compacted then gen_stats.compactions <- gen_stats.compactions + 1;
                  if memory_compaction_performed_now then
                    gen_stats.memory_compactions <- gen_stats.memory_compactions + 1;
                  if memory_compaction_performed_now then
                    gen_stats.memory_trimmed <-
                      gen_stats.memory_trimmed + memory_compaction_dropped_notes_now;
                  if memory_performed then begin
                    gen_stats.memory_checks <- gen_stats.memory_checks + 1;
                    if memory_passed_now then
                      gen_stats.memory_passed <- gen_stats.memory_passed + 1;
                  end;
                  gen_stats.memory_notes <- gen_stats.memory_notes + memory_notes_added_now;
                  if gen_stats.first_ts <= 0.0 || ts_unix < gen_stats.first_ts then
                    gen_stats.first_ts <- ts_unix;
                  if ts_unix > gen_stats.last_ts then
                    gen_stats.last_ts <- ts_unix;
                  count_table_incr gen_stats.models model_bucket;
                  List.iter (count_table_incr gen_stats.tools) tools_used;
                end;
                if is_heartbeat then incr heartbeat_points;
                if compact then None
                else
                  Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("channel", `String channel);
                    ("context_ratio", `Float ratio);
                    ("context_tokens", `Int tokens);
                    ("context_max", `Int context_max);
                    ("message_count", `Int message_count);
                    ("compacted", `Bool compacted);
                    ("handoff", `Bool handoff_performed);
                    ("handoff_to_model",
                      match handoff_to_model with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_prev_trace_id",
                      match handoff_prev_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_new_trace_id",
                      match handoff_new_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_new_generation",
                      match handoff_new_generation with
                      | Some g -> `Int g
                      | None -> `Null);
                    ("generation", `Int gen);
                    ("input_tokens", `Int input_tokens);
                    ("output_tokens", `Int output_tokens);
                    ("total_tokens", `Int total_tokens);
                    ("latency_ms", `Int latency_ms);
                    ("cost_usd", `Float cost_usd);
                    ("model_used", `String model_used);
                    ("compaction_before_tokens", `Int before_tokens);
                    ("compaction_after_tokens", `Int after_tokens);
                    ("compaction_saved_tokens", `Int saved_tokens);
                    ("compaction_trigger",
                      match compaction_trigger_now with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("work_kind", `String work_kind);
                    ("tool_call_count", `Int tool_call_count_now);
                    ("tools_used", `List (List.map (fun s -> `String s) tools_used));
                    ("proactive_fallback_applied", `Bool proactive_fallback_applied_now);
                    ("proactive_preview",
                      match proactive_preview_now with
                      | Some s -> `String s
                      | None -> `Null);
                    ("drift_applied", `Bool drift_applied_now);
                    ("drift_reason",
                      match drift_reason_now with
                      | Some s -> `String s
                      | None -> `Null);
                    ("auto_reflect", `Bool auto_reflect_now);
                    ("auto_plan", `Bool auto_plan_now);
                    ("auto_compact", `Bool auto_compact_now);
                    ("auto_handoff", `Bool auto_handoff_now);
                    ("guardrail_stop", `Bool guardrail_stop_now);
                    ("repetition_risk",
                      match repetition_risk_opt with Some v -> `Float v | None -> `Null);
                    ("goal_alignment",
                      match goal_alignment_opt with Some v -> `Float v | None -> `Null);
                    ("response_alignment",
                      match response_alignment_opt with Some v -> `Float v | None -> `Null);
                    ("goal_drift",
                      match goal_drift_opt with Some v -> `Float v | None -> `Null);
                    ("reflection", j |> member "reflection");
                    ("memory_performed", `Bool memory_performed);
                    ("memory_query_kind", `String memory_query_kind);
                    ("memory_passed", `Bool memory_passed_now);
                    ("memory_final_score", `Float memory_final_score);
                    ("memory_threshold", `Float memory_threshold_now);
                    ("memory_correction_applied", `Bool memory_correction_applied_now);
                    ("memory_correction_success", `Bool memory_correction_success_now);
                    ("memory_notes_added", `Int memory_notes_added_now);
                    ("memory_top_kind",
                      match memory_top_kind_now with
                      | Some s when String.trim s <> "" -> `String s
                      | _ -> `Null);
                    ("memory_note_kinds",
                      `List (List.map (fun s -> `String s) memory_note_kinds));
                    ("memory_compaction_performed", `Bool memory_compaction_performed_now);
                    ("memory_compaction_before_notes", `Int memory_compaction_before_notes_now);
                    ("memory_compaction_dropped_notes", `Int memory_compaction_dropped_notes_now);
                    ("memory_compaction_invalid_dropped", `Int memory_compaction_invalid_dropped_now);
                    ("memory_expected_topic",
                      match memory_expected_topic with
                      | Some s -> `String s
                      | None -> `Null);
                  ])
              with _ -> None
            ) parsed_metrics in
            let sample_points = List.length items in
            let turn_points_int = !turn_points in
            let proactive_points_int = !proactive_points in
            let interaction_points_int = turn_points_int + proactive_points_int in
            let fallback_rate =
              if interaction_points_int = 0 then 0.0 else
                float_of_int !fallback_count /. float_of_int interaction_points_int
            in
            let proactive_fallback_rate =
              if proactive_points_int = 0 then 0.0 else
                float_of_int !proactive_fallback_count
                /. float_of_int proactive_points_int
            in
            let intervention_share =
              if interaction_points_int = 0 then 0.0
              else float_of_int proactive_points_int /. float_of_int interaction_points_int
            in
            let intervention_per_turn =
              if turn_points_int = 0 then 0.0
              else float_of_int proactive_points_int /. float_of_int turn_points_int
            in
            let drift_applied_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !drift_applied_count /. float_of_int interaction_points_int
            in
            let auto_reflect_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_reflect_count /. float_of_int interaction_points_int
            in
            let auto_plan_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_plan_count /. float_of_int interaction_points_int
            in
            let auto_compact_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_compact_count /. float_of_int interaction_points_int
            in
            let auto_handoff_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_handoff_count /. float_of_int interaction_points_int
            in
            let guardrail_stop_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !guardrail_stop_count /. float_of_int interaction_points_int
            in
            let proactive_previews = List.rev !proactive_previews_rev in
            let proactive_similarity_warn_threshold =
              float_of_env_default
                "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
                ~default:0.90
                ~min_v:0.0
                ~max_v:1.0
            in
            let proactive_similarity_window = 8 in
            let ( proactive_preview_sample_count,
                  proactive_preview_pair_count,
                  proactive_preview_similarity_avg,
                  proactive_preview_similarity_max,
                  proactive_preview_similarity_warn ) =
              proactive_preview_similarity_stats
                ~window:proactive_similarity_window
                ~warn_threshold:proactive_similarity_warn_threshold
                proactive_previews
            in
            let compaction_saved_ratio =
              if !compaction_before_tokens = 0 then 0.0 else
                float_of_int !compaction_saved_tokens /. float_of_int !compaction_before_tokens
            in
            let avg_compaction_saved_tokens =
              if !compaction_events = 0 then 0.0 else
                float_of_int !compaction_saved_tokens /. float_of_int !compaction_events
            in
            let memory_compaction_drop_ratio =
              if !memory_compaction_before_notes = 0 then 0.0
              else
                float_of_int !memory_compaction_dropped_notes
                /. float_of_int !memory_compaction_before_notes
            in
            let memory_compaction_drop_avg =
              if !memory_compaction_events = 0 then 0.0
              else
                float_of_int !memory_compaction_dropped_notes
                /. float_of_int !memory_compaction_events
            in
            let memory_failed = !memory_checks - !memory_passed in
            let memory_pass_rate =
              if !memory_checks = 0 then 0.0
              else float_of_int !memory_passed /. float_of_int !memory_checks
            in
            let memory_avg_score =
              if !memory_checks = 0 then 0.0
              else !memory_score_sum /. float_of_int !memory_checks
            in
            let memory_weather_pass_rate =
              if !memory_weather_checks = 0 then 0.0
              else
                float_of_int !memory_weather_passed
                /. float_of_int !memory_weather_checks
            in
            let repetition_risk_avg =
              if !repetition_risk_points = 0 then 0.0
              else !repetition_risk_sum /. float_of_int !repetition_risk_points
            in
            let goal_alignment_avg =
              if !goal_alignment_points = 0 then 0.0
              else !goal_alignment_sum /. float_of_int !goal_alignment_points
            in
            let response_alignment_avg =
              if !response_alignment_points = 0 then 0.0
              else !response_alignment_sum /. float_of_int !response_alignment_points
            in
            let goal_drift_avg =
              if !goal_drift_points = 0 then 0.0
              else !goal_drift_sum /. float_of_int !goal_drift_points
            in
            let top_work_kinds =
              top_counts_json ~limit:5 ~name_key:"kind" work_kind_counts
            in
            let top_models =
              top_counts_json ~limit:5 ~name_key:"model" model_counts_window
            in
            let top_tools =
              top_counts_json ~limit:5 ~name_key:"tool" tool_counts_window
            in
            let top_memory_kinds =
              top_counts_json ~limit:5 ~name_key:"kind" memory_kind_counts_window
            in
            let top_drift_reasons =
              top_counts_json ~limit:5 ~name_key:"reason" drift_reason_counts
            in
            let top_compaction_triggers =
              top_counts_json ~limit:5 ~name_key:"reason" compaction_trigger_counts
            in
            let generation_equipment =
              generation_stats
              |> Hashtbl.to_seq
              |> List.of_seq
              |> List.sort (fun (ga, _) (gb, _) -> compare ga gb)
              |> List.map (fun (generation, gs) ->
                   let memory_pass_rate_gen =
                     if gs.memory_checks = 0 then 0.0
                     else
                       float_of_int gs.memory_passed
                       /. float_of_int gs.memory_checks
                   in
                   let top_model =
                     match top_count_name_and_count gs.models with
                     | Some (name, count) ->
                         `Assoc [ ("name", `String name); ("count", `Int count) ]
                     | None -> `Null
                   in
                   let top_tool =
                     match top_count_name_and_count gs.tools with
                     | Some (name, count) ->
                         `Assoc [ ("name", `String name); ("count", `Int count) ]
                     | None -> `Null
                   in
                   `Assoc [
                     ("generation", `Int generation);
                     ("turns", `Int gs.turns);
                     ("input_tokens", `Int gs.input_tokens);
                     ("output_tokens", `Int gs.output_tokens);
                     ("total_tokens", `Int gs.total_tokens);
                     ("handoffs", `Int gs.handoffs);
                     ("compactions", `Int gs.compactions);
                     ("memory_compactions", `Int gs.memory_compactions);
                     ("memory_trimmed", `Int gs.memory_trimmed);
                     ("memory_checks", `Int gs.memory_checks);
                     ("memory_pass_rate", `Float memory_pass_rate_gen);
                     ("memory_notes", `Int gs.memory_notes);
                     ("first_ts_unix", `Float gs.first_ts);
                     ("last_ts_unix", `Float gs.last_ts);
                     ("top_model", top_model);
                     ("top_tool", top_tool);
                   ])
            in
            let summary = `Assoc [
              ("sample_points", `Int sample_points);
              ("window_sample_points", `Int sample_points);
              ("turn_points", `Int turn_points_int);
              ("window_turn_points", `Int turn_points_int);
              ("heartbeat_points", `Int !heartbeat_points);
              ("window_heartbeat_points", `Int !heartbeat_points);
              ("proactive_points", `Int proactive_points_int);
              ("window_proactive_points", `Int proactive_points_int);
              ("window_interactions", `Int interaction_points_int);
              ("window_turns", `Int turn_points_int);
              ("window_series_max_lines", `Int series_points);
              ("window_series_max_bytes", `Int metrics_window_max_bytes);
              ("primary_model", `String primary_model);
              ("handoff_count", `Int !handoff_count);
              ("compaction_events", `Int !compaction_events);
              ("compaction_before_tokens", `Int !compaction_before_tokens);
              ("compaction_saved_tokens", `Int !compaction_saved_tokens);
              ("compaction_saved_ratio", `Float compaction_saved_ratio);
              ("avg_compaction_saved_tokens", `Float avg_compaction_saved_tokens);
              ("fallback_count", `Int !fallback_count);
              ("fallback_rate", `Float fallback_rate);
              ("model_fallback_count", `Int !fallback_count);
              ("model_fallback_rate", `Float fallback_rate);
              ("model_fallback_numerator", `Int !fallback_count);
              ("model_fallback_denominator", `Int interaction_points_int);
              ("proactive_fallback_count", `Int !proactive_fallback_count);
              ("proactive_fallback_rate", `Float proactive_fallback_rate);
              ("proactive_template_fallback_count", `Int !proactive_fallback_count);
              ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
              ("proactive_template_fallback_numerator", `Int !proactive_fallback_count);
              ("proactive_template_fallback_denominator", `Int proactive_points_int);
              ("intervention_share", `Float intervention_share);
              ("intervention_per_turn", `Float intervention_per_turn);
              ("auto_reflect_count", `Int !auto_reflect_count);
              ("auto_plan_count", `Int !auto_plan_count);
              ("auto_compact_count", `Int !auto_compact_count);
              ("auto_handoff_count", `Int !auto_handoff_count);
              ("guardrail_stop_count", `Int !guardrail_stop_count);
              ("auto_reflect_rate", `Float auto_reflect_rate);
              ("auto_plan_rate", `Float auto_plan_rate);
              ("auto_compact_rate", `Float auto_compact_rate);
              ("auto_handoff_rate", `Float auto_handoff_rate);
              ("guardrail_stop_rate", `Float guardrail_stop_rate);
              ("drift_applied_count", `Int !drift_applied_count);
              ("drift_applied_rate", `Float drift_applied_rate);
              ("repetition_risk_avg", `Float repetition_risk_avg);
              ("goal_alignment_avg", `Float goal_alignment_avg);
              ("response_alignment_avg", `Float response_alignment_avg);
              ("goal_drift_avg", `Float goal_drift_avg);
              ("proactive_preview_sample_count", `Int proactive_preview_sample_count);
              ("proactive_preview_pair_count", `Int proactive_preview_pair_count);
              ("proactive_preview_similarity_avg", `Float proactive_preview_similarity_avg);
              ("proactive_preview_similarity_max", `Float proactive_preview_similarity_max);
              ("proactive_preview_similarity_warn", `Bool proactive_preview_similarity_warn);
              ("proactive_preview_similarity_method", `String "jaccard_adjacent_preview");
              ("proactive_preview_similarity_window", `Int proactive_similarity_window);
              ("tool_call_count", `Int !tool_call_count);
              ("memory_checks", `Int !memory_checks);
              ("memory_passed", `Int !memory_passed);
              ("memory_failed", `Int memory_failed);
              ("memory_pass_rate", `Float memory_pass_rate);
              ("memory_avg_score", `Float memory_avg_score);
              ("memory_threshold", `Float !memory_threshold);
              ("memory_corrections", `Int !memory_corrections);
              ("memory_correction_success", `Int !memory_correction_success);
              ("memory_notes_added", `Int !memory_notes_added);
              ("memory_compaction_events", `Int !memory_compaction_events);
              ("memory_compaction_before_notes", `Int !memory_compaction_before_notes);
              ("memory_compaction_dropped_notes", `Int !memory_compaction_dropped_notes);
              ("memory_compaction_invalid_dropped", `Int !memory_compaction_invalid_dropped);
              ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
              ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
              ("memory_weather_checks", `Int !memory_weather_checks);
              ("memory_weather_passed", `Int !memory_weather_passed);
              ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
              ("top_work_kinds", `List top_work_kinds);
              ("top_models", `List top_models);
              ("top_tools", `List top_tools);
              ("top_memory_kinds", `List top_memory_kinds);
              ("top_drift_reasons", `List top_drift_reasons);
              ("top_compaction_triggers", `List top_compaction_triggers);
              ("generation_equipment", `List generation_equipment);
            ] in
            (`List items, summary, !last_handoff, !last_compaction)
          in

          let models_resolved =
            match Tool_keeper.model_specs_of_strings m.models with
            | Error _ -> `List []
            | Ok specs ->
                `List (List.map (fun (s : Llm_client.model_spec) ->
                  `Assoc [
                    ("provider", `String (Llm_client.string_of_provider s.provider));
                    ("model_id", `String s.model_id);
                    ("max_context", `Int s.max_context);
                  ]
                ) specs)
          in

          let memory_bank_summary =
            Tool_keeper.read_keeper_memory_summary
              config
              ~name:m.name
              ~max_bytes:120000
              ~max_lines:200
              ~recent_limit:4
          in
          let memory_bank_json =
            Tool_keeper.memory_summary_to_json memory_bank_summary
          in
          let memory_recent_note =
            match memory_bank_summary.Tool_keeper.recent_notes with
            | row :: _ -> Some row.Tool_keeper.text
            | [] -> None
          in
          let history_path =
            Filename.concat
              (Filename.concat (Tool_keeper.session_base_dir config) m.trace_id)
              "history.jsonl"
          in
          let ( conversation_tail,
                k2k_recent,
                k2k_mentions,
                conversation_raw_count,
                conversation_fragment_count,
                conversation_fragment_filtered_count ) =
            keeper_history_summary_json
              ~all_keeper_names:names
              ~keeper_name:m.name
              ~history_path
              ~filter_fragments:history_fragment_filter_enabled
          in
          let conversation_tail_count =
            match conversation_tail with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let conversation_items =
            match conversation_tail with
            | `List xs -> xs
            | _ -> []
          in
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let keepalive_running =
            Tool_keeper.keeper_keepalive_running m.name
          in

          let context =
            match last_metrics with
            | Some metrics ->
                `Assoc [
                  ("source", `String "metrics");
                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
                ]
            | None ->
                (match Tool_keeper.model_specs_of_strings m.models with
                 | Error _ -> `Assoc [("has_checkpoint", `Bool false)]
                 | Ok specs ->
                     let primary =
                       match specs with m0 :: _ -> m0 | [] -> Llm_client.ollama_glm
                     in
                     let base_dir = Tool_keeper.session_base_dir config in
                     let (_session, ctx_opt) =
                       Tool_keeper.load_context_from_checkpoint
                         ~trace_id:m.trace_id
                         ~primary_model_max_tokens:primary.max_context
                         ~base_dir
                     in
                     match ctx_opt with
                     | None -> `Assoc [("has_checkpoint", `Bool false)]
                     | Some c ->
                         `Assoc [
                           ("has_checkpoint", `Bool true);
                           ("source", `String "checkpoint");
                           ("context_ratio", `Float (Context_manager.context_ratio c));
                           ("context_tokens", `Int c.token_count);
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (List.length c.messages));
                         ])
          in
	          let context_source =
	            match context with
	            | `Assoc fields ->
	                (match List.assoc_opt "source" fields with
	                 | Some s -> s
	                 | None -> `Null)
	            | _ -> `Null
	          in
	          let summary =
	            let compact_ratio_gate = m.compaction_ratio_gate in
	            let compact_message_gate = m.compaction_message_gate in
	            let compact_token_gate = m.compaction_token_gate in
              let diagnostic =
                Tool_keeper.keeper_diagnostic_json
                  ~meta:m
                  ~agent_status:agent
                  ~keepalive_running
                  ~history_items:conversation_items
                  ~now_ts
              in
              let detail_fields =
                if compact then []
                else [
                  ("last_metrics", match last_metrics with None -> `Null | Some j -> j);
                  ("metrics_series", metrics_series);
                  ("metrics_24h", metrics_24h);
                  ("memory_bank", memory_bank_json);
                  ("conversation_tail", conversation_tail);
                  ("k2k_recent", k2k_recent);
                ]
              in
	            `Assoc ([
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("emoji", `String (let (e, _) = get_agent_identity m.name in e));
              ("koreanName", `String (let (_, k) = get_agent_identity m.name in k));
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ("goal", if include_goals then `String m.goal else `Null);
              ("short_goal", if include_goals then `String m.short_goal else `Null);
              ("mid_goal", if include_goals then `String m.mid_goal else `Null);
              ("long_goal", if include_goals then `String m.long_goal else `Null);
              ( "goal_horizons",
                if include_goals then
                  `Assoc [
                    ("short", `String m.short_goal);
                    ("mid", `String m.mid_goal);
                    ("long", `String m.long_goal);
                  ]
                else
                  `Null );
              ("soul_profile", `String m.soul_profile);
              ("will", if String.trim m.will = "" then `Null else `String m.will);
              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("self_model", `Assoc [
                ("will", if String.trim m.will = "" then `Null else `String m.will);
                ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
                ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ]);
              ("models", `List (List.map (fun s -> `String s) m.models));
              ("models_resolved", models_resolved);
              ("primary_model", `String primary_model);
              ("active_model", `String active_model);
              ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
              ("presence_keepalive", `Bool m.presence_keepalive);
              ("presence_keepalive_sec", `Int m.presence_keepalive_sec);
              ("keepalive_running", `Bool keepalive_running);
              ("auto_handoff", `Bool m.auto_handoff);
              ("handoff_threshold", `Float m.handoff_threshold);
              ("agent", agent);
              ("diagnostic", diagnostic);
              ("keeper_age_s", `Float keeper_age_s);
              ("uptime_hours", `Float (keeper_age_s /. 3600.0));
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_handoff_ago_s", `Float last_handoff_ago_s);
              ("last_compaction_ago_s", `Float last_compaction_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("handoff_count_total", `Int trace_history_count);
              ("total_turns", `Int m.total_turns);
              ("total_input_tokens", `Int m.total_input_tokens);
              ("total_output_tokens", `Int m.total_output_tokens);
              ("total_tokens", `Int m.total_tokens);
              ("total_cost_usd", `Float m.total_cost_usd);
              ("last_model_used", `String m.last_model_used);
              ("last_usage", `Assoc [
                ("input_tokens", `Int m.last_input_tokens);
                ("output_tokens", `Int m.last_output_tokens);
                ("total_tokens", `Int m.last_total_tokens);
              ]);
              ("last_latency_ms", `Int m.last_latency_ms);
              ("compaction_count", `Int m.compaction_count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction_profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive_enabled);
              ("proactive_idle_sec", `Int m.proactive_idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
              ("proactive_count_total", `Int m.proactive_count_total);
              ("last_proactive_ts", `Float m.last_proactive_ts);
              ("last_proactive_reason",
                if String.trim m.last_proactive_reason = ""
                then `Null
                else `String m.last_proactive_reason);
              ("drift_enabled", `Bool m.drift_enabled);
              ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
              ("drift_count_total", `Int m.drift_count_total);
              ("last_drift_turn", `Int m.last_drift_turn);
              ("last_drift_reason",
                if String.trim m.last_drift_reason = ""
                then `Null
                else `String m.last_drift_reason);
	              ("last_proactive_preview",
	                if String.trim m.last_proactive_preview = ""
	                then `Null
	                else `String m.last_proactive_preview);
	              ("skill_primary",
	                match last_skill_primary with
	                | Some s -> `String s
	                | None -> `Null);
	              ("skill_secondary",
	                `List (List.map (fun s -> `String s) last_skill_secondary));
	              ("skill_reason",
	                match last_skill_reason with
	                | Some s -> `String s
	                | None -> `Null);
              ("metrics_window", metrics_window_summary);
              ("metrics_24h_summary", metrics_24h_summary);
              ("memory_note_count", `Int memory_bank_summary.Tool_keeper.total_notes);
              ("memory_top_kind",
                match memory_bank_summary.Tool_keeper.top_kind with
                | Some kind -> `String kind
                | None -> `Null);
              ("memory_recent_note",
                match memory_recent_note with
                | Some text -> `String text
                | None -> `Null);
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("conversation_fragment_filter_enabled", `Bool history_fragment_filter_enabled);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("last_handoff_event", match last_handoff_event with Some j -> j | None -> `Null);
              ("last_compaction_event", match last_compaction_event with Some j -> j | None -> `Null);
              ("context", context);
              ("context_source", context_source);
            ] @ detail_fields)
          in
          Some summary
    ) names
  in
  `Assoc [
    ("keepers", `List summaries);
    ("total", `Int (List.length summaries));
  ]

let perpetual_dashboard_json () : Yojson.Safe.t =
  let include_goals = bool_of_env "MASC_DASHBOARD_INCLUDE_GOALS" in
  let items =
    Hashtbl.fold (fun trace_id (state, (config : Masc_mcp.Perpetual_loop.loop_config)) acc ->
      let base = Masc_mcp.Perpetual_loop.status state in
      let with_cfg =
        match base with
        | `Assoc fields ->
              let models =
              `List (List.map (fun (m : Llm_client.model_spec) ->
                `Assoc [
                  ("provider", `String (Llm_client.string_of_provider m.provider));
                  ("model_id", `String m.model_id);
                  ("max_context", `Int m.max_context);
                ]
              ) config.model_cascade)
            in
            `Assoc ([
              ("goal", if include_goals then `String config.initial_goal else `Null);
              ("model_cascade", models);
              ("heartbeat_interval_s", `Float config.heartbeat_interval_s);
              ("compact_threshold", `Float config.compact_threshold);
              ("prepare_threshold", `Float config.prepare_threshold);
              ("handoff_threshold", `Float config.handoff_threshold);
            ] @ fields)
        | other -> other
      in
      (trace_id, with_cfg) :: acc
    ) Tool_perpetual.active_agents []
  in
  let items =
    items
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map snd
  in
  `Assoc [
    ("agents", `List items);
    ("total", `Int (List.length items));
  ]

let mdal_status_string (status : Mdal.status) : string =
  Mdal.status_to_string status

let mdal_iteration_record_json (r : Mdal.iteration_record) : Yojson.Safe.t =
  let evidence_json =
    match r.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("worker_engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("worker_model", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("evidence_status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc
    [
      ("iteration", `Int r.iteration);
      ("metric_before", `Float r.metric_before);
      ("metric_after", `Float r.metric_after);
      ("delta", `Float r.delta);
      ("changes", `String r.changes);
      ("failed_attempts", `String r.failed_attempts);
      ("next_suggestion", `String r.next_suggestion);
      ("elapsed_ms", `Int r.elapsed_ms);
      ("cost_usd", match r.cost_usd with Some c -> `Float c | None -> `Null);
      ("evidence", evidence_json);
    ]

let mdal_loop_json ~(config : Room.config) ~(history_limit : int)
    (state : Mdal.loop_state) : Yojson.Safe.t =
  let history =
    state.history
    |> take history_limit
    |> List.map mdal_iteration_record_json
  in
  let latest_evidence = Mdal.latest_evidence state in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("status", `String (mdal_status_string state.status));
      ("strict_mode", `Bool state.strict_mode);
      ("error_message",
       match state.error_message with Some msg -> `String msg | None -> `Null);
      ("error_reason",
       match state.error_message with Some msg -> `String msg | None -> `Null);
      ("stop_reason",
       match state.stop_reason with Some reason -> `String reason | None -> `Null);
      ("profile", `String state.profile.name);
      ("current_iteration", `Int state.current_iteration);
      ("max_iterations", `Int state.profile.max_iterations);
      ("baseline_metric", `Float state.baseline_metric);
      ("current_metric", `Float (Mdal.current_metric state));
      ("target", `String state.profile.target);
      ("stagnation_streak", `Int state.stagnation_streak);
      ("stagnation_limit", `Int state.profile.stagnation_count);
      ("elapsed_seconds", `Float (Masc_mcp.Time_compat.now () -. state.start_time));
      ("start_time", `String (iso8601_of_unix state.start_time));
      ("updated_at", `String (iso8601_of_unix state.updated_at));
      ("stopped_at",
       match state.stopped_at with
       | Some ts -> `String (iso8601_of_unix ts)
       | None -> `Null);
      ("execution_mode",
       `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       match state.worker_engine with
       | Some engine -> `String (Mdal.worker_engine_to_string engine)
       | None -> `Null);
      ("worker_model",
       match state.worker_model with
       | Some model -> `String model
       | None -> `Null);
      ("evidence_policy", if state.strict_mode then `String "hard" else `String "legacy");
      ("latest_tool_call_count",
       `Int
         (match latest_evidence with
          | Some evidence -> evidence.tool_call_count
          | None -> 0));
      ("latest_tool_names",
       `List
         (match latest_evidence with
          | Some evidence -> List.map (fun item -> `String item) evidence.tool_names
          | None -> []));
      ("session_id",
       match latest_evidence with
       | Some evidence -> `String evidence.session_id
       | None -> `Null);
      ("evidence_status",
       match Mdal.current_evidence_status state with
       | Some status -> `String (Mdal.evidence_status_to_string status)
       | None -> `Null);
      ("durability", `String (Masc_mcp.Mdal_store.durability config));
      ("persistence_backend", `String (Masc_mcp.Mdal_store.persistence_backend config));
      ("recoverable", `Bool (Mdal.recoverable state));
      ("history", `List history);
    ]

let parse_mdal_status_filter (raw_opt : string option) : (string option, string) result =
  match raw_opt with
  | None -> Ok None
  | Some raw ->
      let normalized = String.trim raw |> String.lowercase_ascii in
      if normalized = "" then Ok None
      else if normalized = "running"
           || normalized = "interrupted"
           || normalized = "completed"
           || normalized = "stopped"
           || normalized = "error"
      then Ok (Some normalized)
      else
        Error
          (Printf.sprintf
             "invalid status filter: %s (expected running|interrupted|completed|stopped|error)"
             raw)

let mdal_loops_json ~(config : Room.config)
    (request : Httpun.Request.t) : (Yojson.Safe.t, string) result =
  let limit = int_query_param request "limit" ~default:20 |> clamp ~min_v:1 ~max_v:100 in
  let history_limit =
    int_query_param request "history_limit" ~default:50 |> clamp ~min_v:0 ~max_v:500
  in
  match parse_mdal_status_filter (query_param request "status") with
  | Error _ as e -> e
  | Ok status_filter ->
      let loops =
        Tool_mdal.list_loops ~config ()
        |> List.filter (fun (state : Mdal.loop_state) ->
               let status = mdal_status_string state.status in
               match status_filter with
               | None -> true
               | Some expected -> String.equal expected status)
      in
      let loops =
        loops
        |> List.sort (fun (a : Mdal.loop_state) (b : Mdal.loop_state) ->
               let rank (s : Mdal.loop_state) =
                 match s.status with
                 | `Running -> 0
                 | `Interrupted -> 1
                 | _ -> 2
               in
               let by_status = Int.compare (rank a) (rank b) in
               if by_status <> 0 then by_status
               else Float.compare b.start_time a.start_time)
      in
      let total = List.length loops in
      let loops = take limit loops in
      Ok
        (`Assoc
          [
            ("loops", `List (List.map (mdal_loop_json ~config ~history_limit) loops));
            ("total", `Int total);
            ("returned", `Int (List.length loops));
            ("limit", `Int limit);
            ("history_limit", `Int history_limit);
            ("status", match status_filter with Some s -> `String s | None -> `Null);
          ])

let mdal_loops_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("error", `String msg) ]
let dashboard_batch_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let tasks = Room.get_tasks_raw config in
  let agents = Room.get_agents_raw config in
  let msgs = Room.get_messages_raw config ~since_seq:0 ~limit:20 in
  let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let now_ts = Masc_mcp.Time_compat.now () in
  let (board_monitor_json, board_contract_ok) = board_monitoring_json ~now_ts in
  let (council_monitor_json, council_feed_ok) =
    council_monitoring_json ~now_ts ~base_path:config.base_path
  in

  let proactive_fallback_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_WARN"
      ~default:0.20
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_fallback_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_BAD"
      ~default:0.40
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
      ~default:0.90
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_BAD"
      ~default:0.97
      ~min_v:0.0
      ~max_v:1.0
  in
  let alert_toast_cooldown_sec =
    int_of_env_default
      "MASC_DASHBOARD_ALERT_TOAST_COOLDOWN_SEC"
      ~default:300
      ~min_v:10
      ~max_v:86400
  in
  let status_json =
    `Assoc [
      ("room", `String room_state.project);
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("tool_call_health", tool_call_health_json config);
      ("alert_thresholds", `Assoc [
        ("proactive_fallback_warn", `Float proactive_fallback_warn);
        ("proactive_fallback_bad", `Float (max proactive_fallback_warn proactive_fallback_bad));
        ("proactive_similarity_warn", `Float proactive_similarity_warn);
        ("proactive_similarity_bad", `Float (max proactive_similarity_warn proactive_similarity_bad));
        ("toast_cooldown_sec", `Int alert_toast_cooldown_sec);
      ]);
      ("monitoring", `Assoc [
        ("board", board_monitor_json);
        ("council", council_monitor_json);
      ]);
      ("lodge", lodge_json);
      ("data_quality", `Assoc [
        ("board_contract_ok", `Bool board_contract_ok);
        ("council_feed_ok", `Bool council_feed_ok);
        ("last_sync_at", `String (Types.now_iso ()));
      ]);
    ]
  in
  let tasks_json =
    List.map (fun (t : Types.task) ->
      `Assoc [
        ("id", `String t.id);
        ("title", `String t.title);
        ("status", `String (Types.string_of_task_status t.task_status));
        ("priority", `Int t.priority);
        ("assignee",
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
             `String assignee
         | _ -> `Null);
      ]
    )
      (List.filter
         (fun (t : Types.task) ->
           match t.task_status with
           | Types.Cancelled _ -> false
           | Types.Done _ -> not compact
           | _ -> true)
         tasks)
  in
  let agents_json =
    List.map (fun (a : Types.agent) ->
      let (emoji, korean_name) = get_agent_identity a.name in
      `Assoc [
        ("name", `String a.name);
        ("status", `String (Types.string_of_agent_status a.status));
        ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
        ("last_seen", `String a.last_seen);
        ("emoji", `String emoji);
        ("koreanName", `String korean_name);
        ("generation", `Null);
        ("context_ratio", `Null);
        ("turn_count", `Null);
      ]
    ) agents
  in
  let msgs_json =
    List.map
      (fun (m : Types.message) ->
        `Assoc [
          ("from", `String m.from_agent);
          ("content", `String m.content);
          ("timestamp", `String m.timestamp);
          ("seq", `Int m.seq);
        ])
      (List.filteri (fun idx _ -> idx < 20) msgs)
  in
  `Assoc [
    ("status", status_json);
    ("tasks", `Assoc [ ("tasks", `List tasks_json); ("total", `Int (List.length tasks_json)) ]);
    ("agents", `Assoc [ ("agents", `List agents_json); ("total", `Int (List.length agents_json)) ]);
    ("messages", `Assoc [ ("messages", `List msgs_json); ("total", `Int (List.length msgs_json)) ]);
    ("keepers", keepers_dashboard_json ~compact config);
    ("perpetual", perpetual_dashboard_json ());
  ]

let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let operator_snapshot_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let include_messages =
    match query_param request "include_messages" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_sessions =
    match query_param request "include_sessions" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_keepers =
    match query_param request "include_keepers" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  Operator_control.snapshot_json ?actor:(operator_actor_hint request)
    ~include_messages ~include_sessions ~include_keepers ctx

let operator_digest_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  Operator_control.digest_json ?actor:(operator_actor_hint request)
    ?target_type ?target_id ?include_workers ctx

let dashboard_mission_http_json ~state ~sw ~clock request =
  Dashboard_mission.json ?actor:(operator_actor_hint request)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  `Assoc
    [
      ("room", `String room_state.project);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("version", `String Masc_mcp.Version.version);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("last_seen", `String agent.last_seen);
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let json_list_field key json =
  match Yojson.Safe.Util.member key json with
  | `List items -> items
  | _ -> []

let json_int_field key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with Failure _ -> default)
  | _ -> default

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)

let dashboard_agents_safe config =
  Room.get_agents_raw_in_room config (dashboard_current_room_id config)

let dashboard_messages_safe config ~since_seq ~limit =
  Room.get_messages_raw_in_room config ~room_id:(dashboard_current_room_id config) ~since_seq ~limit

let dashboard_shell_http_json (config : Room.config) : Yojson.Safe.t =
  let agents = dashboard_agents_safe config in
  let tasks = dashboard_tasks_safe config in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers_total = json_int_field "total" keepers_json ~default:0 in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int (List.length agents));
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int keepers_total);
          ] );
    ]

let dashboard_execution_http_json (config : Room.config) : Yojson.Safe.t =
  let tasks = dashboard_tasks_safe config in
  let agents = dashboard_agents_safe config in
  let messages = dashboard_messages_safe config ~since_seq:0 ~limit:50 in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers = json_list_field "keepers" keepers_json in
  let active_agents =
    List.fold_left
      (fun acc (agent : Types.agent) ->
        match agent.status with
        | Types.Active | Types.Busy | Types.Listening -> acc + 1
        | Types.Inactive -> acc)
      0 agents
  in
  let task_rollup =
    List.fold_left
      (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
        match task.task_status with
        | Todo -> (todo + 1, claimed, running, done_count, cancelled)
        | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
        | InProgress _ -> (todo, claimed, running + 1, done_count, cancelled)
        | Done _ -> (todo, claimed, running, done_count + 1, cancelled)
        | Cancelled _ -> (todo, claimed, running, done_count, cancelled + 1))
      (0, 0, 0, 0, 0) tasks
  in
  let (todo_count, claimed_count, running_count, done_count, cancelled_count) = task_rollup in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "summary",
        `Assoc
          [
            ("active_agents", `Int active_agents);
            ("todo_tasks", `Int todo_count);
            ("claimed_tasks", `Int claimed_count);
            ("running_tasks", `Int running_count);
            ("done_tasks", `Int done_count);
            ("cancelled_tasks", `Int cancelled_count);
            ("keepers", `Int (List.length keepers));
          ] );
      ("agents", `List (List.map dashboard_agent_json agents));
      ("tasks", `List (List.map dashboard_task_json tasks));
      ("messages", `List (List.map dashboard_message_json messages));
      ("keepers", `List keepers);
    ]

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
  let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
  let posts = filter_board_posts ~exclude_system posts in
  let karma_map = Board_dispatch.get_all_karma () in
  let get_karma author =
    try List.assoc author karma_map with Not_found -> 0
  in
  let paged = posts |> drop offset |> take limit in
  let posts_json =
    List.map
      (fun (post : Board.post) ->
        let author = Board.Agent_id.to_string post.author in
        board_post_dashboard_json ~author_karma:(get_karma author) post)
      paged
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("visible_posts", `Int (List.length posts_json));
            ("sort_by", `String (board_sort_label sort_by));
            ("exclude_system", `Bool exclude_system);
          ] );
      ("posts", `List posts_json);
      ("count", `Int (List.length posts_json));
      ("limit", `Int limit);
      ("offset", `Int offset);
      ("sort_by", `String (board_sort_label sort_by));
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let config = Council.make_config ~base_path in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = limit + offset in
  let status_filter =
    match query_param request "status" with
    | None -> None
    | Some raw -> (
        match String.lowercase_ascii (String.trim raw) with
        | "open" -> Some Council.Debate.Open
        | "closed" -> Some Council.Debate.Closed
        | "pending" -> Some Council.Debate.Pending
        | _ -> None)
  in
  let debates =
    Council.DebateApi.list_all ~config ~status_filter ~limit:fetch_limit ()
    |> drop offset |> take limit
    |> List.map
         (fun (debate : Council.Debate.debate) ->
           `Assoc
             [
               ("id", `String debate.id);
               ("topic", `String debate.topic);
               ("status", `String (Council.Debate.status_to_string debate.status));
               ("argument_count", `Int (List.length debate.arguments));
               ("created_at", `Float debate.created_at);
               ("created_at_iso", `String (iso8601_of_unix debate.created_at));
             ])
  in
  let sessions =
    Council.ConsensusApi.list_active () |> drop offset |> take limit
    |> List.map
         (fun (session : Council.Consensus.session) ->
           `Assoc
             [
               ("id", `String session.id);
               ("topic", `String session.topic);
               ("initiator", `String session.initiator);
               ("votes", `Int (List.length session.votes));
               ("quorum", `Int session.quorum);
               ("threshold", `Float session.threshold);
               ("state", Council.Consensus.voting_state_to_yojson session.state);
               ("created_at", `Float session.created_at);
               ("created_at_iso", `String (iso8601_of_unix session.created_at));
             ])
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("debates", `Int (List.length debates));
            ("voting_sessions", `Int (List.length sessions));
          ] );
      ("debates", `List debates);
      ("sessions", `List sessions);
    ]

let dashboard_planning_http_json request ~(config : Room.config) : Yojson.Safe.t =
  let goals = Masc_mcp.Goal_store.list_goals config () in
  let rollup = Masc_mcp.Goal_store.compute_rollup goals in
  let mdal_json =
    match mdal_loops_json ~config request with
    | Ok json -> json
    | Error message -> `Assoc [ ("error", `String message); ("loops", `List []) ]
  in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
           match task.task_status with
           | Todo -> (todo + 1, claimed, running, done_count, cancelled)
           | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
           | InProgress _ -> (todo, claimed, running + 1, done_count, cancelled)
           | Done _ -> (todo, claimed, running, done_count + 1, cancelled)
           | Cancelled _ -> (todo, claimed, running, done_count, cancelled + 1))
         (0, 0, 0, 0, 0)
  in
  let (todo_count, claimed_count, running_count, done_count, cancelled_count) = task_rollup in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("goals", `List (List.map Masc_mcp.Goal_store.goal_to_yojson goals));
      ("rollup", Masc_mcp.Goal_store.rollup_to_yojson rollup);
      ("mdal", mdal_json);
      ( "task_backlog",
        `Assoc
          [
            ("todo", `Int todo_count);
            ("claimed", `Int claimed_count);
            ("in_progress", `Int running_count);
            ("done", `Int done_count);
            ("cancelled", `Int cancelled_count);
          ] );
    ]

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]

let assoc_add key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | json -> `Assoc [ ("payload", json); (key, value) ]

let command_plane_summary_http_json ~state =
  let config = state.Mcp_server.room_config in
  let summary = Command_plane_v2.summary_json config in
  let swarm_status =
    if Room.is_initialized config then
      Masc_mcp.Swarm_status.build_json ~timeline_limit_override:6 config
    else
      Masc_mcp.Swarm_status.empty_json
  in
  summary
  |> assoc_add "swarm_status" swarm_status

let command_plane_snapshot_http_json ~state =
  let config = state.Mcp_server.room_config in
  let snapshot = Command_plane_v2.snapshot_json config in
  let swarm_status =
    if Room.is_initialized config then
      Masc_mcp.Swarm_status.build_json_from_snapshot config snapshot
    else
      Masc_mcp.Swarm_status.empty_json
  in
  snapshot
  |> assoc_add "swarm_status" swarm_status

let command_plane_topology_http_json ~state =
  Command_plane_v2.topology_json state.Mcp_server.room_config

let command_plane_units_http_json ~state =
  Command_plane_v2.list_units_json state.Mcp_server.room_config

let command_plane_operations_http_json ~state request =
  let operation_id = query_param request "operation_id" in
  Command_plane_v2.operation_status_json state.Mcp_server.room_config ?operation_id ()

let command_plane_detachments_http_json ~state request =
  let operation_id = query_param request "operation_id" in
  let detachment_id = query_param request "detachment_id" in
  Command_plane_v2.list_detachments_json state.Mcp_server.room_config ?operation_id
    ?detachment_id

let command_plane_detachment_status_http_json ~state request =
  let args =
    `Assoc
      [
        ( "detachment_id",
          match query_param request "detachment_id" with
          | Some value -> `String value
          | None -> `Null );
      ]
  in
  Command_plane_v2.detachment_status_json state.Mcp_server.room_config args

let command_plane_decisions_http_json ~state request =
  let decision_id = query_param request "decision_id" in
  Command_plane_v2.list_policy_decisions_json state.Mcp_server.room_config ?decision_id

let command_plane_capacity_http_json ~state =
  Command_plane_v2.capacity_json state.Mcp_server.room_config

let command_plane_alerts_http_json ~state =
  Command_plane_v2.list_alerts_json state.Mcp_server.room_config

let command_plane_traces_http_json ~state request =
  let operation_id = query_param request "operation_id" in
  let limit = int_query_param request "limit" ~default:25 |> clamp ~min_v:1 ~max_v:200 in
  Command_plane_v2.list_traces_json state.Mcp_server.room_config ?operation_id ~limit ()

let command_plane_swarm_http_json ~state request =
  let run_id = query_param request "run_id" in
  let operation_id = query_param request "operation_id" in
  Command_plane_v2.swarm_live_json state.Mcp_server.room_config ?run_id
    ?operation_id ()

let command_plane_actor request =
  Option.value ~default:"dashboard" (operator_actor_hint request)

(** Eio switch and clock references for MCP handlers *)
let current_sw : Eio.Switch.t option ref = ref None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None
let current_net : _ Eio.Net.t option ref = ref None

let get_switch () = match !current_sw with
  | Some s -> s
  | None -> failwith "Eio switch not initialized"

let get_clock () = match !current_clock with
  | Some c -> c
  | None -> failwith "Eio clock not initialized"

let get_net () = match !current_net with
  | Some n -> n
  | None -> failwith "Eio net not initialized"

let command_plane_tool_ctx ~state request : (_, _) Masc_mcp.Tool_command_plane.context =
  {
    config = state.Mcp_server.room_config;
    agent_name = command_plane_actor request;
    sw = Some (get_switch ());
    clock = Some (get_clock ());
    net = Some (get_net ());
    mcp_state = Some state;
    mcp_session_id = get_session_id_any request;
    auth_token = auth_token_from_request request;
  }

let tool_command_plane_http_json ~state request ~name ~args =
  match Masc_mcp.Tool_command_plane.dispatch (command_plane_tool_ctx ~state request) ~name ~args with
  | Some (true, payload) -> (
      try Ok (Yojson.Safe.from_string payload)
      with Yojson.Json_error message -> Error ("invalid tool json: " ^ message))
  | Some (false, payload) -> (
      try
        match Yojson.Safe.from_string payload with
        | `Assoc fields -> (
            match List.assoc_opt "message" fields with
            | Some (`String message) -> Error message
            | _ -> Error payload)
        | _ -> Error payload
      with Yojson.Json_error _ -> Error payload)
  | None -> Error ("unsupported command-plane tool: " ^ name)

let command_plane_unit_define_http_json ~state request ~args =
  Command_plane_v2.unit_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_operation_start_http_json ~state request ~args =
  tool_command_plane_http_json ~state request ~name:"masc_operation_start" ~args

let command_plane_chain_summary_http_json ~state request =
  tool_command_plane_http_json ~state request ~name:"masc_chain_snapshot"
    ~args:(`Assoc [])

let command_plane_chain_run_http_json ~state request run_id =
  tool_command_plane_http_json ~state request ~name:"masc_chain_run_get"
    ~args:(`Assoc [ ("run_id", `String run_id) ])

let chain_http_error_status message =
  let starts_with ~prefix value =
    let prefix_len = String.length prefix in
    String.length value >= prefix_len
    && String.equal (String.sub value 0 prefix_len) prefix
  in
  if starts_with ~prefix:"invalid chain run_id:" message then
    `Bad_request
  else if starts_with ~prefix:"chain run not found:" message then
    `Not_found
  else
    `Bad_gateway

let stream_native_chain_events_http ~request reqd =
  let origin = get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Masc_mcp.Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Printf.eprintf "[chain-sse] %s\n%!" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Masc_mcp.Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (Httpun.Body.Writer.is_closed writer) then Httpun.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || Httpun.Body.Writer.is_closed writer then
            `Closed
          else
            try
              Httpun.Body.Writer.write_string writer frame;
              Httpun.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream ~reason:(Printf.sprintf "stream write failed: %s" (Printexc.to_string exn)) ();
        false
  in
  (try
     let sub =
       Masc_mcp.Chain_telemetry.subscribe (fun event ->
           let payload =
             Masc_mcp.Chain_native_eio.chain_event_json event
             |> Yojson.Safe.to_string
           in
           let frame =
             Masc_mcp.Sse.format_event
               ~event_type:(Masc_mcp.Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s" (Printexc.to_string exn))
       ())

let proxy_chain_events_http ~request reqd =
  let endpoint = Masc_mcp.Llm_client_eio.resolve_endpoint () in
  let path = Masc_mcp.Llm_client_eio.endpoint_path endpoint "/chain/events" in
  let origin = get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let upstream_request =
    let auth_header =
      match endpoint.api_key with
      | Some value -> [ Printf.sprintf "Authorization: Bearer %s" value ]
      | None -> []
    in
    Printf.sprintf "GET %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n%s\r\n\r\n"
      path endpoint.host endpoint.port
      (String.concat "\r\n" auth_header)
  in
  Eio.Fiber.fork ~sw:(get_switch ()) (fun () ->
      let safe_close () =
        try Httpun.Body.Writer.close writer with Invalid_argument _ -> ()
      in
      let send_error message =
        (try
           let payload =
             Printf.sprintf "event: error\ndata: {\"message\":%s}\n\n"
               (Yojson.Safe.to_string (`String message))
           in
           Httpun.Body.Writer.write_string writer payload;
           Httpun.Body.Writer.flush writer ignore
         with _ -> ());
        safe_close ()
      in
      try
        Eio.Net.with_tcp_connect ~host:endpoint.host
          ~service:(string_of_int endpoint.port) (get_net ())
        @@ fun flow ->
        Eio.Flow.copy_string upstream_request flow;
        let header_buf = Buffer.create 4096 in
        let rec read_headers () =
          let chunk = Cstruct.create 2048 in
          match Eio.Flow.single_read flow chunk with
          | n ->
              Buffer.add_string header_buf (Cstruct.to_string ~len:n chunk);
              let current = Buffer.contents header_buf in
              (try
                 let idx = Str.search_forward (Str.regexp "\r\n\r\n") current 0 in
                 let headers_part = String.sub current 0 idx in
                 let body_start = idx + 4 in
                 let body_rest =
                   if body_start >= String.length current then ""
                   else
                     String.sub current body_start (String.length current - body_start)
                 in
                 Ok (headers_part, body_rest)
               with Not_found -> read_headers ())
          | exception End_of_file ->
              Error "llm-mcp closed chain/events stream before headers were received"
        in
        match read_headers () with
        | Error message -> send_error message
        | Ok (headers_part, body_rest) ->
            let status_line =
              match String.split_on_char '\n' headers_part with
              | line :: _ -> String.trim line
              | [] -> "HTTP/1.1 502 Bad Gateway"
            in
            let status_code =
              match String.split_on_char ' ' status_line with
              | _http :: code :: _ -> (try int_of_string code with _ -> 502)
              | _ -> 502
            in
            if status_code < 200 || status_code >= 300 then
              send_error
                (Printf.sprintf "llm-mcp /chain/events upstream returned %d"
                   status_code)
            else (
              if body_rest <> "" then (
                Httpun.Body.Writer.write_string writer body_rest;
                Httpun.Body.Writer.flush writer ignore);
              let rec pump () =
                let chunk = Cstruct.create 4096 in
                match Eio.Flow.single_read flow chunk with
                | n ->
                    Httpun.Body.Writer.write_string writer
                      (Cstruct.to_string ~len:n chunk);
                    Httpun.Body.Writer.flush writer ignore;
                    pump ()
                | exception End_of_file -> safe_close ()
                | exception exn -> send_error (Printexc.to_string exn)
              in
              pump ())
      with exn -> send_error (Printexc.to_string exn))

let command_plane_chain_events_http ~request reqd =
  match Masc_mcp.Tool_command_plane.chain_backend () with
  | Masc_mcp.Tool_command_plane.Native -> stream_native_chain_events_http ~request reqd
  | Masc_mcp.Tool_command_plane.Compat_llm_mcp ->
      proxy_chain_events_http ~request reqd

let stream_native_chain_events_h2 ~request h2_reqd =
  let origin = get_origin request in
  let headers =
    H2.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = H2.Response.create ~headers `OK in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let sub_ref : Masc_mcp.Chain_telemetry.subscription option ref = ref None in
  let log_chain_sse message =
    Printf.eprintf "[chain-sse/h2] %s\n%!" message
  in
  let close_stream ?reason () =
    let sub_to_remove, should_close =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          let sub = !sub_ref in
          sub_ref := None;
          if !closed then
            (sub, false)
          else (
            closed := true;
            (sub, true)))
    in
    Option.iter Masc_mcp.Chain_telemetry.unsubscribe sub_to_remove;
    if should_close then (
      Option.iter log_chain_sse reason;
      try
        if not (H2.Body.Writer.is_closed writer) then H2.Body.Writer.close writer
      with Invalid_argument _ -> ())
  in
  let send_raw frame =
    let write_result =
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          if !closed || H2.Body.Writer.is_closed writer then
            `Closed
          else
            try
              H2.Body.Writer.write_string writer frame;
              H2.Body.Writer.flush writer (fun _ -> ());
              `Sent
            with exn -> `Error exn)
    in
    match write_result with
    | `Sent -> true
    | `Closed ->
        close_stream ();
        false
    | `Error exn ->
        close_stream
          ~reason:
            (Printf.sprintf "stream write failed: %s" (Printexc.to_string exn))
          ();
        false
  in
  (try
     let sub =
       Masc_mcp.Chain_telemetry.subscribe (fun event ->
           let payload =
             Masc_mcp.Chain_native_eio.chain_event_json event
             |> Yojson.Safe.to_string
           in
           let frame =
             Masc_mcp.Sse.format_event
               ~event_type:(Masc_mcp.Chain_native_eio.chain_event_name event)
               payload
           in
           ignore (send_raw frame))
     in
     Eio.Mutex.use_rw ~protect:true mutex (fun () -> sub_ref := Some sub);
     if send_raw ": native chain stream\nretry: 3000\n\n" then
       Eio.Fiber.fork ~sw:(get_switch ()) (fun () ->
           try
             while not !closed do
               Eio.Time.sleep (get_clock ()) 30.0;
               if not (send_raw ": keepalive\n\n") then close_stream ()
             done
           with exn ->
             close_stream
               ~reason:
                 (Printf.sprintf "keepalive loop failed: %s"
                    (Printexc.to_string exn))
               ())
     else
       close_stream ~reason:"initial stream write failed" ()
   with exn ->
     close_stream
       ~reason:
         (Printf.sprintf "subscription setup failed: %s" (Printexc.to_string exn))
       ())

let proxy_chain_events_h2 ~request h2_reqd =
  let endpoint = Masc_mcp.Llm_client_eio.resolve_endpoint () in
  let path = Masc_mcp.Llm_client_eio.endpoint_path endpoint "/chain/events" in
  let origin = get_origin request in
  let headers =
    H2.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = H2.Response.create ~headers `OK in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  let upstream_request =
    let auth_header =
      match endpoint.api_key with
      | Some value -> [ Printf.sprintf "Authorization: Bearer %s" value ]
      | None -> []
    in
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n%s\r\n\r\n"
      path endpoint.host endpoint.port
      (String.concat "\r\n" auth_header)
  in
  Eio.Fiber.fork ~sw:(get_switch ()) (fun () ->
      let safe_close () =
        try H2.Body.Writer.close writer with Invalid_argument _ -> ()
      in
      let send_error message =
        (try
           let payload =
             Printf.sprintf "event: error\ndata: {\"message\":%s}\n\n"
               (Yojson.Safe.to_string (`String message))
           in
           H2.Body.Writer.write_string writer payload;
           H2.Body.Writer.flush writer ignore
         with _ -> ());
        safe_close ()
      in
      try
        Eio.Net.with_tcp_connect ~host:endpoint.host
          ~service:(string_of_int endpoint.port) (get_net ())
        @@ fun flow ->
        Eio.Flow.copy_string upstream_request flow;
        let header_buf = Buffer.create 4096 in
        let rec read_headers () =
          let chunk = Cstruct.create 2048 in
          match Eio.Flow.single_read flow chunk with
          | n ->
              Buffer.add_string header_buf (Cstruct.to_string ~len:n chunk);
              let current = Buffer.contents header_buf in
              (try
                 let idx = Str.search_forward (Str.regexp "\r\n\r\n") current 0 in
                 let headers_part = String.sub current 0 idx in
                 let body_start = idx + 4 in
                 let body_rest =
                   if body_start >= String.length current then ""
                   else
                     String.sub current body_start
                       (String.length current - body_start)
                 in
                 Ok (headers_part, body_rest)
               with Not_found -> read_headers ())
          | exception End_of_file ->
              Error "llm-mcp closed chain/events stream before headers were received"
        in
        match read_headers () with
        | Error message -> send_error message
        | Ok (headers_part, body_rest) ->
            let status_line =
              match String.split_on_char '\n' headers_part with
              | line :: _ -> String.trim line
              | [] -> "HTTP/1.1 502 Bad Gateway"
            in
            let status_code =
              match String.split_on_char ' ' status_line with
              | _http :: code :: _ -> (try int_of_string code with _ -> 502)
              | _ -> 502
            in
            if status_code < 200 || status_code >= 300 then
              send_error
                (Printf.sprintf "llm-mcp /chain/events upstream returned %d"
                   status_code)
            else (
              if String.length body_rest > 0 then (
                H2.Body.Writer.write_string writer body_rest;
                H2.Body.Writer.flush writer ignore);
              let rec pump () =
                let chunk = Cstruct.create 4096 in
                match Eio.Flow.single_read flow chunk with
                | n when n > 0 ->
                    H2.Body.Writer.write_bigstring writer
                      ~off:0 ~len:n
                      (Cstruct.to_bigarray chunk);
                    H2.Body.Writer.flush writer ignore;
                    pump ()
                | _ -> safe_close ()
                | exception End_of_file -> safe_close ()
                | exception exn -> send_error (Printexc.to_string exn)
              in
              pump ())
      with exn -> send_error (Printexc.to_string exn))

let command_plane_chain_events_h2 ~request h2_reqd =
  match Masc_mcp.Tool_command_plane.chain_backend () with
  | Masc_mcp.Tool_command_plane.Native -> stream_native_chain_events_h2 ~request h2_reqd
  | Masc_mcp.Tool_command_plane.Compat_llm_mcp ->
      proxy_chain_events_h2 ~request h2_reqd

let command_plane_operation_checkpoint_http_json ~state request ~args =
  match
    Command_plane_v2.checkpoint_operation state.Mcp_server.room_config
      ~actor:(command_plane_actor request) args
  with
  | Ok operation ->
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("result", Command_plane_v2.operation_to_json operation);
            ( "traces",
              Command_plane_v2.list_traces_json state.Mcp_server.room_config
                ~operation_id:operation.operation_id () );
          ])
  | Error message -> Error message
  | exception Invalid_argument message -> Error message

let command_plane_unit_reparent_http_json ~state request ~args =
  Command_plane_v2.unit_reparent_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_unit_reassign_http_json ~state request ~args =
  Command_plane_v2.unit_reassign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_operation_pause_http_json ~state request ~args =
  Command_plane_v2.pause_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_operation_resume_http_json ~state request ~args =
  Command_plane_v2.resume_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_operation_stop_http_json ~state request ~args =
  Command_plane_v2.stop_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_operation_finalize_http_json ~state request ~args =
  Command_plane_v2.finalize_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_dispatch_plan_http_json ~state _request ~args =
  Ok (Command_plane_v2.dispatch_plan_json state.Mcp_server.room_config args)

let command_plane_dispatch_assign_http_json ~state request ~args =
  Command_plane_v2.dispatch_assign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_dispatch_rebalance_http_json ~state request ~args =
  Command_plane_v2.dispatch_rebalance_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_dispatch_escalate_http_json ~state request ~args =
  Command_plane_v2.dispatch_escalate_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_dispatch_recall_http_json ~state request ~args =
  Command_plane_v2.dispatch_recall_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_dispatch_tick_http_json ~state request ~args =
  Command_plane_v2.dispatch_tick_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_policy_status_http_json ~state =
  Command_plane_v2.policy_status_json state.Mcp_server.room_config

let command_plane_policy_approve_http_json ~state request ~args =
  Command_plane_v2.policy_approve_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_policy_deny_http_json ~state request ~args =
  Command_plane_v2.policy_deny_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_policy_update_http_json ~state request ~args =
  Command_plane_v2.policy_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_policy_freeze_http_json ~state request ~args =
  Command_plane_v2.policy_freeze_unit_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_policy_kill_switch_http_json ~state request ~args =
  Command_plane_v2.policy_kill_switch_json state.Mcp_server.room_config
    ~actor:(command_plane_actor request) args

let command_plane_help_http_json () =
  let str_list values = `List (List.map (fun value -> `String value) values) in
  let concept ~id ~title ~summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
      ]
  in
  let step ~id ~title ~tool ~summary ~success_signals ~pitfalls =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("tool", `String tool);
        ("summary", `String summary);
        ("success_signals", str_list success_signals);
        ("pitfalls", str_list pitfalls);
      ]
  in
  let path ~id ~title ~summary ~when_to_use ~steps =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("summary", `String summary);
        ("when_to_use", `String when_to_use);
        ("steps", `List steps);
      ]
  in
  let tool_group ~id ~title ~description ~tools =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("description", `String description);
        ("tools", str_list tools);
      ]
  in
  let pitfall ~id ~title ~symptom ~why ~fix_tool ~fix_summary =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("symptom", `String symptom);
        ("why", `String why);
        ("fix_tool", `String fix_tool);
        ("fix_summary", `String fix_summary);
      ]
  in
  let example ~id ~title ~path_id ~transport ~request ~response ~notes =
    `Assoc
      [
        ("id", `String id);
        ("title", `String title);
        ("path_id", `String path_id);
        ("transport", `String transport);
        ("request", request);
        ("response", response);
        ("notes", str_list notes);
      ]
  in
  `Assoc
    [
      ("version", `String "1");
      ("generated_at", `String (Types.now_iso ()));
      ( "docs",
        `List
          [
            `Assoc
              [
                ("title", `String "Command Plane Runbook");
                ("path", `String "docs/COMMAND-PLANE-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Benchmark Runbook");
                ("path", `String "docs/BENCHMARK-RUNBOOK.md");
              ];
            `Assoc
              [
                ("title", `String "Supervisor Mode");
                ("path", `String "docs/SUPERVISOR-MODE.md");
              ];
            `Assoc
              [
                ("title", `String "Swarm Delivery Runbook");
                ("path", `String "docs/SWARM-DELIVERY-RUNBOOK.md");
              ];
          ] );
      ( "concepts",
        `List
          [
            concept ~id:"room" ~title:"Room"
              ~summary:
                "The coordination scope. In practice masc_set_room resolves to the repo-root room, not an arbitrary nested worktree.";
            concept ~id:"task" ~title:"Task"
              ~summary:
                "Backlog work item. Claiming a task does not automatically set the session current_task pointer.";
            concept ~id:"operation" ~title:"Operation"
              ~summary:
                "Managed CPv2 execution unit owned by company/platoon/squad hierarchy.";
            concept ~id:"detachment" ~title:"Detachment"
              ~summary:
                "Scheduler/runtime view of active work under an operation. Use it to inspect progress, liveness, and runtime binding.";
            concept ~id:"policy_decision" ~title:"Policy Decision"
              ~summary:
                "Pending approval item. Cross-platoon moves and disruptive actions stop here until approved or denied.";
            concept ~id:"trace" ~title:"Trace"
              ~summary:
                "End-to-end lineage of operation, checkpoint, dispatch, and policy events.";
          ] );
      ( "golden_paths",
        `List
          [
            path ~id:"room_task_hygiene" ~title:"Room / Task Hygiene"
              ~summary:
                "Minimal MCP sequence before doing any real work in a room."
              ~when_to_use:
                "Use this before benchmark runs, CPv2 experiments, or ordinary implementation work."
              ~steps:
                [
                  step ~id:"join" ~title:"Join the room" ~tool:"masc_join"
                    ~summary:
                      "Register agent identity and capabilities in the repo-root room."
                    ~success_signals:
                      [ "agent visible in masc_status"; "room agent roster includes your agent" ]
                    ~pitfalls:
                      [ "masc_set_room points at repo root semantics"; "without join you are invisible to scheduling" ];
                  step ~id:"claim" ~title:"Claim or create work" ~tool:"masc_claim"
                    ~summary:
                      "Claim an existing task or create one first with masc_add_task when the backlog is empty."
                    ~success_signals:
                      [ "task assignee is your agent"; "task status becomes claimed/in_progress" ]
                    ~pitfalls:
                      [ "claiming alone does not set current_task" ];
                  step ~id:"set-task" ~title:"Bind current task" ~tool:"masc_plan_set_task"
                    ~summary:
                      "Set the current session task pointer so later planning and logs target the correct task."
                    ~success_signals:
                      [ "masc_plan_get_task returns the claimed task id" ]
                    ~pitfalls:
                      [ "dashboard can show claimed task and missing current_task at the same time" ];
                  step ~id:"heartbeat" ~title:"Refresh presence" ~tool:"masc_heartbeat"
                    ~summary:
                      "Update liveness before or during long-running work."
                    ~success_signals:
                      [ "agent status stays active/busy"; "last_seen remains fresh" ]
                    ~pitfalls:
                      [ "without heartbeat an otherwise healthy agent looks zombie/stale" ];
                ];
            path ~id:"cpv2_benchmark" ~title:"CPv2 Benchmark / Swarm"
              ~summary:
                "Canonical benchmark path for company → platoon → squad → agent orchestration."
              ~when_to_use:
                "Use this for real swarm experiments, benchmarking, long-running command-plane work, and 4→16→64 agent rehearsals."
              ~steps:
                [
                  step ~id:"define-units" ~title:"Define hierarchy" ~tool:"masc_unit_define"
                    ~summary:
                      "Create managed company/platoon/squad/agent units with policy and budget envelopes."
                    ~success_signals:
                      [ "masc_observe_topology shows managed units"; "capacity rows appear for units" ]
                    ~pitfalls:
                      [ "missing leaders or empty live rosters block operation start" ];
                  step ~id:"start-operation" ~title:"Start operation" ~tool:"masc_operation_start"
                    ~summary:
                      "Create the managed benchmark operation and bind it to the target unit."
                    ~success_signals:
                      [ "operation appears in masc_observe_operations"; "trace_id is issued" ]
                    ~pitfalls:
                      [ "starting directly on a frozen or killed unit fails" ];
                  step ~id:"dispatch" ~title:"Materialize detachments" ~tool:"masc_dispatch_tick"
                    ~summary:
                      "Run the scheduler/reconciler to create or update detachments."
                    ~success_signals:
                      [ "masc_detachment_list returns active detachments"; "operation moves from planned to active runtime" ]
                    ~pitfalls:
                      [ "active op with zero detachments usually means tick has not been run yet" ];
                  step ~id:"observe" ~title:"Observe runtime" ~tool:"masc_detachment_status"
                    ~summary:
                      "Inspect detachments, topology, alerts, and trace events while the operation runs."
                    ~success_signals:
                      [ "heartbeat_deadline and last_progress_at advance"; "alerts/traces explain stalls or approvals" ]
                    ~pitfalls:
                      [ "pending approvals stop cross-platoon movement until policy action happens" ];
                  step ~id:"approve" ~title:"Handle approval queue" ~tool:"masc_policy_approve"
                    ~summary:
                      "Approve or deny pending policy decisions for strict actions."
                    ~success_signals:
                      [ "decision leaves pending state"; "next tick applies the move or leaves a denial trace" ]
                    ~pitfalls:
                      [ "dispatch_rebalance can legitimately return pending_approval" ];
                  step ~id:"checkpoint" ~title:"Checkpoint and finalize" ~tool:"masc_operation_checkpoint"
                    ~summary:
                      "Record durable state, then finish with masc_operation_finalize when done."
                    ~success_signals:
                      [ "checkpoint_ref stored on operation"; "finalized operation is completed in operations view" ]
                    ~pitfalls:
                      [ "stop/finalize without checkpoint loses resume breadcrumbs" ];
                ];
            path ~id:"supervisor_session" ~title:"Supervisor / Team Session"
              ~summary:
                "Guided intervention loop for supervised implementation sessions."
              ~when_to_use:
                "Use this when a human or supervisor agent steers a team session instead of running direct CPv2 benchmark orchestration."
              ~steps:
                [
                  step ~id:"snapshot" ~title:"Read operator snapshot" ~tool:"masc_operator_snapshot"
                    ~summary:"Read state first from the small operator surface."
                    ~success_signals:[ "summary/full snapshot available" ]
                    ~pitfalls:[ "this is not the benchmark canonical path" ];
                  step ~id:"intervene" ~title:"Preview intervention" ~tool:"masc_operator_action"
                    ~summary:"Prepare a small intervention such as team_note or team_task_inject."
                    ~success_signals:[ "preview token or immediate action result returned" ]
                    ~pitfalls:[ "disruptive actions require confirm" ];
                  step ~id:"confirm" ~title:"Confirm disruptive action" ~tool:"masc_operator_confirm"
                    ~summary:"Execute the previewed intervention once a human approves it."
                    ~success_signals:[ "intervention trace appended"; "team-session reflects the change" ]
                    ~pitfalls:[ "do not mix this path with CPv2 benchmark commands in the same explanation" ];
                ];
          ] );
      ( "tool_groups",
        `List
          [
            tool_group ~id:"room-task" ~title:"Room / Task Hygiene"
              ~description:
                "Core room/task tools every session should use before higher-level workflows."
              ~tools:
                [ "masc_set_room"; "masc_join"; "masc_status"; "masc_claim"; "masc_plan_set_task"; "masc_heartbeat" ];
            tool_group ~id:"cpv2-core" ~title:"CPv2 Benchmark Core"
              ~description:
                "Canonical swarm/benchmark tool family."
              ~tools:
                [ "masc_unit_define"; "masc_operation_start"; "masc_dispatch_tick"; "masc_detachment_list"; "masc_detachment_status"; "masc_observe_topology"; "masc_observe_operations"; "masc_observe_alerts"; "masc_observe_traces"; "masc_policy_status"; "masc_policy_approve"; "masc_policy_deny"; "masc_operation_checkpoint"; "masc_operation_finalize" ];
            tool_group ~id:"supervisor" ~title:"Supervisor Session"
              ~description:
                "Small operator loop for intervention-oriented sessions."
              ~tools:
                [ "masc_operator_snapshot"; "masc_operator_action"; "masc_operator_confirm"; "masc_team_session_events" ];
          ] );
      ( "pitfalls",
        `List
          [
            pitfall ~id:"repo-root-room" ~title:"Room path resolves to repo root"
              ~symptom:"You point masc_set_room at a worktree but the room still behaves like the repo root."
              ~why:"Room semantics are repo-root scoped; worktrees share the same room substrate."
              ~fix_tool:"masc_join"
              ~fix_summary:"Treat worktrees as code-isolation only. Join the repo-root room and reason about shared room state.";
            pitfall ~id:"claimed-not-current" ~title:"Claimed task is not current task"
              ~symptom:"Task is claimed, but planning/log tools still act like no current task is selected."
              ~why:"Claim mutates backlog ownership; it does not set the session current_task pointer."
              ~fix_tool:"masc_plan_set_task"
              ~fix_summary:"Call masc_plan_set_task immediately after claiming the task.";
            pitfall ~id:"heartbeat-stale" ~title:"Agent looks stale"
              ~symptom:"Your agent appears inactive/zombie during long work even though the process is alive."
              ~why:"Heartbeat/liveness was not refreshed recently."
              ~fix_tool:"masc_heartbeat"
              ~fix_summary:"Call masc_heartbeat periodically during long operations or before observing state.";
            pitfall ~id:"no-detachments" ~title:"Operation exists but no detachments"
              ~symptom:"Operation is visible, but detachments list is empty."
              ~why:"The scheduler has not reconciled yet, or the target unit is blocked."
              ~fix_tool:"masc_dispatch_tick"
              ~fix_summary:"Run masc_dispatch_tick, then inspect topology/capacity or policy queue if detachments still do not appear.";
            pitfall ~id:"pending-approval" ~title:"Dispatch is blocked by approval"
              ~symptom:"dispatch_rebalance or related control action returns pending_approval."
              ~why:"Strict cross-platoon or disruptive action requires a policy decision."
              ~fix_tool:"masc_policy_approve"
              ~fix_summary:"Review the pending decision and approve/deny it before running tick again.";
            pitfall ~id:"http-actor-defaults-dashboard"
              ~title:"HTTP actor defaults to dashboard"
              ~symptom:"Operation or trace entries show actor=dashboard even though a human or agent initiated the request."
              ~why:"Mutating HTTP endpoints use dashboard as the fallback actor unless x-masc-agent, x-masc-agent-name, or agent_name is provided."
              ~fix_tool:"masc_operation_start"
              ~fix_summary:"Send x-masc-agent-name (or x-masc-agent) on mutating HTTP requests when actor attribution matters.";
          ] );
      ( "examples",
        `List
          [
            example ~id:"join-room" ~title:"Join room for task hygiene"
              ~path_id:"room_task_hygiene" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_join");
                     ("arguments",
                      `Assoc
                        [
                          ("agent_name", `String "codex");
                          ("capabilities",
                           `List [ `String "ocaml"; `String "dashboard"; `String "documentation" ]);
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("agent", `String "codex-...");
                     ("status", `String "joined");
                     ("room", `String "repo-root room");
                   ])
              ~notes:
                [ "Response is trimmed to canonical fields."; "Use masc_status next to confirm visibility." ];
            example ~id:"start-op" ~title:"Start benchmark operation"
              ~path_id:"cpv2_benchmark" ~transport:"http"
              ~request:
                (`Assoc
                   [
                     ("method", `String "POST");
                     ("path", `String "/api/v1/command-plane/operations");
                     ("headers", `Assoc [ ("x-masc-agent-name", `String "codex") ]);
                     ("body",
                      `Assoc
                        [
                          ("assigned_unit_id", `String "squad-research-normalize");
                          ("objective", `String "Normalize and verify latest AI research items");
                          ("autonomy_level", `String "L4_Autonomous");
                          ("policy_class", `String "guarded");
                        ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("result",
                      `Assoc
                        [
                          ("operation_id", `String "op-...");
                          ("trace_id", `String "trace-...");
                          ("status", `String "active");
                        ]);
                   ])
              ~notes:
                [
                  "Run dispatch/tick after operation start to materialize detachments.";
                  "Without x-masc-agent-name (or x-masc-agent), actor attribution falls back to dashboard.";
                ];
            example ~id:"approval" ~title:"Approve strict action"
              ~path_id:"cpv2_benchmark" ~transport:"mcp"
              ~request:
                (`Assoc
                   [
                     ("tool", `String "masc_policy_approve");
                     ("arguments",
                      `Assoc [ ("decision_id", `String "decision-...") ]);
                   ])
              ~response:
                (`Assoc
                   [
                     ("status", `String "ok");
                     ("decision_id", `String "decision-...");
                     ("approval_state", `String "approved");
                   ])
              ~notes:
                [ "Follow with masc_dispatch_tick to apply the approved move." ];
          ] );
    ]

let command_plane_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
let parse_host_port host_header default_host default_port =
  match host_header with
  | None -> (default_host, default_port)
  | Some host_value ->
      (match String.split_on_char ':' host_value with
       | [host] -> (host, default_port)
       | host :: port_str :: _ ->
           let port = try int_of_string port_str with Failure _ -> default_port in
           (host, port)
       | _ -> (default_host, default_port))

(** Utility: string prefix check *)
let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(** Allowed origins for DNS rebinding protection *)
let allowed_origins = [
  "http://localhost";
  "https://localhost";
  "http://127.0.0.1";
  "https://127.0.0.1";
  (* Cloudflare tunnel *)
  "https://masc.crying.pictures";
]

(** Validate Origin header for DNS rebinding protection *)
let validate_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "origin" with
  | None -> true
  | Some origin ->
      List.exists (fun prefix -> starts_with ~prefix origin) allowed_origins

(** Check if client accepts SSE *)
let accepts_sse (request : Httpun.Request.t) =
  Http_negotiation.accepts_sse_header
    (Httpun.Headers.get request.headers "accept")

(** Check if client accepts MCP Streamable HTTP (JSON + SSE) *)
let accepts_streamable_mcp (request : Httpun.Request.t) =
  Http_negotiation.accepts_streamable_mcp
    (Httpun.Headers.get request.headers "accept")

let env_flag name =
  match Sys.getenv_opt name with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | _ -> false)
  | None -> false

let header_truthy_value value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> true
  | _ -> false

let request_force_json_response (request : Httpun.Request.t) =
  match get_header_any_case request.headers "x-masc-force-json" with
  | Some value -> header_truthy_value value
  | None -> false

(** Compatibility mode for legacy Accept headers (default: strict off). *)
let allow_legacy_accept = env_flag "MASC_ALLOW_LEGACY_ACCEPT"

let classify_mcp_accept (request : Httpun.Request.t) =
  Http_negotiation.classify_mcp_accept ~allow_legacy:allow_legacy_accept
    (Httpun.Headers.get request.headers "accept")

(** Warning headers when a non-streamable Accept header is temporarily accepted. *)
let legacy_accept_warning_headers = function
  | Http_negotiation.Legacy_accepted ->
      [
        ( "warning",
          "299 - \"Legacy Accept is deprecated; use 'application/json, text/event-stream'\"" );
        ("x-masc-legacy-accept", "1");
      ]
  | Http_negotiation.Streamable | Http_negotiation.Rejected -> []

(** Deprecation headers for legacy SSE endpoints (/sse, /messages). *)
let legacy_transport_deprecation_headers =
  [
    ("deprecation", "true");
    ( "warning",
      "299 - \"Legacy SSE endpoints (/sse,/messages) are deprecated; use /mcp\"" );
    ("link", "</mcp>; rel=\"successor-version\"");
  ]

(** Force JSON responses for POST /mcp (compatibility fallback). *)
let force_json_response =
  env_flag "MASC_FORCE_JSON_RESPONSE" || env_flag "MCP_FORCE_JSON_RESPONSE"

(** SSE retry interval in milliseconds (for connection closure) *)
let sse_retry_ms = 3000

(** Format SSE priming event (id + retry, no data payload). *)
let sse_prime_event () =
  let id = Sse.next_id () in
  Printf.sprintf "retry: %d\nid: %d\n\n" sse_retry_ms id

(** SSE keep-alive ping interval in seconds *)
let sse_ping_interval_s = 30.0

let env_float_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      (try float_of_string raw with _ -> default)

let env_int_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      (try int_of_string raw with _ -> default)

(** SSE reconnect guard (disabled by default unless env is set). *)
let sse_reconnect_min_interval_s =
  env_float_or ~name:"MASC_SSE_RECONNECT_MIN_INTERVAL_S" ~default:0.0
  |> Float.max 0.0

let sse_connect_window_s =
  env_float_or ~name:"MASC_SSE_CONNECT_WINDOW_S" ~default:0.0
  |> Float.max 0.0

let sse_connect_max_in_window =
  env_int_or ~name:"MASC_SSE_CONNECT_MAX_IN_WINDOW" ~default:0
  |> max 0

(** Get Last-Event-ID from headers for resumability *)
let get_last_event_id (request : Httpun.Request.t) =
  match Httpun.Headers.get request.headers "last-event-id" with
  | Some id -> (try Some (int_of_string id) with Failure _ -> None)
  | None -> None


(** Common MCP headers *)
let mcp_headers session_id protocol_version = [
  ("mcp-session-id", session_id);
  ("mcp-protocol-version", protocol_version);
]

let session_cookie_header session_id =
  ("set-cookie",
   Printf.sprintf "mcp-session-id=%s; Path=/; Max-Age=86400; SameSite=Lax" session_id)

(** SSE response headers *)
let sse_headers session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ cors_headers origin

(** SSE stream headers (with keep-alive) *)
let sse_stream_headers session_id protocol_version origin =
  [
    ("content-type", Http_negotiation.sse_content_type);
    ("cache-control", "no-cache");
    ("connection", "keep-alive");
    session_cookie_header session_id;
  ]
  @ mcp_headers session_id protocol_version
  @ cors_headers origin

(** JSON response headers *)
let json_headers session_id protocol_version origin =
  [("content-type", "application/json")]
  @ mcp_headers session_id protocol_version
  @ cors_headers origin

let respond_mcp_auth_error ?(extra_headers = []) request reqd ~session_id
    ~protocol_version msg =
  let origin = get_origin request in
  let body = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("error", `Assoc [
      ("code", `Int (-32001));
      ("message", `String msg);
    ]);
  ]) in
  let headers =
    Httpun.Headers.of_list
      ((("content-length", string_of_int (String.length body))
       :: ("www-authenticate", "Bearer")
       :: extra_headers)
      @ json_headers session_id protocol_version origin)
  in
  let response = Httpun.Response.create ~headers `Unauthorized in
  Httpun.Reqd.respond_with_string reqd response body

(** GraphQL response headers *)
let graphql_headers origin =
  [("content-type", "application/json")]
  @ cors_headers origin

(** GraphQL Playground HTML (GET /graphql) *)
let graphql_playground_html ~nonce =
  String.concat "" [
    {|
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="user-scalable=no,initial-scale=1,minimum-scale=1,maximum-scale=1" />
    <title>MASC GraphQL Playground</title>
    <link rel="stylesheet" href="/static/css/middleware.css" />
  </head>
  <body>
    <style>
      html { font-family: "Open Sans", sans-serif; overflow: hidden; }
      body { margin: 0; background: #172a3a; }
      .playgroundIn { animation: playgroundIn .5s ease-out forwards; }
      @keyframes playgroundIn {
        from { opacity: 0; transform: translateY(10px); }
        to { opacity: 1; transform: translateY(0); }
      }
    </style>
    <style>
      .fadeOut { animation: fadeOut .5s ease-out forwards; }
      @keyframes fadeIn {
        from { opacity: 0; transform: translateY(-10px); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes fadeOut {
        from { opacity: 1; transform: translateY(0); }
        to { opacity: 0; transform: translateY(-10px); }
      }
      @keyframes appearIn {
        from { opacity: 0; transform: translateY(0); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes scaleIn {
        from { transform: scale(0); }
        to { transform: scale(1); }
      }
      @keyframes innerDrawIn {
        0% { stroke-dashoffset: 70; }
        50% { stroke-dashoffset: 140; }
        100% { stroke-dashoffset: 210; }
      }
      @keyframes outerDrawIn {
        0% { stroke-dashoffset: 76; }
        100% { stroke-dashoffset: 152; }
      }
      #loading-wrapper {
        position: absolute;
        width: 100vw;
        height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-direction: column;
      }
      .logo {
        width: 75px;
        height: 75px;
        margin-bottom: 20px;
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text {
        font-size: 32px;
        font-weight: 200;
        text-align: center;
        color: rgba(255, 255, 255, .6);
        opacity: 0;
        animation: fadeIn .5s ease-out forwards;
      }
      .text strong { font-weight: 400; }
    </style>
    <div id="loading-wrapper">
      <svg class="logo" viewBox="0 0 128 128" xmlns:xlink="http://www.w3.org/1999/xlink">
        <title>GraphQL Playground Logo</title>
        <defs>
          <linearGradient id="linearGradient-1" x1="4.86%" x2="96.21%" y1="0%" y2="99.66%">
            <stop stop-color="#E00082" stop-opacity=".8" offset="0%"></stop>
            <stop stop-color="#E00082" offset="100%"></stop>
          </linearGradient>
        </defs>
        <g>
          <rect id="Gradient" width="127.96" height="127.96" y="1" fill="url(#linearGradient-1)" rx="4"></rect>
          <path id="Border" fill="#E00082" fill-rule="nonzero" d="M4.7 2.84c-1.58 0-2.86 1.28-2.86 2.85v116.57c0 1.57 1.28 2.84 2.85 2.84h116.57c1.57 0 2.84-1.26 2.84-2.83V5.67c0-1.55-1.26-2.83-2.83-2.83H4.67zM4.7 0h116.58c3.14 0 5.68 2.55 5.68 5.7v116.58c0 3.14-2.54 5.68-5.68 5.68H4.68c-3.13 0-5.68-2.54-5.68-5.68V5.68C-1 2.56 1.55 0 4.7 0z"></path>
          <path class="bglIGM" x="64" y="28" fill="#fff" d="M64 36c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8"></path>
          <path class="ksxRII" x="95.98500061035156" y="46.510000228881836" fill="#fff" d="M89.04 50.52c-2.2-3.84-.9-8.73 2.94-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.76.9-10.97-2.94"></path>
          <path class="cWrBmb" x="95.97162628173828" y="83.4900016784668" fill="#fff" d="M102.9 87.5c-2.2 3.84-7.1 5.15-10.94 2.94-3.84-2.2-5.14-7.12-2.94-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.86 2.23 5.16 7.12 2.94 10.96"></path>
          <path class="Wnusb" x="64" y="101.97999572753906" fill="#fff" d="M64 110c-4.43 0-8-3.6-8-8.02 0-4.44 3.57-8.02 8-8.02s8 3.58 8 8.02c0 4.4-3.57 8.02-8 8.02"></path>
          <path class="bfPqf" x="32.03982162475586" y="83.4900016784668" fill="#fff" d="M25.1 87.5c-2.2-3.84-.9-8.73 2.93-10.96 3.83-2.2 8.72-.9 10.95 2.94 2.2 3.84.9 8.73-2.94 10.96-3.85 2.2-8.74.9-10.95-2.94"></path>
          <path class="edRCTN" x="32.033552169799805" y="46.510000228881836" fill="#fff" d="M38.96 50.52c-2.2 3.84-7.12 5.15-10.95 2.94-3.82-2.2-5.12-7.12-2.92-10.96 2.2-3.84 7.12-5.15 10.95-2.94 3.83 2.23 5.14 7.12 2.94 10.96"></path>
          <path class="iEGVWn" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M63.55 27.5l32.9 19-32.9-19z"></path>
          <path class="bsocdx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96 46v38-38z"></path>
          <path class="jAZXmP" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M96.45 84.5l-32.9 19 32.9-19z"></path>
          <path class="hSeArx" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M64.45 103.5l-32.9-19 32.9 19z"></path>
          <path class="bVgqGk" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M32 84V46v38z"></path>
          <path class="hEFqBt" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" d="M31.55 46.5l32.9-19-32.9 19z"></path>
          <path class="dzEKCM" id="Triangle-Bottom" stroke="#fff" stroke-width="4" d="M30 84h70" stroke-linecap="round"></path>
          <path class="DYnPx" id="Triangle-Left" stroke="#fff" stroke-width="4" d="M65 26L30 87" stroke-linecap="round"></path>
          <path class="hjPEAQ" id="Triangle-Right" stroke="#fff" stroke-width="4" d="M98 87L63 26" stroke-linecap="round"></path>
        </g>
      </svg>
      <div class="text">Loading <strong>GraphQL Playground</strong></div>
    </div>
    <div id="root"></div>
    <script nonce="|};
    nonce;
    {|">
      window.addEventListener("load", function () {
        var loading = document.getElementById("loading-wrapper");
        if (loading) {
          loading.classList.add("fadeOut");
        }
        var root = document.getElementById("root");
        if (!root) {
          return;
        }
        root.classList.add("playgroundIn");
        GraphQLPlayground.init(root, {
          endpoint: "/graphql",
          settings: { "request.credentials": "same-origin" }
        });
      });
    </script>
    <script src="/static/js/middleware.js"></script>
  </body>
</html>
|};
  ]

let graphql_csp_header nonce =
  Printf.sprintf
    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; \
     connect-src 'self'; img-src 'self' data:; \
     script-src 'self' 'nonce-%s' 'unsafe-eval'; \
     style-src 'self' 'unsafe-inline'; \
     font-src 'self' data:; \
     worker-src 'self' blob:"
    nonce

(** Resolve assets root *)
let assets_root () =
  let is_dir path =
    Sys.file_exists path && Sys.is_directory path
  in
  let exe_assets =
    let exe_dir = Filename.dirname Sys.executable_name in
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "assets"
  in
  let env_assets =
    match Sys.getenv_opt "MASC_ASSETS_ROOT" with
    | Some path when String.trim path <> "" -> Some path
    | _ -> Sys.getenv_opt "MASC_ASSETS_DIR"
  in
  match env_assets with
  | Some path when is_dir path -> path
  | _ when is_dir (Filename.concat (Sys.getcwd ()) "assets") ->
      Filename.concat (Sys.getcwd ()) "assets"
  | _ when is_dir exe_assets -> exe_assets
  | _ -> Filename.concat (Sys.getcwd ()) "assets"

(** Local GraphiQL assets *)
let graphiql_asset_root () =
  Filename.concat (assets_root ()) "graphiql"

let graphiql_asset_path name =
  Filename.concat (graphiql_asset_root ()) name

let asset_content_type name =
  if Filename.check_suffix name ".css" then
    "text/css; charset=utf-8"
  else if Filename.check_suffix name ".js" then
    "application/javascript; charset=utf-8"
  else if Filename.check_suffix name ".html" then
    "text/html; charset=utf-8"
  else if Filename.check_suffix name ".svg" then
    "image/svg+xml"
  else if Filename.check_suffix name ".png" then
    "image/png"
  else if Filename.check_suffix name ".jpg" || Filename.check_suffix name ".jpeg" then
    "image/jpeg"
  else if Filename.check_suffix name ".webp" then
    "image/webp"
  else if Filename.check_suffix name ".json" then
    "application/json"
  else if Filename.check_suffix name ".woff2" then
    "font/woff2"
  else if Filename.check_suffix name ".map" then
    "application/json"
  else
    "application/octet-stream"

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with exn -> Error (Printexc.to_string exn)

let serve_graphiql_asset name _request reqd =
  let path = graphiql_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Local GraphQL Playground assets *)
let playground_asset_root () =
  Filename.concat (assets_root ()) "playground"

let playground_asset_path name =
  Filename.concat (playground_asset_root ()) name

let serve_playground_asset name _request reqd =
  let path = playground_asset_path name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

(** Dashboard SPA assets (Preact + HTM, built by Vite) *)
let dashboard_asset_root () =
  Filename.concat (assets_root ()) "dashboard"

let dashboard_index_path () =
  Filename.concat (dashboard_asset_root ()) "index.html"

let dashboard_etag () =
  try
    let st = Unix.stat (dashboard_index_path ()) in
    let hash =
      Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex
    in
    String.sub hash 0 12
  with _ -> "none"

let dashboard_index_cache_control = "no-store, max-age=0, must-revalidate"

let serve_dashboard_index request reqd =
  match read_file (dashboard_index_path ()) with
  | Ok body ->
      Http.Response.html_cached
        ~etag:(dashboard_etag ())
        ~request body reqd
  | Error _ ->
      Http.Response.html
        "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>"
        reqd

let serve_dashboard_static name _request reqd =
  let path = Filename.concat (dashboard_asset_root ()) name in
  match read_file path with
  | Ok body ->
      Http.Response.bytes ~content_type:(asset_content_type name) body reqd
  | Error _ ->
      Http.Response.not_found reqd

let favicon_svg = {|
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#0f172a"/>
  <circle cx="32" cy="32" r="18" fill="#1d4ed8"/>
  <path d="M22 42 L32 18 L42 42 Z" fill="#93c5fd"/>
</svg>
|}

let serve_favicon _request reqd =
  Http.Response.bytes ~content_type:"image/svg+xml" favicon_svg reqd

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"
  && path <> "/dashboard/lodge"

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ]

(** JSON-RPC error response helper *)
let json_rpc_error code message =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    code
    (String.escaped message)

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) ->
            (match List.assoc_opt "code" err_fields with
             | Some (`Int c) -> Some c
             | _ -> None)
        | _ -> None
      in
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

(** Server start time for uptime calculation *)
let server_start_time = Unix.gettimeofday ()

(** Health check handler *)
let health_handler _request reqd =
  let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
  let uptime_str =
    if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
    else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
    else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
  in
  let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let guardian_json = Masc_mcp.Guardian.status_json () in
  let health_json = `Assoc [
    ("status", `String "ok");
    ("server", `String "masc-mcp");
    ("version", `String Masc_mcp.Version.version);
    ("release_version", `String Masc_mcp.Version.version);
    ( "protocol",
      `Assoc
        [
          ("default", `String mcp_protocol_version_default);
          ( "supported",
            `List (List.map (fun v -> `String v) mcp_protocol_versions) );
        ] );
    ( "transport",
      `Assoc
        [
          ("streamable_http_default", `Bool true);
          ("allow_legacy_accept", `Bool allow_legacy_accept);
          ("legacy_endpoints_deprecated", `Bool true);
        ] );
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Masc_mcp.Sse.client_count ()));
    ("lodge", lodge_json);
    ("guardian", guardian_json);
  ] in
  Http.Response.json (Yojson.Safe.to_string health_json) reqd

let board_post_detail_json ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error _ ->
      (`Not_found, {|{"error":"Post not found"}|})
  | Ok post ->
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~agent_name:author in
      let comments =
        match Board_dispatch.get_comments ~post_id with
        | Ok cs -> cs
        | Error _ -> []
      in
      let post_json = board_post_dashboard_json ~author_karma post in
      let comments_json = `List (List.map Board.comment_to_yojson comments) in
      let json =
        if String.equal (String.lowercase_ascii (String.trim response_format)) "flat" then
          match post_json with
          | `Assoc fields -> `Assoc (fields @ [ ("comments", comments_json) ])
          | _ -> `Assoc [ ("post", post_json); ("comments", comments_json) ]
        else
          `Assoc [ ("post", post_json); ("comments", comments_json) ]
      in
      (`OK, Yojson.Safe.to_string json)

let debate_status_filter_of_request request =
  match query_param request "status" with
  | None -> None
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "open" -> Some Council.Debate.Open
      | "closed" -> Some Council.Debate.Closed
      | "pending" -> Some Council.Debate.Pending
      | _ -> None)

let council_debates_json request ~base_path =
  let config = Council.make_config ~base_path in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = limit + offset in
  let status_filter = debate_status_filter_of_request request in
  let debates = Council.DebateApi.list_all ~config ~status_filter ~limit:fetch_limit () in
  let paged = debates |> drop offset |> take limit in
  let items =
    List.map
      (fun (d : Council.Debate.debate) ->
        `Assoc
          [
            ("id", `String d.id);
            ("topic", `String d.topic);
            ("status", `String (Council.Debate.status_to_string d.status));
            ("argument_count", `Int (List.length d.arguments));
            ("created_at", `Float d.created_at);
            ("created_at_iso", `String (iso8601_of_unix d.created_at));
          ])
      paged
  in
  `Assoc
    [
      ("debates", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_sessions_json request =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let sessions = Council.ConsensusApi.list_active () |> drop offset |> take limit in
  let items =
    List.map
      (fun (s : Council.Consensus.session) ->
        `Assoc
          [
            ("id", `String s.id);
            ("topic", `String s.topic);
            ("initiator", `String s.initiator);
            ("votes", `Int (List.length s.votes));
            ("quorum", `Int s.quorum);
            ("threshold", `Float s.threshold);
            ("state", Council.Consensus.voting_state_to_yojson s.state);
            ("created_at", `Float s.created_at);
            ("created_at_iso", `String (iso8601_of_unix s.created_at));
          ])
      sessions
  in
  `Assoc
    [
      ("sessions", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_debate_summary_json ~base_path ~debate_id =
  let config = Council.make_config ~base_path in
  match Council.DebateApi.status ~config ~debate_id with
  | Error _ ->
      (`Not_found, `Assoc [ ("error", `String "Debate not found") ])
  | Ok (summary : Council.Debate.debate_summary) ->
      let d : Council.Debate.debate = summary.debate in
      let json =
        `Assoc
          [
            ("id", `String d.id);
            ("topic", `String d.topic);
            ("status", `String (Council.Debate.status_to_string d.status));
            ("support_count", `Int summary.support_count);
            ("oppose_count", `Int summary.oppose_count);
            ("neutral_count", `Int summary.neutral_count);
            ("total_arguments", `Int summary.total_arguments);
            ("created_at", `Float d.created_at);
            ("created_at_iso", `String (iso8601_of_unix d.created_at));
            ("summary_text", `String (Council.Debate.render_summary summary));
          ]
      in
      (`OK, json)

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""

(** Helper functions to get initialized state or fail *)
let get_server_state () = match !server_state with
  | Some s -> s
  | None -> failwith "Server state not initialized"


let http_status_of_graphql = function
  | `OK -> `OK
  | `Bad_request -> `Bad_request

let handle_get_graphql _request reqd =
  let nonce =
    let rng = Random.State.make_self_init () in
    let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
    Base64.encode_string (Bytes.to_string bytes)
  in
  let headers = [
    ("content-security-policy", graphql_csp_header nonce);
  ] in
  let body = graphql_playground_html ~nonce in
  Http.Response.html ~headers body reqd

let handle_post_graphql request reqd =
  let origin = get_origin request in
  Http.Request.read_body_async reqd (fun body_str ->
    let state = get_server_state ()
    in
    let response = Graphql_api.handle_request ~config:state.room_config body_str in
    let status = http_status_of_graphql response.status in
    let headers = Httpun.Headers.of_list (
      ("content-length", string_of_int (String.length response.body))
      :: graphql_headers origin
    ) in
    let http_response = Httpun.Response.create ~headers status in
    Httpun.Reqd.respond_with_string reqd http_response response.body
  )

let handle_graphql request reqd =
  match Http.Request.method_ request with
  | `GET -> handle_get_graphql request reqd
  | `POST -> handle_post_graphql request reqd
  | _ -> Http.Response.method_not_allowed reqd

(** MCP POST handler - async body reading with callback-based response *)
let handle_post_mcp ?(profile = Mcp_eio.Full) request reqd =
  let origin = get_origin request in
  let session_id =
    match get_session_id_any request with
    | Some id -> id
    | None -> Mcp_session.generate ()
  in
  let auth_token = auth_token_from_request request in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path =
    match !server_state with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full -> verify_mcp_auth ~base_path request
    | Mcp_eio.Operator_remote -> verify_operator_mcp_auth ~base_path request
  in
  match validate_mcp_session_profile ~profile session_id with
  | Error msg ->
      let body = json_rpc_error (-32600) msg in
      let headers =
        Httpun.Headers.of_list
          ( ("content-length", string_of_int (String.length body))
          :: json_headers session_id protocol_version origin )
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response body
  | Ok () ->
      remember_mcp_profile session_id profile;
      (match auth_result with
  | Error msg ->
      respond_mcp_auth_error request reqd ~session_id ~protocol_version msg
  | Ok _cred_opt -> (
      match classify_mcp_accept request with
      | Http_negotiation.Rejected ->
          let body =
            json_rpc_error (-32600)
              "Invalid Accept header: must include application/json and text/event-stream. \
               Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility."
          in
          let headers =
            Httpun.Headers.of_list
              ( ("content-length", string_of_int (String.length body))
              :: json_headers session_id protocol_version origin )
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | accept_mode ->
          let accept_warn_headers = legacy_accept_warning_headers accept_mode in
          Http.Request.read_body_async reqd (fun body_str ->
              try
                let state = get_server_state ()
                in
                let sw = get_switch ()
                in
                let clock = get_clock ()
                in
                let response_json =
                  Mcp_eio.handle_request ~clock ~sw ~profile ~mcp_session_id:session_id
                    ?auth_token state body_str
                in
                (match protocol_version_from_body body_str with
                | Some v -> remember_protocol_version session_id v
                | None -> ());
                let protocol_version =
                  get_protocol_version_for_session ~session_id request
                in
                let wants_sse =
                  accepts_sse request
                  && not force_json_response
                  && not (request_force_json_response request)
                in
                if wants_sse then begin
                  match response_json with
                  | `Null ->
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", "0")
                          :: accept_warn_headers
                          @ mcp_headers session_id protocol_version )
                      in
                      let response = Httpun.Response.create ~headers `Accepted in
                      Httpun.Reqd.respond_with_string reqd response ""
                  | json when is_http_error_response json ->
                      let body = Yojson.Safe.to_string json in
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", string_of_int (String.length body))
                          :: accept_warn_headers
                          @ json_headers session_id protocol_version origin )
                      in
                      let response = Httpun.Response.create ~headers `Bad_request in
                      Httpun.Reqd.respond_with_string reqd response body
                  | json ->
                      let event =
                        Sse.format_event ~event_type:"message"
                          (Yojson.Safe.to_string json)
                      in
                      let body = sse_prime_event () ^ event in
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", string_of_int (String.length body))
                          :: accept_warn_headers
                          @ sse_headers session_id protocol_version origin )
                      in
                      let response = Httpun.Response.create ~headers `OK in
                      Httpun.Reqd.respond_with_string reqd response body
                end else begin
                  match response_json with
                  | `Null ->
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", "0")
                          :: accept_warn_headers
                          @ mcp_headers session_id protocol_version )
                      in
                      let response = Httpun.Response.create ~headers `Accepted in
                      Httpun.Reqd.respond_with_string reqd response ""
                  | json when is_http_error_response json ->
                      let body = Yojson.Safe.to_string json in
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", string_of_int (String.length body))
                          :: accept_warn_headers
                          @ json_headers session_id protocol_version origin )
                      in
                      let response = Httpun.Response.create ~headers `Bad_request in
                      Httpun.Reqd.respond_with_string reqd response body
                  | json ->
                      let body = Yojson.Safe.to_string json in
                      let headers =
                        Httpun.Headers.of_list
                          ( ("content-length", string_of_int (String.length body))
                          :: accept_warn_headers
                          @ json_headers session_id protocol_version origin )
                      in
                      let response = Httpun.Response.create ~headers `OK in
                      Httpun.Reqd.respond_with_string reqd response body
                end
              with exn ->
                let protocol_version =
                  get_protocol_version_for_session ~session_id request
                in
                let body =
                  json_rpc_error (-32603)
                    ("Internal error: " ^ Printexc.to_string exn)
                in
                let headers =
                  Httpun.Headers.of_list
                    ( ("content-length", string_of_int (String.length body))
                    :: json_headers session_id protocol_version origin )
                in
                let response =
                  Httpun.Response.create ~headers `Internal_server_error
                in
                Httpun.Reqd.respond_with_string reqd response body)))

(** SSE connection tracking (prevents leaks / stale sessions) *)
type sse_conn_info = {
  session_id: string;
  client_id: int;
  writer: Httpun.Body.Writer.t;
  mutex: Eio.Mutex.t;
  stop: bool ref;
  mutable closed: bool;
}

let sse_conn_by_session : (string, sse_conn_info) Hashtbl.t = Hashtbl.create 128

type sse_connect_guard_state = {
  mutable last_connect_at: float;
  mutable connect_times: float list;  (* newest first *)
}

let sse_connect_guard_by_session : (string, sse_connect_guard_state) Hashtbl.t =
  Hashtbl.create 256

let prune_connect_times ~now times =
  if sse_connect_window_s <= 0.0 then times
  else List.filter (fun ts -> now -. ts <= sse_connect_window_s) times

let check_sse_connect_guard session_id =
  let now = Time_compat.now () in
  let state =
    match Hashtbl.find_opt sse_connect_guard_by_session session_id with
    | Some v -> v
    | None -> { last_connect_at = -.1.0; connect_times = [] }
  in
  let recent = prune_connect_times ~now state.connect_times in
  state.connect_times <- recent;
  let session_wait_s =
    if sse_reconnect_min_interval_s <= 0.0 then
      0.0
    else
      sse_reconnect_min_interval_s -. (now -. state.last_connect_at)
  in
  if session_wait_s > 0.0 then
    Error ("session_cooldown", session_wait_s)
  else
    let window_wait_s =
      if sse_connect_window_s <= 0.0 || sse_connect_max_in_window <= 0 then
        0.0
      else if List.length recent >= sse_connect_max_in_window then
        match List.rev recent with
        | oldest :: _ -> sse_connect_window_s -. (now -. oldest)
        | [] -> 0.0
      else
        0.0
    in
    if window_wait_s > 0.0 then
      Error ("window_limit", window_wait_s)
    else begin
      state.last_connect_at <- now;
      state.connect_times <- now :: recent;
      Hashtbl.replace sse_connect_guard_by_session session_id state;
      Ok ()
    end

let respond_sse_rate_limited ~origin ~session_id ~protocol_version ~reason ~retry_after_s reqd =
  let retry_after_s = Float.max retry_after_s 0.001 in
  let retry_after_header =
    retry_after_s
    |> Float.ceil
    |> int_of_float
    |> max 1
    |> string_of_int
  in
  let body =
    `Assoc [
      ("error", `String "sse_connection_rate_limited");
      ("reason", `String reason);
      ("retry_after_seconds", `Float retry_after_s);
    ]
    |> Yojson.Safe.to_string
  in
  let headers = Httpun.Headers.of_list (
    ("content-length", string_of_int (String.length body))
    :: ("retry-after", retry_after_header)
    :: json_headers session_id protocol_version origin
  ) in
  let response = Httpun.Response.create ~headers `Too_many_requests in
  Httpun.Reqd.respond_with_string reqd response body

let close_sse_conn info =
  if not info.closed then begin
    info.closed <- true;
    info.stop := true;
    (try Httpun.Body.Writer.close info.writer with
     | exn ->
         (* Expected during client disconnect - log for debugging *)
         Printf.eprintf "[DEBUG] close_sse_conn: %s\n%!" (Printexc.to_string exn));
    (* Critical: unregister from Sse module to prevent client count leak.
       unregister_if_current is idempotent (checks client_id match). *)
    Sse.unregister_if_current info.session_id info.client_id
  end

let stop_sse_session session_id =
  match Hashtbl.find_opt sse_conn_by_session session_id with
  | None -> ()
  | Some info ->
      Hashtbl.remove sse_conn_by_session session_id;
      close_sse_conn info
      (* Note: Sse.unregister_if_current already called in close_sse_conn *)

(** Close all SSE connections gracefully - for shutdown *)
let close_all_sse_connections () =
  let sessions = Hashtbl.fold (fun k _ acc -> k :: acc) sse_conn_by_session [] in
  List.iter (fun session_id ->
    stop_sse_session session_id
  ) sessions;
  Printf.eprintf "🚀 MASC MCP: Closed %d SSE connections\n%!" (List.length sessions)

let send_raw info data =
  if info.closed || !(info.stop) || Httpun.Body.Writer.is_closed info.writer then
    (close_sse_conn info; false)
  else
    try
      Eio.Mutex.use_rw ~protect:true info.mutex (fun () ->
        Httpun.Body.Writer.write_string info.writer data;
        Httpun.Body.Writer.flush info.writer (fun _ -> ())
      );
      Sse.touch info.session_id;
      true
    with _exn ->
      (* Expected during client disconnect - silent close *)
      close_sse_conn info;
      false

let handle_get_mcp ?legacy_messages_endpoint ?(profile = Mcp_eio.Full) request reqd =
  let origin = get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let legacy_headers =
    match legacy_messages_endpoint with
    | Some _ -> legacy_transport_deprecation_headers
    | None -> []
  in
  let last_event_id = get_last_event_id request in
  match validate_mcp_session_profile ~profile session_id with
  | Error msg ->
      let headers =
        Httpun.Headers.of_list
          ( ("content-length", string_of_int (String.length msg))
          :: json_headers session_id protocol_version origin )
      in
      let response = Httpun.Response.create ~headers `Conflict in
      Httpun.Reqd.respond_with_string reqd response msg
  | Ok () ->
      remember_mcp_profile session_id profile;
      (match check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      respond_sse_rate_limited
        ~origin
        ~session_id
        ~protocol_version
        ~reason
        ~retry_after_s
        reqd
  | Ok () ->
      (* Replace existing connection for session_id *)
      stop_sse_session session_id;

      let headers =
        Httpun.Headers.of_list
          (legacy_headers @ sse_stream_headers session_id protocol_version origin)
      in
      let response = Httpun.Response.create ~headers `OK in
      let writer = Httpun.Reqd.respond_with_streaming reqd response in
      let mutex = Eio.Mutex.create () in
      let info_ref : sse_conn_info option ref = ref None in
      let push event =
        match !info_ref with
        | None -> ()
        | Some info -> ignore (send_raw info event)
      in
      let (client_id, evicted) =
        Sse.register session_id ~push
          ~last_event_id:(Option.value ~default:0 last_event_id)
      in
      (* Clean up writer for evicted session *)
      (match evicted with
       | Some evicted_sid -> stop_sse_session evicted_sid
       | None -> ());
      let info = {
        session_id;
        client_id;
        writer;
        mutex;
        stop = ref false;
        closed = false;
      } in
      info_ref := Some info;
      Hashtbl.replace sse_conn_by_session session_id info;

      (* Send priming event first *)
      ignore (send_raw info (sse_prime_event ()));

      (* Legacy SSE transport: provide messages endpoint (event: endpoint) *)
      (match legacy_messages_endpoint with
       | None -> ()
       | Some f ->
           let endpoint_url = f session_id in
           ignore (send_raw info (Sse.format_event ~event_type:"endpoint" endpoint_url)));

      (* Replay missed events if Last-Event-ID provided (MCP spec MUST) *)
      (match last_event_id with
       | Some last_id ->
           let missed = Sse.get_events_after last_id in
           List.iter (fun ev -> ignore (send_raw info ev)) missed
       | None -> ());

      (* Keep-alive ping loop *)
      (match !current_sw, !current_clock with
       | Some sw, Some clock ->
           Eio.Fiber.fork ~sw (fun () ->
             let is_cancelled exn =
               match exn with
              | Eio.Cancel.Cancelled _ -> true
               | _ -> false
             in
             let rec loop () =
               if not !(info.stop) then begin
                 (try
                    Eio.Time.sleep clock sse_ping_interval_s
                  with exn ->
                    if is_cancelled exn then raise exn;
                    Printf.eprintf "[SSE] ping sleep error: %s\n%!" (Printexc.to_string exn));
                 (try
                    if info.closed then
                      stop_sse_session info.session_id
                    else if not !(info.stop) then
                      ignore (send_raw info ": ping\n\n")
                  with exn ->
                    if is_cancelled exn then raise exn;
                    Printf.eprintf "[SSE] ping send error: %s\n%!" (Printexc.to_string exn);
                    stop_sse_session info.session_id);
                 loop ()
               end
             in
             try loop () with exn ->
               if is_cancelled exn then ()
               else Printf.eprintf "[SSE] ping loop error: %s\n%!" (Printexc.to_string exn))
       | _ -> ());

      (* Only log when approaching capacity or in debug mode *)
      let client_count = Sse.client_count () in
      if client_count > Sse.max_clients / 2 then
        Printf.eprintf "📡 SSE connected: %s (active: %d/%d)\n%!"
          session_id client_count Sse.max_clients)

(** SSE simple handler - for compatibility, returns single event *)
let sse_simple_handler request reqd =
  let origin = get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let event = sse_prime_event ()
              ^ Sse.format_event ~event_type:"connected"
                  (Printf.sprintf {|{"session_id":"%s"}|} session_id)
  in
  let headers =
    Httpun.Headers.of_list
      ( ("content-length", string_of_int (String.length event))
      :: legacy_transport_deprecation_headers
      @ sse_headers session_id protocol_version origin )
  in
  let response = Httpun.Response.create ~headers `OK in
  Httpun.Reqd.respond_with_string reqd response event

(** TRPG SSE poll interval in seconds *)
let trpg_sse_poll_interval_s = 2.0

(** TRPG SSE keepalive interval in seconds *)
let trpg_sse_keepalive_s = 30.0

(** Format a single TRPG event as an SSE frame.
    Uses the event's seq as the SSE id, and the event_type string as the SSE event field. *)
let trpg_event_to_sse (ev : Masc_mcp.Trpg_engine_event.t) : string =
  let data = Yojson.Safe.to_string (Masc_mcp.Trpg_engine_event.to_yojson ev) in
  let event_type_str = Masc_mcp.Trpg_engine_event.string_of_event_type ev.event_type in
  Printf.sprintf "id: %d\nevent: %s\ndata: %s\n\n" ev.seq event_type_str data

(** Handle TRPG SSE streaming endpoint (HTTP/1.1).
    Opens a long-lived text/event-stream connection, replays events after Last-Event-ID,
    then polls SQLite every 2s for new events. Sends keepalive comments every 30s. *)
let handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd =
  let room_id = String.trim room_id in
  if room_id = "" then begin
    let origin = get_origin request in
    Http.Response.json ~status:`Bad_request
      ~extra_headers:(cors_headers origin)
      (Yojson.Safe.to_string (trpg_error_json "room_id is required")) reqd
  end else
    let origin = get_origin request in
    match trpg_parse_event_type_filter event_type_filter with
    | Error (`Bad_request, msg) ->
        Http.Response.json ~status:`Bad_request
          ~extra_headers:(cors_headers origin)
          (Yojson.Safe.to_string (trpg_error_json msg)) reqd
    | Ok event_type_opt ->
        let last_event_id =
          match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
          | Some id -> (try int_of_string id with Failure _ -> 0)
          | None -> 0
        in
        let headers = Httpun.Headers.of_list ([
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache");
          ("connection", "keep-alive");
        ] @ cors_headers origin) in
        let response = Httpun.Response.create ~headers `OK in
        let writer = Httpun.Reqd.respond_with_streaming reqd response in
        let mutex = Eio.Mutex.create () in
        let closed = ref false in
        let last_seq = ref last_event_id in

        let send_raw_data data =
          if !closed || Httpun.Body.Writer.is_closed writer then begin
            closed := true; false
          end else
            try
              Eio.Mutex.use_rw ~protect:true mutex (fun () ->
                Httpun.Body.Writer.write_string writer data;
                Httpun.Body.Writer.flush writer (fun _ -> ()));
              true
            with _exn ->
              closed := true; false
        in

        (* Send initial comment to confirm connection *)
        ignore (send_raw_data
          (Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
             room_id !last_seq));

        (* Replay existing events newer than last_seq *)
        (match
           (if !last_seq > 0 then
              Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                ~base_dir ~room_id ~after_seq:!last_seq
            else
              Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id)
         with
         | Ok events ->
             let events = match event_type_opt with
               | None -> events
               | Some et ->
                   List.filter
                     (fun (ev : Masc_mcp.Trpg_engine_event.t) -> ev.event_type = et)
                     events
             in
             List.iter (fun ev ->
               if not !closed then begin
                 ignore (send_raw_data (trpg_event_to_sse ev));
                 last_seq := max !last_seq ev.Masc_mcp.Trpg_engine_event.seq
               end) events
         | Error _ -> ());

        (* Start polling fiber for new events + keepalive *)
        (match !current_sw, !current_clock with
         | Some sw, Some clock ->
             Eio.Fiber.fork ~sw (fun () ->
               let is_cancelled = function
                 | Eio.Cancel.Cancelled _ -> true | _ -> false
               in
               let keepalive_counter = ref 0 in
               let polls_per_keepalive =
                 max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s))
               in
               let rec loop () =
                 if not !closed then begin
                   (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                    with exn -> if is_cancelled exn then raise exn);
                   if not !closed then begin
                     (match
                        Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                          ~base_dir ~room_id ~after_seq:!last_seq
                      with
                      | Ok events ->
                          let events = match event_type_opt with
                            | None -> events
                            | Some et ->
                                List.filter
                                  (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                                    ev.event_type = et)
                                  events
                          in
                          List.iter (fun ev ->
                            if not !closed then begin
                              if not (send_raw_data (trpg_event_to_sse ev)) then
                                closed := true
                              else
                                last_seq := max !last_seq
                                  ev.Masc_mcp.Trpg_engine_event.seq
                            end) events
                      | Error _ -> ());
                     incr keepalive_counter;
                     if !keepalive_counter >= polls_per_keepalive then begin
                       keepalive_counter := 0;
                       if not !closed then
                         ignore (send_raw_data ": keepalive\n\n")
                     end
                   end;
                   loop ()
                 end
               in
               try loop () with exn ->
                 if not (is_cancelled exn) then
                   Printf.eprintf "[TRPG-SSE] poll loop error for room %s: %s\n%!"
                     room_id (Printexc.to_string exn))
         | _ ->
             ignore (send_raw_data
               "event: error\ndata: {\"error\":\"server not ready\"}\n\n"))

let handle_get_operator_mcp request reqd =
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let base_path =
    match !server_state with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  match verify_operator_mcp_auth ~base_path request with
  | Error msg ->
      respond_mcp_auth_error request reqd ~session_id ~protocol_version msg
  | Ok _ -> handle_get_mcp ~profile:Mcp_eio.Operator_remote request reqd

(** POST /messages - Legacy SSE transport (client->server messages) *)
let handle_post_messages request reqd =
  let origin = get_origin request in
  let legacy_headers = legacy_transport_deprecation_headers in
  match get_session_id_any request with
  | None ->
      let body = "session_id required" in
      let headers = Httpun.Headers.of_list (
        ("content-length", string_of_int (String.length body))
        :: (legacy_headers @ cors_headers origin)
      ) in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id when not (Mcp_session.is_valid session_id) ->
      let body = "invalid session_id" in
      let headers = Httpun.Headers.of_list (
        ("content-length", string_of_int (String.length body))
        :: (legacy_headers @ cors_headers origin)
      ) in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id ->
      let protocol_version = get_protocol_version_for_session ~session_id request in
      let auth_token = auth_token_from_request request in
      let base_path =
        match !server_state with
        | Some s -> s.Mcp_server.room_config.base_path
        | None -> default_base_path ()
      in
      (match verify_mcp_auth ~base_path request with
       | Error msg ->
           respond_mcp_auth_error request reqd ~session_id ~protocol_version
             ~extra_headers:legacy_headers msg
       | Ok _cred_opt ->
           Http.Request.read_body_async reqd (fun body_str ->
             let state = get_server_state ()
             in
             let sw = get_switch ()
             in
             let clock = get_clock ()
             in
             let response_json =
               Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id ?auth_token state body_str
             in
             (match response_json with
             | `Null -> ()
             | json -> Sse.send_to session_id json);
             let headers = Httpun.Headers.of_list (
               ("content-length", "0")
               :: (legacy_headers @ mcp_headers session_id protocol_version)
             ) in
             let response = Httpun.Response.create ~headers `Accepted in
             Httpun.Reqd.respond_with_string reqd response ""
           ))

(** DELETE /mcp - Session termination *)
let handle_delete_mcp ?(profile = Mcp_eio.Full) request reqd =
  let base_path =
    match !server_state with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full -> Ok None
    | Mcp_eio.Operator_remote -> verify_operator_mcp_auth ~base_path request
  in
  match auth_result with
  | Error msg ->
      let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
      let protocol_version = get_protocol_version_for_session ~session_id request in
      respond_mcp_auth_error request reqd ~session_id ~protocol_version msg
  | Ok _ ->
      (match get_session_id_any request with
      | Some session_id -> (
          match validate_mcp_session_delete_profile ~profile session_id with
          | Error msg ->
              let headers = Httpun.Headers.of_list [
                ("content-length", string_of_int (String.length msg));
              ] in
              let response = Httpun.Response.create ~headers `Conflict in
              Httpun.Reqd.respond_with_string reqd response msg
          | Ok () ->
              stop_sse_session session_id;
              Sse.unregister session_id;
              forget_mcp_session session_id;
              Printf.printf "🔚 Session terminated: %s\n%!" session_id;
              let headers = Httpun.Headers.of_list (
                ("content-length", "0")
                :: mcp_headers session_id (get_protocol_version request)
              ) in
              let response = Httpun.Response.create ~headers `No_content in
              Httpun.Reqd.respond_with_string reqd response "")
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers = Httpun.Headers.of_list [
            ("content-length", string_of_int (String.length body));
          ] in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body)

(** Build routes for MCP server *)
let make_routes ~port ~host ~sw ~clock =
  Http.Router.empty
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get "/metrics" (fun request reqd ->
       with_read_auth (fun _state _req reqd ->
         let body = Masc_mcp.Prometheus.to_prometheus_text () in
         Http.Response.bytes ~content_type:"text/plain; version=0.0.4; charset=utf-8" body reqd
       ) request reqd)
  |> Http.Router.get "/.well-known/agent-card.json" (fun request reqd ->
       with_read_auth (fun _state req reqd ->
         let host_header = Httpun.Headers.get req.Httpun.Request.headers "host" in
         let (resolved_host, resolved_port) = parse_host_port host_header host port in
         let card = Masc_mcp.Agent_card.generate_default ~host:resolved_host ~port:resolved_port () in
         let json = Masc_mcp.Agent_card.to_json card |> Yojson.Safe.to_string in
         let a2a_version = Masc_mcp.A2a_tools.default_a2a_version in
         Http.Response.json ~extra_headers:[("A2A-Version", a2a_version)] json reqd
       ) request reqd)
  |> Http.Router.get "/ag-ui/events" (fun request reqd ->
       (* AG-UI Protocol SSE endpoint — translates MASC events to AG-UI format.
          Clients connect here to receive real-time AG-UI events. *)
       let origin = get_origin request in
       let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
       let protocol_version = get_protocol_version_for_session ~session_id request in
       let room_id = Option.value ~default:"default" (query_param request "room") in
       let last_event_id = get_last_event_id request in
       match check_sse_connect_guard session_id with
       | Error (reason, retry_after_s) ->
           respond_sse_rate_limited
             ~origin
             ~session_id
             ~protocol_version
             ~reason
             ~retry_after_s
             reqd
       | Ok () ->
           stop_sse_session session_id;

           let headers = Httpun.Headers.of_list (sse_stream_headers session_id protocol_version origin) in
           let response = Httpun.Response.create ~headers `OK in
           let writer = Httpun.Reqd.respond_with_streaming reqd response in
           let mutex = Eio.Mutex.create () in
           let info_ref : sse_conn_info option ref = ref None in
           let push event =
             match !info_ref with
             | None -> ()
             | Some info ->
               (* Translate MASC SSE data to AG-UI event format.
                  Parse the JSON from the SSE data line and re-emit as AG-UI CUSTOM. *)
               let ag_ui_event =
                 try
                   (* Extract JSON from SSE format: "id: N\nevent: type\ndata: {...}\n\n" *)
                   let lines = String.split_on_char '\n' event in
                   let data_line = List.find_opt (fun l ->
                     String.length l > 6 && String.sub l 0 6 = "data: "
                   ) lines in
                   match data_line with
                   | Some dl ->
                     let json_str = String.sub dl 6 (String.length dl - 6) in
                     let json = Yojson.Safe.from_string json_str in
                     let ag_event = Masc_mcp.Ag_ui.of_custom ~room_id
                       ~name:"MASC_EVENT" json in
                     Masc_mcp.Ag_ui.event_to_sse ag_event
                   | None -> event  (* Pass through if no data line *)
                 with _ -> event  (* Pass through on parse error *)
               in
               ignore (send_raw info ag_ui_event)
           in
           let (client_id, evicted) =
             Sse.register session_id ~push
               ~last_event_id:(Option.value ~default:0 last_event_id)
           in
           (match evicted with
            | Some evicted_sid -> stop_sse_session evicted_sid
            | None -> ());
           let info = {
             session_id;
             client_id;
             writer;
             mutex;
             stop = ref false;
             closed = false;
           } in
           info_ref := Some info;
           Hashtbl.replace sse_conn_by_session session_id info;

           (* Send AG-UI priming: RUN_STARTED event *)
           let prime = Masc_mcp.Ag_ui.(
             make_event ~thread_id:room_id
               ~run_id:(Some session_id)
               Run_started
             |> event_to_sse
           ) in
           ignore (send_raw info prime);

           (* Replay missed events *)
           (match last_event_id with
            | Some last_id ->
              let missed = Sse.get_events_after last_id in
              List.iter (fun ev -> ignore (send_raw info ev)) missed
            | None -> ());

           (* Keep-alive ping *)
           (match !current_sw, !current_clock with
            | Some sw, Some clock ->
              Eio.Fiber.fork ~sw (fun () ->
                let rec loop () =
                  if not !(info.stop) then begin
                    (try Eio.Time.sleep clock sse_ping_interval_s
                     with _ -> ());
                    (try
                       if info.closed then stop_sse_session info.session_id
                       else if not !(info.stop) then
                         ignore (send_raw info ": ping\n\n")
                     with _ -> stop_sse_session info.session_id);
                    loop ()
                  end
                in
                try loop () with _ -> ())
            | _ -> ()))
  (* Dashboard sub-routes: credits and lodge must come before the SPA catchall *)
  |> Http.Router.get "/dashboard/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.html (Masc_mcp.Credits_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/lodge" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Response.html_cached
           ~etag:(Masc_mcp.Lodge_dashboard.etag ())
           ~request:req
           (Masc_mcp.Lodge_dashboard.html ()) reqd
       ) request reqd)
  |> Http.Router.get "/favicon.ico" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  |> Http.Router.get "/favicon.svg" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  (* Dashboard SPA: static assets — prefix match for /dashboard/assets/* *)
  |> Http.Router.prefix_get "/dashboard/assets/"
       (fun request reqd ->
         let req_path = Http.Request.path request in
         let prefix_len = String.length "/dashboard/assets/" in
         let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
         if Masc_mcp.Web_dashboard.is_safe_asset_relative_path filename then
           serve_dashboard_static ("assets/" ^ filename) request reqd
         else
           Http.Response.not_found reqd)
  (* Dashboard SPA: index.html *)
  |> Http.Router.get "/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.prefix_get "/dashboard/"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let req_path = Http.Request.path req in
           if is_dashboard_spa_deep_link req_path then
             serve_dashboard_index req reqd
           else
             Http.Response.not_found reqd
         ) request reqd)
  |> Http.Router.get "/api/v1/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.json (Masc_mcp.Credits_dashboard.json_api ()) reqd
       ) request reqd)
  |> Http.Router.get "/" (fun _req reqd -> Http.Response.text "MASC MCP Server" reqd)
  |> Http.Router.get "/static/css/middleware.css"
       (serve_playground_asset "static/css/middleware.css")
  |> Http.Router.get "/static/js/middleware.js"
       (serve_playground_asset "static/js/middleware.js")
  |> Http.Router.get "/graphiql/graphiql.min.css"
       (serve_graphiql_asset "graphiql.min.css")
  |> Http.Router.get "/graphiql/graphiql.min.js"
       (serve_graphiql_asset "graphiql.min.js")
  |> Http.Router.get "/graphiql/react.production.min.js"
       (serve_graphiql_asset "react.production.min.js")
  |> Http.Router.get "/graphiql/react-dom.production.min.js"
       (serve_graphiql_asset "react-dom.production.min.js")
  |> Http.Router.get "/mcp" (fun request reqd ->
       with_read_auth (fun _state req reqd -> handle_get_mcp req reqd) request reqd)
  |> Http.Router.get "/mcp/operator" handle_get_operator_mcp
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/operator" (handle_post_mcp ~profile:Mcp_eio.Operator_remote)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
  |> Http.Router.post "/messages" handle_post_messages
  |> Http.Router.get "/sse"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           handle_get_mcp
             ~legacy_messages_endpoint:(legacy_messages_endpoint_url req)
             req reqd
         ) request reqd)
  |> Http.Router.get "/sse/simple" (fun request reqd ->
       with_public_read (fun _state req reqd -> sse_simple_handler req reqd) request reqd)
  (* REST API for dashboard - direct Room access *)
  |> Http.Router.get "/api/v1/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_state = Masc_mcp.Room.read_state config in
         let tempo = Masc_mcp.Tempo.get_tempo config in
         let json = `Assoc [
           ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
           ("project", `String room_state.project);
           ("tempo_interval_s", `Float tempo.current_interval_s);
           ("paused", `Bool room_state.paused);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/tasks" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let include_done = bool_query_param req "include_done" ~default:false in
         let include_cancelled = bool_query_param req "include_cancelled" ~default:false in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let tasks = Masc_mcp.Room.get_tasks_raw config in
         let filtered =
           match status_filter with
           | None -> tasks
           | Some status ->
               List.filter (fun (t : Masc_mcp.Types.task) ->
                 String.equal status (Masc_mcp.Types.string_of_task_status t.task_status)
               ) tasks
         in
         let filtered =
           match status_filter with
           | Some _ -> filtered
           | None ->
               List.filter (fun (t : Masc_mcp.Types.task) ->
                 let is_done = match t.task_status with
                   | Types.Done _ -> true
                   | _ -> false
                 in
                 let is_cancelled = match t.task_status with
                   | Types.Cancelled _ -> true
                   | _ -> false
                 in
                 (include_done || not is_done) &&
                 (include_cancelled || not is_cancelled)
               ) filtered
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let tasks_json = List.map (fun (t : Masc_mcp.Types.task) ->
           `Assoc [
             ("id", `String t.id);
             ("title", `String t.title);
             ("status", `String (Masc_mcp.Types.string_of_task_status t.task_status));
             ("priority", `Int t.priority);
             ("assignee", match t.task_status with
               | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } -> `String assignee
               | _ -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("tasks", `List tasks_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let limit = int_query_param req "limit" ~default:50 in
         let offset = int_query_param req "offset" ~default:0 in
         let agents = Masc_mcp.Room.get_agents_raw config in
         let filtered =
           match status_filter with
           | None -> agents
           | Some status ->
               List.filter (fun (a : Masc_mcp.Types.agent) ->
                 String.equal status (Masc_mcp.Types.string_of_agent_status a.status)
               ) agents
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let agents_json = List.map (fun (a : Masc_mcp.Types.agent) ->
           `Assoc [
             ("name", `String a.name);
             ("status", `String (Masc_mcp.Types.string_of_agent_status a.status));
             ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
           ]
         ) page in
         let json = `Assoc [
           ("agents", `List agents_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/messages" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let since_seq = int_query_param req "since_seq" ~default:0 in
         let limit = int_query_param req "limit" ~default:20 in
         let agent_filter = query_param req "agent" in
         let msgs = Masc_mcp.Room.get_messages_raw config ~since_seq ~limit:500 in
         let filtered =
           match agent_filter with
           | None -> msgs
           | Some agent ->
               List.filter (fun (m : Masc_mcp.Types.message) ->
                 String.equal agent m.from_agent
               ) msgs
         in
         let total = List.length filtered in
         let page = filtered |> List.filteri (fun idx _ -> idx < limit) in
         let msgs_json = List.map (fun (m : Masc_mcp.Types.message) ->
           `Assoc [
             ("from", `String m.from_agent);
             ("content", `String m.content);
             ("timestamp", `String m.timestamp);
             ("seq", `Int m.seq);
           ]
         ) page in
         let json = `Assoc [
           ("messages", `List msgs_json);
           ("limit", `Int limit);
           ("since_seq", `Int since_seq);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_append_event_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_id = Option.value ~default:"default" (Masc_mcp.Room.read_current_room config) in
         let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
         respond_json_with_cors request reqd (Yojson.Safe.to_string json)
       ) request reqd)
  |> Http.Router.post "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     respond_json_with_cors ~status:`Bad_request request reqd
                       (Yojson.Safe.to_string
                          (trpg_error_json "room_id cannot be empty"))
                   else (
                     Masc_mcp.Room.write_current_room config room_id;
                     Masc_mcp.Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     respond_json_with_cors request reqd (Yojson.Safe.to_string response)))
           with
           | Yojson.Json_error msg ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json (Printf.sprintf "invalid json: %s" msg))))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/catalog" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match
           trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/preflight" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         let dm_keeper = query_param req "dm" in
         let player_keepers =
           query_param req "players" |> Option.value ~default:"" |> split_csv_nonempty
         in
         let models =
           query_param req "models" |> Option.value ~default:"" |> split_csv_nonempty
         in
         match
           trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module ~dm_keeper ~player_keepers ~models
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/overview" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_overview_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/control/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_control_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/models" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         respond_json_with_cors request reqd
           (Yojson.Safe.to_string (trpg_available_models_json ()))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/dice/roll" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_dice_roll_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/turns/advance" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_turn_advance_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/rounds/run" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let agent_name =
             Option.value ~default:"dashboard" (agent_from_request req)
           in
           match !current_sw, !current_clock with
           | Some sw, Some clock -> (
               match
                 trpg_round_run_json
                   ~state
                   ~agent_name
                   ~sw
                   ~clock
                   ~idempotency_key:
                     (get_header_any_case req.Httpun.Request.headers "idempotency-key")
                   ~body_str
               with
               | Ok json ->
                   respond_json_with_cors request reqd (Yojson.Safe.to_string json)
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Error (`Internal_server_error, msg) ->
                   respond_json_with_cors ~status:`Internal_server_error request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg)))
           | _ ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json "trpg runtime not initialized"))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         let actor_filter = query_param req "actor" in
         let phase_filter = query_param req "phase" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         match
           trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
             ~actor_filter ~phase_filter ~limit
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream/sse" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let event_type_filter = query_param req "event_type" in
         handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/spawn" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match
             trpg_actor_spawn_json ~base_dir
               ~idempotency_key:
                 (get_header_any_case req.Httpun.Request.headers "idempotency-key")
               ~body_str
           with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/claim" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_claim_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/release" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_release_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/tts" (fun request reqd ->
       Http.Request.read_body_async reqd (fun body_str ->
         match trpg_tts_proxy ~body_str with
         | Ok audio_bytes ->
             let origin = get_origin request in
             Http.Response.bytes ~content_type:"audio/mpeg"
               ~headers:(cors_headers origin) audio_bytes reqd
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (_, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))))
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Masc_mcp.Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Masc_mcp.Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)

  (* Batch dashboard endpoint: single request replaces 4 separate API calls *)
  |> Http.Router.get "/api/v1/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           `Assoc
             [
               ("error", `String "dashboard batch contract removed");
               ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
             ]
         in
         Http.Response.json ~status:`Gone ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/shell" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_shell_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/memory" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_memory_http_json req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_planning_http_json req ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/semantics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_semantics_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/mdal/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match mdal_loops_json ~config:state.Mcp_server.room_config req with
         | Ok json -> Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error msg ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string (mdal_loops_error_json msg)) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_snapshot_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_summary_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/help" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = command_plane_help_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/topology" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_topology_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/units" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_units_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/operations" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_operations_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachments" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_detachments_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachment-status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_detachment_status_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~compress:true ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/decisions" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_decisions_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/capacity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_capacity_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/alerts" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_alerts_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/traces" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_traces_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/swarm" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_swarm_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_chain_summary_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         command_plane_chain_events_http ~request:req reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/chains/runs/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/chains/runs/" in
         let run_id =
           String.sub req_path (String.length prefix)
             (String.length req_path - String.length prefix)
         in
         match command_plane_chain_run_http_json ~state req run_id with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/command-plane/units" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_define_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reparent" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reparent_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reassign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reassign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_start_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors ~status:`Created request reqd
                   (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/pause" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_pause_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/resume" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_resume_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/stop" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_stop_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/finalize" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_finalize_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/checkpoint" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               command_plane_operation_checkpoint_http_json ~state req ~args
             with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/plan" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_plan_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/assign" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_assign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/rebalance" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_rebalance_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/escalate" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_escalate_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/recall" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_recall_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/tick" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_tick_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/policy" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_policy_status_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/approve" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_approve_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/deny" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_deny_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/update" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_update_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/freeze" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_freeze_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/kill-switch" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_kill_switch_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = operator_snapshot_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
         | Error message ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json message))
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_permission_auth ~permission:Types.CanBroadcast (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/council/debates" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = council_debates_json req ~base_path in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/council/sessions" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = council_sessions_json req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
         let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
         let posts = filter_board_posts ~exclude_system posts in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           try List.assoc author karma_map with Not_found -> 0
         in
         let paged = posts |> drop offset |> take limit in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
               let author = Board.Agent_id.to_string p.author in
               board_post_dashboard_json ~author_karma:(get_karma author) p)
             paged
         in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts_json));
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("sort_by", `String (board_sort_label sort_by));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let hearths = Board_dispatch.list_hearths () in
         let json = `Assoc [
           ("hearths", `List (List.map (fun (name, count) ->
             `Assoc [("name", `String name); ("count", `Int count)]
           ) hearths));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)


  (* Board write APIs — used by Bevy Viewer *)
  |> Http.Router.post "/api/v1/tools/masc_board_vote" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_vote" args in
             let status = if ok then `OK else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_comment" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_comment" args in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/karma" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let karma_list = Board_dispatch.get_all_karma () in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
         let json = `Assoc [
           ("karma", `List (List.map (fun (agent, k) ->
             `Assoc [("agent", `String agent); ("karma", `Int k)]
           ) sorted));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Lodge Agents REST API — GET public, POST admin *)
  |> Http.Router.add ~path:"/api/v1/lodge/agents" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         match request.Httpun.Request.meth with
         | `GET ->
           with_public_read (fun _state _req reqd ->
             match Masc_mcp.Lodge_heartbeat.load_lodge_agents_full () with
             | Ok json ->
                 Http.Response.json (Yojson.Safe.to_string json) reqd
             | Error msg ->
                 Http.Response.json ~status:`Internal_server_error
                   (Printf.sprintf {|{"error":"%s"}|} msg) reqd
           ) request reqd
         | `POST ->
           with_admin_auth (fun _state _req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               try
                 let json = Yojson.Safe.from_string body_str in
                 let open Yojson.Safe.Util in
                 let name = json |> member "name" |> to_string in
                 let emoji = json |> member "emoji" |> to_string in
                 let korean_name =
                   match json |> member "koreanName" with
                   | `String s -> Some s | _ -> None
                 in
                 let traits =
                   json |> member "traits" |> to_list |> List.map to_string
                 in
                 let interests =
                   try json |> member "interests" |> to_list
                       |> List.map to_string
                   with Yojson.Safe.Util.Type_error _ | Not_found -> []
                 in
                 let activity_level =
                   match json |> member "activityLevel" with
                   | `Float f -> f | `Int i -> float_of_int i | _ -> 0.7
                 in
                 let preferred_hours =
                   json |> member "preferredHours" |> to_list
                   |> List.map to_int
                 in
                 let peak_hour =
                   match json |> member "peakHour" with
                   | `Int i -> Some i | _ -> None
                 in
                 let model =
                   match json |> member "model" with
                   | `String s -> s | _ -> "glm-4.7-flash:latest"
                 in
                 let personality_hint =
                   match json |> member "personalityHint" with
                   | `String s -> Some s | _ -> None
                 in
                 let primary_value =
                   match json |> member "primaryValue" with
                   | `String s -> Some s | _ -> None
                 in
                 let name_re = Str.regexp "^[a-z][a-z0-9-]*$" in
                 let name_len = String.length name in
                 if name_len < 2 || name_len > 20
                    || not (Str.string_match name_re name 0) then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"name: 2-20 lowercase + hyphens"}|} reqd
                 else if String.length emoji = 0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"emoji is required"}|} reqd
                 else if traits = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one trait required"}|} reqd
                 else if preferred_hours = [] then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"at least one preferredHour"}|} reqd
                 else if activity_level < 0.1 || activity_level > 1.0 then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"activityLevel: 0.1-1.0"}|} reqd
                 else if List.exists (fun h -> h < 0 || h > 23)
                           preferred_hours then
                   Http.Response.json ~status:`Bad_request
                     {|{"error":"hours: 0-23"}|} reqd
                 else begin
                   match Masc_mcp.Lodge_heartbeat.create_agent_graphql
                           ~name ~emoji ~korean_name ~traits ~interests
                           ~activity_level ~preferred_hours ~peak_hour
                           ~model ~personality_hint ~primary_value () with
                   | Ok agent_json ->
                       Http.Response.json ~status:`Created
                         (Yojson.Safe.to_string (`Assoc [
                           ("ok", `Bool true);
                           ("agent", agent_json);
                         ])) reqd
                   | Error msg ->
                       Http.Response.json ~status:`Internal_server_error
                         (Printf.sprintf {|{"error":"%s"}|} msg) reqd
                 end
               with
               | Yojson.Safe.Util.Type_error (msg, _) ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Invalid: %s"}|} msg)
                     reqd
               | Yojson.Json_error msg ->
                   Http.Response.json ~status:`Bad_request
                     (Printf.sprintf {|{"error":"Bad JSON: %s"}|} msg)
                     reqd
               | e ->
                   Http.Response.json ~status:`Internal_server_error
                     (Printf.sprintf {|{"error":"%s"}|}
                       (Printexc.to_string e)) reqd
             )
           ) request reqd
         | _ -> Http.Response.method_not_allowed reqd)

(** Extended router to handle OPTIONS *)
let make_extended_handler routes =
  fun _client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    let request = Httpun.Reqd.request reqd in
    try
      let path = Http.Request.path request in
      let is_mcp_like =
        String.equal path "/mcp"
        || String.equal path "/mcp/operator"
        || String.equal path "/sse"
        || String.equal path "/messages"
      in
      let session_id_for_version = get_session_id_any request in
      let protocol_version =
        get_protocol_version_for_session ?session_id:session_id_for_version request
      in
      let origin = get_origin request in
      if is_mcp_like && not (validate_origin request) then
        let body = json_rpc_error (-32600) "Invalid origin" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Forbidden in
        Httpun.Reqd.respond_with_string reqd response body
      else if is_mcp_like && request.meth <> `OPTIONS &&
              not (is_valid_protocol_version protocol_version) then
        let body = json_rpc_error (-32600) "Unsupported protocol version" in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers "-" protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Bad_request in
        Httpun.Reqd.respond_with_string reqd response body
      else
        match request.meth, path with
        | `OPTIONS, _ -> options_handler request reqd
        | `DELETE, "/mcp" -> handle_delete_mcp request reqd
        | `DELETE, "/mcp/operator" ->
            handle_delete_mcp ~profile:Mcp_eio.Operator_remote request reqd
        | `GET, "/api/v1/board/flairs" ->
            let flairs = List.map Board.flair_to_yojson Board.available_flairs in
            let json = `Assoc [("flairs", `List flairs)] in
            Http.Response.json (Yojson.Safe.to_string json) reqd
        | `GET, "/api/v1/board/hearths" ->
            let hearths = Board_dispatch.list_hearths () in
            let json = `Assoc [
              ("hearths", `List (List.map (fun (name, count) ->
                `Assoc [("name", `String name); ("count", `Int count)]
              ) hearths));
            ] in
            Http.Response.json (Yojson.Safe.to_string json) reqd
        | `GET, p
          when String.length p > 32
               && String.length p >= 24 + 8
               && String.sub p 0 24 = "/api/v1/council/debates/"
               && String.ends_with ~suffix:"/summary" p ->
            (match !server_state with
             | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
             | Some state ->
                 let prefix_len = 24 in
                 let suffix_len = 8 in
                 let debate_id_len = String.length p - prefix_len - suffix_len in
                 if debate_id_len <= 0 then
                   Http.Response.json ~status:`Bad_request {|{"error":"debate_id missing"}|} reqd
                 else
                   let debate_id = String.sub p prefix_len debate_id_len in
                   let base_path = state.Mcp_server.room_config.base_path in
                   let (status, json) = council_debate_summary_json ~base_path ~debate_id in
                   Http.Response.json ~status (Yojson.Safe.to_string json) reqd)
        | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
            let post_id = String.sub p 14 (String.length p - 14) in
            let format = Option.value ~default:"nested" (query_param request "format") in
            let (status, body) = board_post_detail_json ~response_format:format ~post_id in
            Http.Response.json ~status body reqd
        | _ -> Http.Router.dispatch routes request reqd
    with exn ->
      let msg = Printexc.to_string exn in
      Http.Response.internal_error msg reqd

(** Main server loop *)
let run_server ~sw ~env ~port ~base_path =
  (* Extract components from Eio environment *)
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in

  (* Store switch, clock, and net references for handlers *)
  current_sw := Some sw;
  current_clock := Some clock;
  current_net := Some net;

  (* Set net and clock references in Mcp_eio for async operations *)
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Masc_mcp.Eio_context.set_net net;
  Masc_mcp.Eio_context.set_clock clock;
  Council.Thread_persist.set_eio_context ~clock
    ~https_connector:(Masc_mcp.Eio_context.get_https_connector ())
    net;
  Masc_mcp.Process_eio.init
    ~cwd_default:Eio.Path.(fs / base_path)
    ~proc_mgr ~clock;

  (* Create Caqti-compatible stdenv adapter
     Note: net type coercion from [Generic|Unix] to [Generic] is safe
     because Caqti only uses the generic network capabilities *)
  let caqti_env : Caqti_eio.stdenv = object
    method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
    method clock = clock
    method mono_clock = mono_clock
  end in

  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;

  (* Initialize server state with Eio context *)
  let state = Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock ~base_path in
  server_state := Some state;
  Masc_mcp.Chain_native_eio.configure_storage_paths state.room_config;
  (try Masc_mcp.Tool_command_plane.backfill_chain_overlays state.room_config
   with exn ->
     Printf.eprintf "[chain-backfill] startup backfill failed: %s\n%!"
       (Printexc.to_string exn));
  Mcp_server.set_sse_callback state Sse.broadcast;

  (* Keepers are meant to be long-lived. Start their keepalive fibers on startup
     so liveness/last_seen stays up-to-date even if no tool calls happen. *)
  (try
     let keeper_ctx : _ Tool_keeper.context = { config = state.room_config; sw; clock } in
     let stats = Tool_keeper.bootstrap_existing_keepers keeper_ctx in
     if stats.enabled then
       Printf.eprintf
         "[keeper-bootstrap] scanned=%d started=%d stale=%d\n%!"
         stats.scanned stats.started stats.stale
   with exn -> Printf.eprintf "[main] keeper bootstrap failed: %s\n%!" (Printexc.to_string exn));

  (* Initialize Task backend - share pool with Board if PostgreSQL available *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       (match Task_dispatch.init_pg pool with
        | Ok () -> Printf.eprintf "[Task_dispatch] PostgreSQL backend initialized\n%!"
        | Error e -> Printf.eprintf "[Task_dispatch] PG init failed: %s, using JSONL\n%!" (Types.show_masc_error e))
   | None -> Task_dispatch.init_jsonl ());
  Progress.set_sse_callback Sse.broadcast;
  let cancel_orchestrator = Masc_mcp.Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr state.room_config in
  (* Store cancel function for graceful shutdown *)
  Masc_mcp.Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator;
  (* Lodge world heartbeat - wakes agents every 60s *)
  Masc_mcp.Lodge_heartbeat.start ~sw ~clock state.room_config;
  (* Internal guardian loops (no external watchdog dependency) *)
  Masc_mcp.Guardian.start ~sw ~clock ~net state.room_config;
  (* Start MCP session cleanup loop *)
  Masc_mcp.Session.start_mcp_session_cleanup_loop ~sw ~clock ();

  (* Board Listener — bridges pg_notify to SSE for real-time updates (Phase C) *)
  (match Board_dispatch.get_pg_pool () with
   | Some pool ->
       let listener = Board_listener.create pool in
       Eio.Fiber.fork ~sw (fun () -> Board_listener.start listener);
       Printf.eprintf "[Board_listener] Fiber started for real-time Board events\n%!"
   | None ->
       Printf.eprintf "[Board_listener] Skipped (not using PostgreSQL backend)\n%!");

  (* Periodic SSE stale-client reaper — every 60s, evict connections older than 30min *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 60.0;
      let stale_sids = Masc_mcp.Sse.cleanup_stale () in
      List.iter stop_sse_session stale_sids;
      if stale_sids <> [] then
        Printf.eprintf "[SSE] Reaped %d stale connections (active: %d)\n%!"
          (List.length stale_sids) (Masc_mcp.Sse.client_count ());
      loop ()
    in
    loop ());

  let config = { Http.default_config with port; host = "0.0.0.0" } in
  Unix.putenv "MASC_HTTP_PORT" (string_of_int config.port);
  (match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
   | Some existing when String.trim existing <> "" -> ()
   | _ ->
       Unix.putenv "MASC_HTTP_BASE_URL"
         (Printf.sprintf "http://127.0.0.1:%d" config.port));
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_extended_handler routes in

  (* Listen on all interfaces for Cloudflare tunnel access *)
  let ip = Eio.Net.Ipaddr.V4.any in
  let addr = `Tcp (ip, config.port) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr in

  let resolved_base = state.room_config.base_path in
  let masc_dir = Filename.concat resolved_base ".masc" in

  (* Initialize A2A subscription persistence *)
  Masc_mcp.A2a_tools.init ~masc_dir;

  Printf.printf "🚀 MASC MCP Server listening on http://%s:%d\n%!" config.host config.port;
  Printf.printf "   Base path: %s\n%!" resolved_base;
  if resolved_base <> base_path then
    Printf.printf "   Base path (input): %s\n%!" base_path;
  Printf.printf "   MASC dir: %s\n%!" masc_dir;
  Printf.printf "   GET  /mcp → SSE stream (notifications)\n%!";
  Printf.printf
    "   POST /mcp → JSON-RPC (Accept: application/json, text/event-stream)\n\
     %!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf
    "   GET  /mcp/operator → Remote operator MCP stream (bearer token required)\n\
     %!";
  Printf.printf
    "   POST /mcp/operator → Remote operator JSON-RPC (4 curated tools only)\n\
     %!";
  Printf.printf
    "   DELETE /mcp/operator → Remote operator session termination\n%!";
  Printf.printf "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf
    "   GET  /sse → legacy SSE stream (deprecated; use /mcp)\n%!";
  Printf.printf
    "   POST /messages → legacy client->server messages (deprecated)\n%!";
  Printf.printf "   GET  /health → Health check\n%!";

  (* Defer Lodge init slightly to avoid startup race when GRAPHQL_URL points
     to local /graphql on this same process. *)
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Time.sleep clock 1.0;
    Masc_mcp.Tool_lodge.init ());

  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Response Helpers - Reduce duplication in handlers
     ═══════════════════════════════════════════════════════════════════════ *)

  let h2_respond_json ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/html; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_bytes
      ?(status = `OK)
      ?(extra_headers = [])
      ~content_type
      h2_reqd
      body =
    let headers = H2.Headers.of_list ([
      ("content-type", content_type);
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
    let headers = H2.Headers.of_list (("content-length", "0") :: extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.close writer
  in

  (* Read H2 request body asynchronously *)
  let h2_read_body h2_reqd callback =
    let body = H2.Reqd.request_body h2_reqd in
    let buf = Buffer.create 4096 in
    let rec read_loop () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () -> callback (Buffer.contents buf))
        ~on_read:(fun bigstring ~off ~len ->
          let chunk = Bigstringaf.substring bigstring ~off ~len in
          Buffer.add_string buf chunk;
          read_loop ())
    in
    read_loop ()
  in

  (* HTTP/2 error handler *)
  let _h2_error_handler _client_addr ?request:_ error respond =
    let message = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Internal_server_error -> "Internal server error"
    in
    Printf.eprintf "[H2] Error: %s\n%!" message;
    let headers = H2.Headers.of_list [("content-type", "text/plain")] in
    let body = respond headers in
    H2.Body.Writer.write_string body message;
    H2.Body.Writer.close body
  in

  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Request Handler - Full implementation
     ═══════════════════════════════════════════════════════════════════════ *)
  let _h2_request_handler _client_addr h2_reqd =
    let h2_req = H2.Reqd.request h2_reqd in
    let h2_headers = h2_req.headers in
    (* Convert H2.Request to Httpun.Request for compatibility with existing code *)
    let httpun_headers = Httpun.Headers.of_list (H2.Headers.to_list h2_headers) in
    let httpun_meth = match h2_req.meth with
      | `GET -> `GET | `POST -> `POST | `DELETE -> `DELETE
      | `OPTIONS -> `OPTIONS | `PUT -> `PUT | `HEAD -> `HEAD
      | `CONNECT -> `CONNECT | `TRACE -> `TRACE | `Other s -> `Other s
    in
    let httpun_request = Httpun.Request.create ~headers:httpun_headers httpun_meth h2_req.target in
    let path = Http.Request.path httpun_request in
    let origin = match H2.Headers.get h2_headers "origin" with
      | Some o -> o | None -> "*"
    in
    let cors = cors_headers origin in
    let base_path =
      match !server_state with
      | Some s -> s.Mcp_server.room_config.base_path
      | None -> default_base_path ()
    in
    let session_id_opt = get_session_id_any httpun_request in
    let h2_respond_dashboard_index () =
      let index_path = dashboard_index_path () in
      match read_file index_path with
      | Ok body ->
          let etag_value = "\"" ^ dashboard_etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", dashboard_index_cache_control);
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control); ("vary", "Accept-Encoding")] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)
      | Error _ ->
          h2_respond_html h2_reqd "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>" ~extra_headers:cors
    in

    let dispatch_h2_route () =
      match httpun_meth, path with
      (* ─────────────────────────────────────────────────────────────────────
         Health & Metrics
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/health" ->
          let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
          let uptime_str =
            if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
            else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
            else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
          in
          let lodge_json = Masc_mcp.Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
          let guardian_json = Masc_mcp.Guardian.status_json () in
          let health_json = `Assoc [
            ("status", `String "ok");
            ("server", `String "masc-mcp");
            ("version", `String Masc_mcp.Version.version);
            ("protocol", `String "h2");
            ("uptime", `String uptime_str);
            ("sse_clients", `Int (Sse.client_count ()));
            ("lodge", lodge_json);
            ("guardian", guardian_json);
          ] in
          let body = Yojson.Safe.to_string health_json in
          h2_respond_json h2_reqd body ~extra_headers:cors

      | `GET, "/metrics" ->
          let body = Masc_mcp.Prometheus.to_prometheus_text () in
          let headers = H2.Headers.of_list ([
            ("content-type", "text/plain; version=0.0.4; charset=utf-8");
            ("content-length", string_of_int (String.length body));
          ] @ cors) in
          let response = H2.Response.create ~headers `OK in
          let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
          H2.Body.Writer.write_string writer body;
          H2.Body.Writer.close writer

      | `GET, "/" ->
          h2_respond_text h2_reqd "MASC MCP Server (HTTP/2)" ~extra_headers:cors

      | `GET, "/favicon.ico" | `GET, "/favicon.svg" ->
          h2_respond_bytes
            h2_reqd
            favicon_svg
            ~content_type:"image/svg+xml"
            ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         CORS Preflight
         ───────────────────────────────────────────────────────────────────── *)
      | `OPTIONS, _ ->
          h2_respond_empty h2_reqd ~extra_headers:(cors_preflight_headers origin)

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp" | `POST, "/" | `POST, "/mcp/operator" ->
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let auth_token = auth_token_from_request httpun_request in
          let protocol_version = get_protocol_version_for_session ~session_id httpun_request in
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else Mcp_eio.Full
          in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full -> verify_mcp_auth ~base_path httpun_request
            | Mcp_eio.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match validate_mcp_session_profile ~profile session_id with
           | Error msg ->
               let body = json_rpc_error (-32600) msg in
               h2_respond_json h2_reqd body ~status:`Conflict ~extra_headers:cors
           | Ok () ->
               remember_mcp_profile session_id profile;
               (match auth_result with
                | Error msg ->
                    let body = Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg in
                    h2_respond_json h2_reqd body ~status:`Unauthorized ~extra_headers:(("www-authenticate", "Bearer") :: cors)
                | Ok _cred_opt -> (
                    match classify_mcp_accept httpun_request with
                    | Http_negotiation.Rejected ->
                        let body =
                          json_rpc_error (-32600)
                            "Invalid Accept header: must include application/json and text/event-stream. \
                             Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility."
                        in
                        h2_respond_json h2_reqd body ~status:`Bad_request
                          ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                    | accept_mode ->
                        let accept_warn_headers =
                          legacy_accept_warning_headers accept_mode
                        in
                        h2_read_body h2_reqd (fun body_str ->
                            let state = get_server_state ()
                            in
                            let response_json =
                              Mcp_eio.handle_request ~clock ~sw ~profile
                                ~mcp_session_id:session_id ?auth_token state body_str
                            in
                            (match protocol_version_from_body body_str with
                            | Some v -> remember_protocol_version session_id v
                            | None -> ());
                            let protocol_version =
                              get_protocol_version_for_session ~session_id
                                httpun_request
                            in
                            let mcp_hdrs =
                              accept_warn_headers @ mcp_headers session_id protocol_version
                              @ cors
                            in
                            match response_json with
                            | `Null ->
                                h2_respond_empty h2_reqd ~status:`Accepted
                                  ~extra_headers:mcp_hdrs
                            | json when is_http_error_response json ->
                                let body = Yojson.Safe.to_string json in
                                h2_respond_json h2_reqd body ~status:`Bad_request
                                  ~extra_headers:mcp_hdrs
                            | json ->
                                let body = Yojson.Safe.to_string json in
                                h2_respond_json h2_reqd body ~extra_headers:mcp_hdrs))))

      | `DELETE, "/mcp" | `DELETE, "/mcp/operator" ->
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else Mcp_eio.Full
          in
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full -> Ok None
            | Mcp_eio.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match auth_result with
           | Error msg ->
               let body =
                 Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg
               in
               h2_respond_json h2_reqd body ~status:`Unauthorized
                 ~extra_headers:(("www-authenticate", "Bearer") :: cors)
           | Ok _ ->
               (match session_id_opt with
                | Some session_id -> (
                    match validate_mcp_session_delete_profile ~profile session_id with
                    | Error msg ->
                        let body =
                          Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32600,"message":"%s"}}|} msg
                        in
                        h2_respond_json h2_reqd body ~status:`Conflict
                          ~extra_headers:cors
                    | Ok () ->
                        stop_sse_session session_id;
                        Sse.unregister session_id;
                        forget_mcp_session session_id;
                        Printf.printf "🔚 Session terminated: %s\n%!" session_id;
                        let mcp_hdrs = mcp_headers session_id (get_protocol_version httpun_request) in
                        h2_respond_empty h2_reqd ~extra_headers:mcp_hdrs)
                | None ->
                    h2_respond_text h2_reqd "Mcp-Session-Id required" ~status:`Bad_request ~extra_headers:cors))

      (* ─────────────────────────────────────────────────────────────────────
         Dashboard
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/dashboard" | `GET, "/dashboard/" ->
          h2_respond_dashboard_index ()

      | `GET, "/dashboard/credits" ->
          h2_respond_html h2_reqd (Masc_mcp.Credits_dashboard.html ()) ~extra_headers:cors

      | `GET, "/dashboard/lodge" ->
          let etag_value = "\"" ^ Masc_mcp.Lodge_dashboard.etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", dashboard_index_cache_control);
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let body = Masc_mcp.Lodge_dashboard.html () in
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control)] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)

      | `GET, p when is_dashboard_spa_deep_link p ->
          h2_respond_dashboard_index ()

      (* ─────────────────────────────────────────────────────────────────────
         GraphQL
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/graphql" ->
          let nonce =
            let rng = Random.State.make_self_init () in
            let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
            Base64.encode_string (Bytes.to_string bytes)
          in
          let csp_header = ("content-security-policy", graphql_csp_header nonce) in
          h2_respond_html h2_reqd (graphql_playground_html ~nonce) ~extra_headers:(csp_header :: cors)

      | `POST, "/graphql" ->
          h2_read_body h2_reqd (fun body_str ->
            let state = get_server_state ()
            in
            let response = Graphql_api.handle_request ~config:state.room_config body_str in
            let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
            h2_respond_json h2_reqd response.body ~status ~extra_headers:cors
          )

      (* ─────────────────────────────────────────────────────────────────────
         REST API
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/api/v1/dashboard" ->
          let json =
            `Assoc
              [
                ("error", `String "dashboard batch contract removed");
                ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
              ]
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json)
            ~status:`Gone ~extra_headers:cors

      | `GET, "/api/v1/dashboard/shell" ->
          let state = get_server_state () in
          let json = dashboard_shell_http_json state.Mcp_server.room_config in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/execution" ->
          let state = get_server_state () in
          let json = dashboard_execution_http_json state.Mcp_server.room_config in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/memory" ->
          let json = dashboard_memory_http_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/governance" ->
          let state = get_server_state () in
          let json =
            dashboard_governance_http_json httpun_request
              ~base_path:state.Mcp_server.room_config.base_path
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/planning" ->
          let state = get_server_state () in
          let json =
            dashboard_planning_http_json httpun_request
              ~config:state.Mcp_server.room_config
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/semantics" ->
          let json = dashboard_semantics_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/mission" ->
          let state = get_server_state () in
          let json = dashboard_mission_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/mdal/loops" ->
          let state = get_server_state () in
          (match mdal_loops_json ~config:state.Mcp_server.room_config httpun_request with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error msg ->
              h2_respond_json h2_reqd
                (Yojson.Safe.to_string (mdal_loops_error_json msg))
                ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane" ->
          let state = get_server_state () in
          let json = command_plane_snapshot_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/summary" ->
          let state = get_server_state () in
          let json = command_plane_summary_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/help" ->
          let json = command_plane_help_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/topology" ->
          let state = get_server_state () in
          let json = command_plane_topology_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          let json = command_plane_units_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          let json = command_plane_operations_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachments" ->
          let state = get_server_state () in
          let json = command_plane_detachments_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachment-status" ->
          let state = get_server_state () in
          (match command_plane_detachment_status_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane/decisions" ->
          let state = get_server_state () in
          let json = command_plane_decisions_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/capacity" ->
          let state = get_server_state () in
          let json = command_plane_capacity_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/alerts" ->
          let state = get_server_state () in
          let json = command_plane_alerts_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/traces" ->
          let state = get_server_state () in
          let json = command_plane_traces_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/swarm" ->
          let state = get_server_state () in
          let json = command_plane_swarm_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/chains/summary" ->
          let state = get_server_state () in
          (match command_plane_chain_summary_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)

      | `GET, "/api/v1/chains/events" ->
          command_plane_chain_events_h2 ~request:httpun_request h2_reqd

      | `GET, path when String.length path > String.length "/api/v1/chains/runs/"
                        && String.sub path 0 (String.length "/api/v1/chains/runs/")
                           = "/api/v1/chains/runs/" ->
          let state = get_server_state () in
          let prefix_len = String.length "/api/v1/chains/runs/" in
          let run_id =
            String.sub path prefix_len (String.length path - prefix_len)
          in
          (match command_plane_chain_run_http_json ~state httpun_request run_id with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)
      | `GET, "/api/v1/command-plane/policy" ->
          let state = get_server_state () in
          let json = command_plane_policy_status_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/operator" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () ->
                 let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
                 h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)
          else
            let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
      | `GET, "/api/v1/operator/digest" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          let respond_digest () =
            match operator_digest_http_json ~state ~sw ~clock httpun_request with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
            | Error message ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (operator_error_json message))
                  ~status:`Bad_request ~extra_headers:cors
          in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () -> respond_digest ())
          else
            respond_digest ()
      | `GET, "/api/v1/status" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_state = Masc_mcp.Room.read_state config in
          let tempo = Masc_mcp.Tempo.get_tempo config in
          let json = `Assoc [
            ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
            ("project", `String room_state.project);
            ("tempo_interval_s", `Float tempo.current_interval_s);
            ("paused", `Bool room_state.paused);
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/credits" ->
          h2_respond_json h2_reqd (Masc_mcp.Credits_dashboard.json_api ()) ~extra_headers:cors

      | `GET, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_id = Option.value ~default:"default" (Masc_mcp.Room.read_current_room config) in
          let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `POST, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          h2_read_body h2_reqd (fun body_str ->
            try
              let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     h2_respond_json h2_reqd
                       (Yojson.Safe.to_string (trpg_error_json "room_id cannot be empty"))
                       ~status:`Bad_request ~extra_headers:cors
                   else (
                     Masc_mcp.Room.write_current_room config room_id;
                     Masc_mcp.Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     h2_respond_json h2_reqd (Yojson.Safe.to_string response) ~extra_headers:cors))
            with
            | Yojson.Json_error msg ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json (Printf.sprintf "invalid json: %s" msg)))
                  ~status:`Bad_request ~extra_headers:cors
            )

      | `POST, "/api/v1/operator/action" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_action_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_unit_define_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reparent" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reparent_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reassign" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reassign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_start_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~status:`Created ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/checkpoint" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_checkpoint_http_json ~state
                        httpun_request ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/pause" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_pause_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/resume" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_resume_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/stop" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_stop_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/finalize" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_finalize_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/plan" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_plan_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/assign" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_assign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/rebalance" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_rebalance_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/escalate" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_escalate_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/recall" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_recall_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/tick" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_tick_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/approve" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_approve_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/deny" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_deny_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/update" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_update_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/freeze" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_freeze_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/kill-switch" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_kill_switch_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/operator/confirm" ->
          let state = get_server_state () in
          (match authorize_permission_request
                    ~base_path:state.Mcp_server.room_config.base_path
                    ~permission:Types.CanBroadcast httpun_request with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_confirm_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_append_event_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite" (query_param httpun_request "rule_module")
          in
          (match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/catalog" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match
             trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/preflight" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          let dm_keeper = query_param httpun_request "dm" in
          let player_keepers =
            query_param httpun_request "players" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          let models =
            query_param httpun_request "models" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          (match
             trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module ~dm_keeper ~player_keepers ~models
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/overview" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_overview_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/control/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_control_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/models" ->
          h2_respond_json h2_reqd
            (Yojson.Safe.to_string (trpg_available_models_json ()))
            ~extra_headers:cors

      | `POST, "/api/v1/trpg/dice/roll" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_dice_roll_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/turns/advance" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_turn_advance_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/rounds/run" ->
          let state = get_server_state () in
          h2_read_body h2_reqd (fun body_str ->
            let agent_name =
              Option.value
                ~default:"dashboard"
                (agent_from_request httpun_request)
            in
            match !current_sw, !current_clock with
            | Some sw, Some clock -> (
                match
                  trpg_round_run_json
                    ~state
                    ~agent_name
                    ~sw
                    ~clock
                    ~idempotency_key:
                      (get_header_any_case httpun_request.headers "idempotency-key")
                    ~body_str
                with
                | Ok json ->
                    h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                      ~extra_headers:cors
                | Error (`Bad_request, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
                | Error (`Internal_server_error, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Internal_server_error ~extra_headers:cors)
            | _ ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string
                     (trpg_error_json "trpg runtime not initialized"))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/stream" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/timeline" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          let actor_filter = query_param httpun_request "actor" in
          let phase_filter = query_param httpun_request "phase" in
          let limit =
            int_query_param httpun_request "limit" ~default:50
            |> clamp ~min_v:1 ~max_v:200
          in
          (match
             trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
               ~actor_filter ~phase_filter ~limit
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/stream/sse" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let event_type_filter = query_param httpun_request "event_type" in
          let room_id_trimmed = String.trim room_id in
          if room_id_trimmed = "" then
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json "room_id is required"))
              ~status:`Bad_request ~extra_headers:cors
          else begin
            match trpg_parse_event_type_filter event_type_filter with
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Ok event_type_opt ->
                let last_event_id =
                  match H2.Headers.get (H2.Reqd.request h2_reqd).headers "last-event-id" with
                  | Some id -> (try int_of_string id with Failure _ -> 0)
                  | None -> 0
                in
                let headers = H2.Headers.of_list ([
                  ("content-type", "text/event-stream");
                  ("cache-control", "no-cache");
                ] @ cors) in
                let response = H2.Response.create ~headers `OK in
                let writer = H2.Reqd.respond_with_streaming
                  ~flush_headers_immediately:true h2_reqd response in
                let closed = ref false in
                let last_seq = ref last_event_id in

                let send data =
                  if !closed || H2.Body.Writer.is_closed writer then begin
                    closed := true; false
                  end else begin
                    H2.Body.Writer.write_string writer data;
                    H2.Body.Writer.flush writer ignore;
                    true
                  end
                in

                let init_comment =
                  Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
                    room_id_trimmed !last_seq in
                ignore (send init_comment);

                (* Send existing events *)
                (match
                   (if !last_seq > 0 then
                      Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                        ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                    else
                      Masc_mcp.Trpg_engine_store_sqlite.read_events
                        ~base_dir ~room_id:room_id_trimmed)
                 with
                 | Ok events ->
                     let events = match event_type_opt with
                       | None -> events
                       | Some et ->
                           List.filter (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                             ev.event_type = et) events
                     in
                     List.iter (fun ev ->
                       if not !closed then begin
                         ignore (send (trpg_event_to_sse ev));
                         last_seq := max !last_seq ev.Masc_mcp.Trpg_engine_event.seq
                       end) events
                 | Error _ -> ());

                (* Poll loop *)
                (match !current_sw, !current_clock with
                 | Some sw, Some clock ->
                     Eio.Fiber.fork ~sw (fun () ->
                       let is_cancelled = function
                         | Eio.Cancel.Cancelled _ -> true | _ -> false in
                       let keepalive_counter = ref 0 in
                       let polls_per_keepalive =
                         max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s)) in
                       let rec loop () =
                         if not !closed then begin
                           (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                            with exn -> if is_cancelled exn then raise exn);
                           if not !closed then begin
                             (match
                                Masc_mcp.Trpg_engine_store_sqlite.read_events_after
                                  ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                              with
                              | Ok events ->
                                  let events = match event_type_opt with
                                    | None -> events
                                    | Some et ->
                                        List.filter (fun (ev : Masc_mcp.Trpg_engine_event.t) ->
                                          ev.event_type = et) events
                                  in
                                  List.iter (fun ev ->
                                    if not !closed then begin
                                      if not (send (trpg_event_to_sse ev)) then
                                        closed := true
                                      else
                                        last_seq := max !last_seq
                                          ev.Masc_mcp.Trpg_engine_event.seq
                                    end) events
                              | Error _ -> ());
                             incr keepalive_counter;
                             if !keepalive_counter >= polls_per_keepalive then begin
                               keepalive_counter := 0;
                               if not !closed then ignore (send ": keepalive\n\n")
                             end
                           end;
                           loop ()
                         end else
                           H2.Body.Writer.close writer
                       in
                       try loop () with exn ->
                         if not (is_cancelled exn) then
                           Printf.eprintf "[TRPG-SSE/H2] poll error for room %s: %s\n%!"
                             room_id_trimmed (Printexc.to_string exn))
                 | _ ->
                     ignore (send "event: error\ndata: {\"error\":\"server not ready\"}\n\n");
                     H2.Body.Writer.close writer)
          end

      | `POST, "/api/v1/trpg/actors/spawn" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match
              trpg_actor_spawn_json ~base_dir
                ~idempotency_key:
                  (get_header_any_case httpun_request.headers "idempotency-key")
                ~body_str
            with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/claim" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_claim_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/release" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_release_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/tts" ->
          h2_read_body h2_reqd (fun body_str ->
            match trpg_tts_proxy ~body_str with
            | Ok audio_bytes ->
                h2_respond_bytes ~content_type:"audio/mpeg"
                  ~extra_headers:cors h2_reqd audio_bytes
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
            | Error (_, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/council/debates" ->
          let state = get_server_state () in
          let base_path = state.Mcp_server.room_config.base_path in
          let json = council_debates_json httpun_request ~base_path in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/council/sessions" ->
          let json = council_sessions_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board" ->
          let hearth = query_param httpun_request "hearth" in
          let sort_by = board_sort_order_of_request httpun_request in
          let exclude_system = bool_query_param httpun_request "exclude_system" ~default:false in
          let limit = int_query_param httpun_request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
          let offset = int_query_param httpun_request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
          let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
          let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
          let posts = filter_board_posts ~exclude_system posts in
          let karma_map = Board_dispatch.get_all_karma () in
          let get_karma author =
            try List.assoc author karma_map with Not_found -> 0
          in
          let paged = posts |> drop offset |> take limit in
          let posts_json = List.map (fun (p : Board.post) ->
            let author = Board.Agent_id.to_string p.author in
            board_post_dashboard_json ~author_karma:(get_karma author) p
          ) paged in
          let json = `Assoc [
            ("posts", `List posts_json);
            ("count", `Int (List.length posts_json));
            ("limit", `Int limit);
            ("offset", `Int offset);
            ("sort_by", `String (board_sort_label sort_by));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/hearths" ->
          let hearths = Board_dispatch.list_hearths () in
          let json = `Assoc [
            ("hearths", `List (List.map (fun (name, count) ->
              `Assoc [("name", `String name); ("count", `Int count)]
            ) hearths));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/flairs" ->
          let flairs = List.map Board.flair_to_yojson Board.available_flairs in
          let json = `Assoc [("flairs", `List flairs)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, p
        when String.length p > 32
             && String.length p >= 24 + 8
             && String.sub p 0 24 = "/api/v1/council/debates/"
             && String.ends_with ~suffix:"/summary" p ->
          let prefix_len = 24 in
          let suffix_len = 8 in
          let debate_id_len = String.length p - prefix_len - suffix_len in
          if debate_id_len <= 0 then
            h2_respond_json h2_reqd {|{"error":"debate_id missing"}|}
              ~status:`Bad_request ~extra_headers:cors
          else
            let debate_id = String.sub p prefix_len debate_id_len in
            let state = get_server_state () in
            let base_path = state.Mcp_server.room_config.base_path in
            let (status, json) = council_debate_summary_json ~base_path ~debate_id in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~status ~extra_headers:cors

      | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
          let post_id = String.sub p 14 (String.length p - 14) in
          let format = Option.value ~default:"nested" (query_param httpun_request "format") in
          let (status, body) = board_post_detail_json ~response_format:format ~post_id in
          h2_respond_json h2_reqd body ~status ~extra_headers:cors

      | `GET, "/api/v1/karma" ->
          let karma_list = Board_dispatch.get_all_karma () in
          let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
          let json = `Assoc [
            ("karma", `List (List.map (fun (agent, k) ->
              `Assoc [("agent", `String agent); ("karma", `Int k)]
            ) sorted));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         Static Assets
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/static/css/middleware.css" ->
          (match read_file (playground_asset_path "static/css/middleware.css") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "text/css; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      | `GET, "/static/js/middleware.js" ->
          (match read_file (playground_asset_path "static/js/middleware.js") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "application/javascript; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* Dashboard SPA: static assets *)
      | `GET, p when String.length p > 18
                   && String.sub p 0 18 = "/dashboard/assets/" ->
          let filename = String.sub p 18 (String.length p - 18) in
          if not (Masc_mcp.Web_dashboard.is_safe_asset_relative_path filename) then
            h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
          else
            let file_path = Filename.concat (dashboard_asset_root ()) ("assets/" ^ filename) in
            (match read_file file_path with
             | Ok body ->
                 let ct = asset_content_type filename in
                 let headers = H2.Headers.of_list [
                   ("content-type", ct);
                   ("content-length", string_of_int (String.length body));
                   ("cache-control", "public, max-age=31536000, immutable");
                 ] in
                 let response = H2.Response.create ~headers `OK in
                 let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
                 H2.Body.Writer.write_string writer body;
                 H2.Body.Writer.close writer
             | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    try
      if
        http_auth_strict_enabled ()
        && httpun_meth <> `OPTIONS
        && String.starts_with ~prefix:"/api/v1/trpg/" path
      then
        match authorize_read_request ~base_path httpun_request with
        | Ok () -> dispatch_h2_route ()
        | Error err ->
            let status = http_status_of_auth_error err in
            h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
      else
        dispatch_h2_route ()
    with exn ->
      let msg = Printexc.to_string exn in
      Printf.eprintf "[H2] Handler error: %s\n%!" msg;
      h2_respond_text h2_reqd ("500 Internal Server Error: " ^ msg) ~status:`Internal_server_error ~extra_headers:cors
  in
  let _ = request_handler in (* suppress warning - legacy httpun handler *)

  (* H2 error handler *)
  let _h2_error_handler _client_addr ?request:_ error respond =
    let msg = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Bad_gateway -> "Bad gateway"
      | `Internal_server_error -> "Internal server error"
    in
    let headers = H2.Headers.of_list [
      ("content-type", "text/plain");
      ("content-length", string_of_int (String.length msg));
    ] in
    let body = respond headers in
    H2.Body.Writer.write_string body msg;
    H2.Body.Writer.close body
  in

  (* HTTP/1.1 accept loop - Cloudflare Tunnel HTTP origin *)
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          Eio.Switch.on_release conn_sw (fun () ->
            try Eio.Flow.close flow with _ -> ()
          );
          try
            (* HTTP/1.1 with httpun-eio - Cloudflare provides h2 to browser *)
            let conn_handler = Httpun_eio.Server.create_connection_handler
              ~sw:conn_sw
              ~request_handler:(fun client_addr -> request_handler client_addr)
              ~error_handler:(fun _client_addr ?request:_ error respond ->
                let msg = match error with
                  | `Exn exn -> Printexc.to_string exn
                  | `Bad_request -> "Bad request"
                  | `Bad_gateway -> "Bad gateway"
                  | `Internal_server_error -> "Internal server error"
                in
                let body = respond (Httpun.Headers.of_list [("content-type", "text/plain")]) in
                Httpun.Body.Writer.write_string body msg;
                Httpun.Body.Writer.close body)
            in
            conn_handler client_addr flow
          with exn ->
            Printf.eprintf "[HTTP] Connection error: %s\n%!" (Printexc.to_string exn)
        )
      );
      accept_loop 0.05
    with exn ->
      if is_cancelled exn then ()
      else begin
        Printf.eprintf "Accept error: %s\n%!" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s with _ -> ());
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

(** CLI options *)
let port =
  let doc = "Port to listen on" in
  Arg.(value & opt int 8935 & info ["p"; "port"] ~docv:"PORT" ~doc)

let base_path =
  let doc = "Base path for MASC data (.masc folder location)" in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

(** Graceful shutdown exception *)
exception Shutdown

let run_cmd port base_path =
  Eio_main.run @@ fun env ->
  (* Initialize Mirage_crypto RNG - MUST be inside Eio_main.run for thread-local state *)
  Mirage_crypto_rng_unix.use_default ();

  (* Enable Eio-aware locking in Prometheus metrics *)
  Masc_mcp.Prometheus.enable_eio ();
  Masc_mcp.Llm_response_cache.enable_eio ();

  (* Set global clock for Time_compat (Eio-native timestamps) *)
  Masc_mcp.Time_compat.set_clock (Eio.Stdenv.clock env);

  (* Initialize thread-safe token store for cancellation support *)
  Masc_mcp.Cancellation.TokenStore.init ();

  (* Graceful shutdown setup *)
  let switch_ref = ref None in
  let shutdown_initiated = ref false in
  let initiate_shutdown signal_name =
    if not !shutdown_initiated then begin
      shutdown_initiated := true;
      Printf.eprintf "\n🚀 MASC MCP: Received %s, shutting down gracefully...\n%!" signal_name;

      (* Broadcast shutdown notification to all SSE clients *)
      let shutdown_data = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
        signal_name
      in
      Sse.broadcast (Yojson.Safe.from_string shutdown_data);
      Printf.eprintf "🚀 MASC MCP: Sent shutdown notification to %d SSE clients\n%!" (Sse.client_count ());

      (* Give clients 200ms to receive the notification *)
      Unix.sleepf 0.2;

      (* Run all shutdown hooks (cancel orchestrator, close SSE, etc.) *)
      Masc_mcp.Shutdown_hooks.run_all ();

      (* Flush dirty board data to prevent data loss *)
      (try Board_dispatch.flush ()
       with _ -> Printf.eprintf "[Shutdown] Board flush skipped (not initialized)\n%!");

      (* Also close local SSE connections tracked in main_eio *)
      close_all_sse_connections ();

      (* Give connections 200ms to complete close handshake *)
      Unix.sleepf 0.2;

      match !switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  let max_bind_retries = 5 in
  let rec try_start attempt =
    (try
      Eio.Switch.run @@ fun sw ->
      switch_ref := Some sw;
      run_server ~sw ~env ~port ~base_path
    with
    | Shutdown ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Eio.Cancel.Cancelled _ ->
        Printf.eprintf "🚀 MASC MCP: Shutdown complete.\n%!"
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) when attempt < max_bind_retries ->
        let delay = Float.min 30.0 (2.0 ** Float.of_int attempt) in
        Printf.eprintf "⚠️  Port %d in use, retrying in %.0fs (attempt %d/%d)...\n%!"
          port delay (attempt + 1) max_bind_retries;
        Time_compat.sleep delay;
        try_start (attempt + 1)
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Port %d is still in use after %d retries.\n%!"
          port max_bind_retries;
        Printf.eprintf "   Try: lsof -i :%d | grep LISTEN\n%!" port;
        exit 1
    | Unix.Unix_error (Unix.EACCES, _, _) ->
        Printf.eprintf "❌ [MASC FATAL] Permission denied binding to port %d.\n%!" port;
        exit 1)
  in
  try_start 0

let cmd =
  let doc = "MASC MCP Server" in
  let info = Cmd.info "masc-mcp" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ port $ base_path)

let () = exit (Cmd.eval cmd)
