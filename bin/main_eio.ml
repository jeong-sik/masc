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
module Tool_audit = Masc_mcp.Tool_audit
module Graphql_api = Masc_mcp.Graphql_api
module Types = Masc_mcp.Types
module Tempo = Masc_mcp.Tempo
module Auth = Masc_mcp.Auth
module Board = Masc_mcp.Board
module Board_dispatch = Masc_mcp.Board_dispatch
module Board_listener = Masc_mcp.Board_listener
module Task_dispatch = Masc_mcp.Task_dispatch
module Http_negotiation = Masc_mcp.Mcp_protocol.Http_negotiation
module Progress = Masc_mcp.Progress
module Sse = Masc_mcp.Sse
module Safe_ops = Masc_mcp.Safe_ops
module Context_manager = Masc_mcp.Context_manager
module Llm_client = Masc_mcp.Llm_client
module Tool_perpetual = Masc_mcp.Tool_perpetual

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

let mcp_protocol_versions = [
  "2024-11-05";
  "2025-03-26";
  "2025-11-25";
]

let mcp_protocol_version_default = "2025-11-25"

let protocol_version_by_session : (string, string) Hashtbl.t = Hashtbl.create 128

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

let get_cookie_value (request : Httpun.Request.t) cookie_name =
  match Httpun.Headers.get request.headers "cookie" with
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
      (match Httpun.Headers.get request.headers "mcp-session-id" with
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

type trpg_api_error_kind = [ `Bad_request | `Internal_server_error ]
type trpg_api_result = (Yojson.Safe.t, trpg_api_error_kind * string) result

let trpg_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]

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
        | Error e -> Error (`Internal_server_error, e)
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
  let room_id = String.trim room_id in
  if room_id = "" then
    Error (`Bad_request, "room_id is required")
  else
    match trpg_rule_by_id rule_module with
    | Error _ as e -> e
    | Ok rule -> (
        match Masc_mcp.Trpg_engine_store_sqlite.read_events ~base_dir ~room_id with
        | Error e -> Error (`Internal_server_error, e)
        | Ok events ->
            let config = trpg_extract_config_from_events events in
            let state =
              Masc_mcp.Trpg_engine_replay.derive_state ~rule ~config ~events
            in
            let module R = (val rule : Masc_mcp.Trpg_rule.S) in
            Ok
              (`Assoc
                [
                  ("ok", `Bool true);
                  ("room_id", `String room_id);
                  ("rule_module", `String R.id);
                  ("event_count", `Int (List.length events));
                  ("state", state);
                ]))

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

let trpg_turn_advance_json ~base_dir ~body_str : trpg_api_result =
  try
    let json = Yojson.Safe.from_string body_str in
    let ( let* ) r f = match r with Ok v -> f v | Error _ as e -> e in
    let* room_id = trpg_parse_required_string "room_id" json in
    let* rule_module_opt = trpg_parse_optional_string "rule_module" json in
    let rule_module = Option.value ~default:"dnd5e-lite" rule_module_opt in
    let* _rule = trpg_rule_by_id rule_module in
    let* phase_opt = trpg_parse_optional_string "phase" json in
    let* () =
      match phase_opt with
      | None -> Ok ()
      | Some p -> (
          match Masc_mcp.Trpg_engine_types.phase_of_string p with
          | Ok _ -> Ok ()
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

let trpg_keeper_call_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
    ~message
    ~timeout_sec
  : Masc_mcp.Tool_trpg.keeper_call_result =
  let keeper_ctx : _ Masc_mcp.Tool_keeper.context = { config; sw; clock } in
  let keeper_args =
    `Assoc [ ("name", `String keeper_name); ("message", `String message) ]
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

let trpg_round_run_json
    ~(state : Mcp_server.server_state)
    ~(agent_name : string)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~body_str
  : trpg_api_result =
  try
    let args = Yojson.Safe.from_string body_str in
    let keeper_call =
      trpg_keeper_call_with_runtime
        ~config:state.Mcp_server.room_config
        ~sw
        ~clock
    in
    let trpg_ctx : Masc_mcp.Tool_trpg.context =
      { config = state.Mcp_server.room_config; agent_name; keeper_call = Some keeper_call }
    in
    match Masc_mcp.Tool_trpg.dispatch trpg_ctx ~name:"masc_trpg_round_run" ~args with
    | None ->
        Error (`Internal_server_error, "masc_trpg_round_run dispatch unavailable")
    | Some (false, msg) -> Error (`Bad_request, msg)
    | Some (true, body) -> (
        try Ok (Yojson.Safe.from_string body)
        with Yojson.Json_error e ->
          Error (`Internal_server_error, Printf.sprintf "invalid tool json: %s" e))
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
let cors_headers origin = [
  ("access-control-allow-origin", origin);
  ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
  ("access-control-allow-headers",
   "Content-Type, Accept, Origin, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-Id");
  ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ("access-control-allow-credentials", "true");
]

let respond_auth_error request reqd err =
  let status = http_status_of_auth_error err in
  let origin = get_origin request in
  let body = Yojson.Safe.to_string (`Assoc [
    ("error", `String (Types.masc_error_to_string err));
  ]) in
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
let with_public_read handler request reqd =
  match !server_state with
  | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
  | Some state -> handler state request reqd

(** Authenticated read access - requires valid token when auth enabled *)
let with_read_auth handler request reqd =
  match !server_state with
  | None -> Http.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = state.Mcp_server.room_config.base_path in
      let auth_cfg = Auth.load_auth_config base_path in
      let agent_name_opt = agent_from_request request in
      let token = auth_token_from_request request in
      let agent_name = Option.value ~default:"dashboard" agent_name_opt in
      if auth_cfg.enabled && auth_cfg.require_token && agent_name_opt = None then
        respond_auth_error request reqd (Types.Unauthorized "Agent name required")
      else
        match Auth.check_permission base_path ~agent_name ~token ~permission:Types.CanReadState with
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
      with _ -> ())
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

let keepers_dashboard_json (config : Room.config) : Yojson.Safe.t =
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
          let keepalive_running = Hashtbl.mem Tool_keeper.keepalives m.name in
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
            keeper_metrics_24h_json ~metrics_path ~now_ts
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
              ("drift_applied_count", `Int !drift_applied_count);
              ("drift_applied_rate", `Float drift_applied_rate);
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
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
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
	            `Assoc [
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ("goal", if include_goals then `String m.goal else `Null);
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
	              ("last_metrics", match last_metrics with None -> `Null | Some j -> j);
	              ("metrics_series", metrics_series);
              ("metrics_window", metrics_window_summary);
              ("metrics_24h", metrics_24h);
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
              ("memory_bank", memory_bank_json);
              ("conversation_tail", conversation_tail);
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("conversation_fragment_filter_enabled", `Bool history_fragment_filter_enabled);
              ("k2k_recent", k2k_recent);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("last_handoff_event", match last_handoff_event with Some j -> j | None -> `Null);
              ("last_compaction_event", match last_compaction_event with Some j -> j | None -> `Null);
              ("context", context);
              ("context_source", context_source);
            ]
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

let dashboard_batch_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let tasks = Room.get_tasks_raw config in
  let agents = Room.get_agents_raw config in
  let msgs = Room.get_messages_raw config ~since_seq:0 ~limit:20 in
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
           match t.task_status with Types.Done _ | Types.Cancelled _ -> false | _ -> true)
         tasks)
  in
  let agents_json =
    List.map (fun (a : Types.agent) ->
      `Assoc [
        ("name", `String a.name);
        ("status", `String (Types.string_of_agent_status a.status));
        ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
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
    ("keepers", keepers_dashboard_json config);
    ("perpetual", perpetual_dashboard_json ());
  ]

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

(** Force JSON responses for POST /mcp (compatibility fallback). *)
let force_json_response =
  match Sys.getenv_opt "MASC_FORCE_JSON_RESPONSE" with
  | Some "1" -> true
  | _ ->
      (match Sys.getenv_opt "MCP_FORCE_JSON_RESPONSE" with
      | Some "1" -> true
      | _ -> false)

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
  match Sys.getenv_opt "MASC_ASSETS_DIR" with
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

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers",
     "Content-Type, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-Id, Accept, Origin");
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
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Masc_mcp.Sse.client_count ()));
    ("lodge", lodge_json);
    ("guardian", guardian_json);
  ] in
  Http.Response.json (Yojson.Safe.to_string health_json) reqd

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""

(** Eio switch and clock references for MCP handlers *)
let current_sw : Eio.Switch.t option ref = ref None
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None
let current_net : _ Eio.Net.t option ref = ref None

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
    let state = match !server_state with
      | Some s -> s
      | None -> failwith "Server state not initialized"
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
let handle_post_mcp request reqd =
  let origin = get_origin request in
  let session_id =
    match get_session_id_any request with
    | Some id -> id
    | None -> Mcp_session.generate ()
  in
  let auth_token = auth_token_from_request request in

  Http.Request.read_body_async reqd (fun body_str ->
    try
      let state = match !server_state with
        | Some s -> s
        | None -> failwith "Server state not initialized"
      in
      let sw = match !current_sw with
        | Some s -> s
        | None -> failwith "Eio switch not initialized"
      in
      let clock = match !current_clock with
        | Some c -> c
        | None -> failwith "Eio clock not initialized"
      in
      let response_json =
        Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id ?auth_token state body_str
      in
      (match protocol_version_from_body body_str with
       | Some v -> remember_protocol_version session_id v
       | None -> ());
      let protocol_version = get_protocol_version_for_session ~session_id request in
      if not (accepts_streamable_mcp request) then
        let body = json_rpc_error (-32600)
          "Invalid Accept header: must include application/json and text/event-stream"
        in
        let headers = Httpun.Headers.of_list (
          ("content-length", string_of_int (String.length body))
          :: json_headers session_id protocol_version origin
        ) in
        let response = Httpun.Response.create ~headers `Bad_request in
        Httpun.Reqd.respond_with_string reqd response body
      else
        let wants_sse = accepts_sse request && not force_json_response in
        if wants_sse then begin
          match response_json with
          | `Null ->
              let headers = Httpun.Headers.of_list (
                ("content-length", "0")
                :: mcp_headers session_id protocol_version
              ) in
              let response = Httpun.Response.create ~headers `Accepted in
              Httpun.Reqd.respond_with_string reqd response ""
          | json when is_http_error_response json ->
              let body = Yojson.Safe.to_string json in
              let headers = Httpun.Headers.of_list (
                ("content-length", string_of_int (String.length body))
                :: json_headers session_id protocol_version origin
              ) in
              let response = Httpun.Response.create ~headers `Bad_request in
              Httpun.Reqd.respond_with_string reqd response body
          | json ->
              let event = Sse.format_event ~event_type:"message" (Yojson.Safe.to_string json) in
              let body = sse_prime_event () ^ event in
              let headers = Httpun.Headers.of_list (
                ("content-length", string_of_int (String.length body))
                :: sse_headers session_id protocol_version origin
              ) in
              let response = Httpun.Response.create ~headers `OK in
              Httpun.Reqd.respond_with_string reqd response body
        end else begin
          match response_json with
          | `Null ->
              let headers = Httpun.Headers.of_list (
                ("content-length", "0")
                :: mcp_headers session_id protocol_version
              ) in
              let response = Httpun.Response.create ~headers `Accepted in
              Httpun.Reqd.respond_with_string reqd response ""
          | json when is_http_error_response json ->
              let body = Yojson.Safe.to_string json in
              let headers = Httpun.Headers.of_list (
                ("content-length", string_of_int (String.length body))
                :: json_headers session_id protocol_version origin
              ) in
              let response = Httpun.Response.create ~headers `Bad_request in
              Httpun.Reqd.respond_with_string reqd response body
          | json ->
              let body = Yojson.Safe.to_string json in
              let headers = Httpun.Headers.of_list (
                ("content-length", string_of_int (String.length body))
                :: json_headers session_id protocol_version origin
              ) in
              let response = Httpun.Response.create ~headers `OK in
              Httpun.Reqd.respond_with_string reqd response body
        end
    with exn ->
      let protocol_version = get_protocol_version_for_session ~session_id request in
      let body = json_rpc_error (-32603) ("Internal error: " ^ Printexc.to_string exn) in
      let headers = Httpun.Headers.of_list (
        ("content-length", string_of_int (String.length body))
        :: json_headers session_id protocol_version origin
      ) in
        let response = Httpun.Response.create ~headers `Internal_server_error in
        Httpun.Reqd.respond_with_string reqd response body
  )

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

let handle_get_mcp ?legacy_messages_endpoint request reqd =
  let origin = get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
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
      (* Replace existing connection for session_id *)
      stop_sse_session session_id;

      let headers = Httpun.Headers.of_list (sse_stream_headers session_id protocol_version origin) in
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
          session_id client_count Sse.max_clients

(** SSE simple handler - for compatibility, returns single event *)
let sse_simple_handler request reqd =
  let origin = get_origin request in
  let session_id = Mcp_session.get_or_generate (get_session_id_any request) in
  let protocol_version = get_protocol_version_for_session ~session_id request in
  let event = sse_prime_event ()
              ^ Sse.format_event ~event_type:"connected"
                  (Printf.sprintf {|{"session_id":"%s"}|} session_id)
  in
  let headers = Httpun.Headers.of_list (
    ("content-length", string_of_int (String.length event))
    :: sse_headers session_id protocol_version origin
  ) in
  let response = Httpun.Response.create ~headers `OK in
  Httpun.Reqd.respond_with_string reqd response event

(** POST /messages - Legacy SSE transport (client->server messages) *)
let handle_post_messages request reqd =
  let origin = get_origin request in
  match get_session_id_any request with
  | None ->
      let body = "session_id required" in
      let headers = Httpun.Headers.of_list (
        ("content-length", string_of_int (String.length body))
        :: cors_headers origin
      ) in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id when not (Mcp_session.is_valid session_id) ->
      let body = "invalid session_id" in
      let headers = Httpun.Headers.of_list (
        ("content-length", string_of_int (String.length body))
        :: cors_headers origin
      ) in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id ->
      let protocol_version = get_protocol_version_for_session ~session_id request in
      let auth_token = auth_token_from_request request in
      Http.Request.read_body_async reqd (fun body_str ->
        let state = match !server_state with
          | Some s -> s
          | None -> failwith "Server state not initialized"
        in
        let sw = match !current_sw with
          | Some s -> s
          | None -> failwith "Eio switch not initialized"
        in
        let clock = match !current_clock with
          | Some c -> c
          | None -> failwith "Eio clock not initialized"
        in
        let response_json =
          Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id ?auth_token state body_str
        in
        (match response_json with
         | `Null -> ()
         | json -> Sse.send_to session_id json);
        let headers = Httpun.Headers.of_list (
          ("content-length", "0")
          :: mcp_headers session_id protocol_version
        ) in
        let response = Httpun.Response.create ~headers `Accepted in
        Httpun.Reqd.respond_with_string reqd response ""
      )

(** DELETE /mcp - Session termination *)
let handle_delete_mcp request reqd =
  match get_session_id_any request with
  | Some session_id ->
      stop_sse_session session_id;
      Sse.unregister session_id;
      Hashtbl.remove protocol_version_by_session session_id;
      Printf.printf "🔚 Session terminated: %s\n%!" session_id;
      let headers = Httpun.Headers.of_list (
        ("content-length", "0")
        :: mcp_headers session_id (get_protocol_version request)
      ) in
      let response = Httpun.Response.create ~headers `No_content in
      Httpun.Reqd.respond_with_string reqd response ""
  | None ->
      let body = "Mcp-Session-Id required" in
      let headers = Httpun.Headers.of_list [
        ("content-length", string_of_int (String.length body));
      ] in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body

(** Build routes for MCP server *)
let make_routes ~port ~host =
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
  |> Http.Router.get "/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Response.html_cached
           ~etag:(Masc_mcp.Web_dashboard.etag ())
           ~request:req
           (Masc_mcp.Web_dashboard.html ()) reqd
       ) request reqd)
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
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
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
             Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error (`Bad_request, msg) ->
             Http.Response.json ~status:`Bad_request (Yojson.Safe.to_string (trpg_error_json msg)) reqd
         | Error (`Internal_server_error, msg) ->
             Http.Response.json ~status:`Internal_server_error
               (Yojson.Safe.to_string (trpg_error_json msg))
               reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_append_event_json ~base_dir ~body_str with
           | Ok json ->
               Http.Response.json ~status:`Created (Yojson.Safe.to_string json) reqd
           | Error (`Bad_request, msg) ->
               Http.Response.json ~status:`Bad_request
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
           | Error (`Internal_server_error, msg) ->
               Http.Response.json ~status:`Internal_server_error
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error (`Bad_request, msg) ->
             Http.Response.json ~status:`Bad_request (Yojson.Safe.to_string (trpg_error_json msg)) reqd
         | Error (`Internal_server_error, msg) ->
             Http.Response.json ~status:`Internal_server_error
               (Yojson.Safe.to_string (trpg_error_json msg))
               reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/dice/roll" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_dice_roll_json ~base_dir ~body_str with
           | Ok json ->
               Http.Response.json ~status:`Created (Yojson.Safe.to_string json) reqd
           | Error (`Bad_request, msg) ->
               Http.Response.json ~status:`Bad_request
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
           | Error (`Internal_server_error, msg) ->
               Http.Response.json ~status:`Internal_server_error
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/turns/advance" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_turn_advance_json ~base_dir ~body_str with
           | Ok json ->
               Http.Response.json (Yojson.Safe.to_string json) reqd
           | Error (`Bad_request, msg) ->
               Http.Response.json ~status:`Bad_request
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
           | Error (`Internal_server_error, msg) ->
               Http.Response.json ~status:`Internal_server_error
                 (Yojson.Safe.to_string (trpg_error_json msg))
                 reqd
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
                 trpg_round_run_json ~state ~agent_name ~sw ~clock ~body_str
               with
               | Ok json ->
                   Http.Response.json (Yojson.Safe.to_string json) reqd
               | Error (`Bad_request, msg) ->
                   Http.Response.json ~status:`Bad_request
                     (Yojson.Safe.to_string (trpg_error_json msg))
                     reqd
               | Error (`Internal_server_error, msg) ->
                   Http.Response.json ~status:`Internal_server_error
                     (Yojson.Safe.to_string (trpg_error_json msg))
                     reqd)
           | _ ->
               Http.Response.json ~status:`Internal_server_error
                 (Yojson.Safe.to_string
                    (trpg_error_json "trpg runtime not initialized"))
                 reqd
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
             Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error (`Bad_request, msg) ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string (trpg_error_json msg))
               reqd
         | Error (`Internal_server_error, msg) ->
             Http.Response.json ~status:`Internal_server_error
               (Yojson.Safe.to_string (trpg_error_json msg))
               reqd
       ) request reqd)
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
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let json = dashboard_batch_json config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let posts = Board_dispatch.list_posts ?hearth () in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           try List.assoc author karma_map with Not_found -> 0
         in
         let posts_json = List.map (fun p ->
           Board_dispatch.post_to_yojson_with_karma p
             ~author_karma:(get_karma (Board.Agent_id.to_string p.author))
         ) posts in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts));
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
        | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
            let post_id = String.sub p 14 (String.length p - 14) in
            (match Board_dispatch.get_post ~post_id with
            | Error _ ->
                Http.Response.json {|{"error":"Post not found"}|} reqd
            | Ok post ->
                let comments = match Board_dispatch.get_comments ~post_id with
                  | Ok cs -> cs | Error _ -> []
                in
                let json = `Assoc [
                  ("post", Board.post_to_yojson post);
                  ("comments", `List (List.map Board.comment_to_yojson comments));
                ] in
                Http.Response.json (Yojson.Safe.to_string json) reqd)
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
  Masc_mcp.Process_eio.init ~proc_mgr ~clock;
  (* Initialize Lodge after Eio context is ready (requires net for GraphQL) *)
  Masc_mcp.Tool_lodge.init ();

  (* Create Caqti-compatible stdenv adapter
     Note: net type coercion from [Generic|Unix] to [Generic] is safe
     because Caqti only uses the generic network capabilities *)
  let caqti_env : Caqti_eio.stdenv = object
    method net = (net :> [`Generic] Eio.Net.ty Eio.Resource.t)
    method clock = clock
    method mono_clock = mono_clock
  end in

  (* Initialize server state with Eio context *)
  let state = Mcp_eio.create_state_eio ~sw ~env:caqti_env ~proc_mgr ~fs ~clock ~base_path in
  server_state := Some state;
  Mcp_server.set_sse_callback state Sse.broadcast;

  (* Keepers are meant to be long-lived. Start their keepalive fibers on startup
     so liveness/last_seen stays up-to-date even if no tool calls happen. *)
  (try
     let keeper_ctx : _ Tool_keeper.context = { config = state.room_config; sw; clock } in
     Tool_keeper.start_existing_keepalives keeper_ctx
   with _ -> ());

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
  let routes = make_routes ~port:config.port ~host:config.host in
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
  Printf.printf "   POST /mcp → JSON-RPC (Accept: text/event-stream for SSE)\n%!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf "   GET  /sse → legacy SSE stream (event: endpoint)\n%!";
  Printf.printf "   POST /messages → legacy client->server messages\n%!";
  Printf.printf "   GET  /health → Health check\n%!";

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
    let session_id_opt = get_session_id_any httpun_request in

    try
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

      (* ─────────────────────────────────────────────────────────────────────
         CORS Preflight
         ───────────────────────────────────────────────────────────────────── *)
      | `OPTIONS, _ ->
          h2_respond_empty h2_reqd ~extra_headers:(cors_preflight_headers origin)

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp" | `POST, "/" ->
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let auth_token = auth_token_from_request httpun_request in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          (match verify_mcp_auth ~base_path httpun_request with
          | Error msg ->
              let body = Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg in
              h2_respond_json h2_reqd body ~status:`Unauthorized ~extra_headers:(("www-authenticate", "Bearer") :: cors)
          | Ok _cred_opt ->
          h2_read_body h2_reqd (fun body_str ->
            let state = match !server_state with
              | Some s -> s
              | None -> failwith "Server state not initialized"
            in
            let response_json =
              Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id ?auth_token state body_str
            in
            (match protocol_version_from_body body_str with
             | Some v -> remember_protocol_version session_id v
             | None -> ());
            let protocol_version = get_protocol_version_for_session ~session_id httpun_request in
            let mcp_hdrs = mcp_headers session_id protocol_version @ cors in
            match response_json with
            | `Null ->
                h2_respond_empty h2_reqd ~status:`Accepted ~extra_headers:mcp_hdrs
            | json when is_http_error_response json ->
                let body = Yojson.Safe.to_string json in
                h2_respond_json h2_reqd body ~status:`Bad_request ~extra_headers:mcp_hdrs
            | json ->
                let body = Yojson.Safe.to_string json in
                h2_respond_json h2_reqd body ~extra_headers:mcp_hdrs
          ))  (* Close auth match + h2_read_body *)

      | `DELETE, "/mcp" ->
          (match session_id_opt with
           | Some session_id ->
               stop_sse_session session_id;
               Sse.unregister session_id;
               Hashtbl.remove protocol_version_by_session session_id;
               Printf.printf "🔚 Session terminated: %s\n%!" session_id;
               let mcp_hdrs = mcp_headers session_id (get_protocol_version httpun_request) in
               h2_respond_empty h2_reqd ~extra_headers:mcp_hdrs
           | None ->
               h2_respond_text h2_reqd "Mcp-Session-Id required" ~status:`Bad_request ~extra_headers:cors)

      (* ─────────────────────────────────────────────────────────────────────
         Dashboard
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/dashboard" ->
          let etag_value = "\"" ^ Masc_mcp.Web_dashboard.etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", "no-cache");
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let body = Masc_mcp.Web_dashboard.html () in
               let extra = [("etag", etag_value); ("cache-control", "no-cache"); ("vary", "Accept-Encoding")] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)

      | `GET, "/dashboard/credits" ->
          h2_respond_html h2_reqd (Masc_mcp.Credits_dashboard.html ()) ~extra_headers:cors

      | `GET, "/dashboard/lodge" ->
          let etag_value = "\"" ^ Masc_mcp.Lodge_dashboard.etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", "no-cache");
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let body = Masc_mcp.Lodge_dashboard.html () in
               let extra = [("etag", etag_value); ("cache-control", "no-cache")] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)

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
            let state = match !server_state with
              | Some s -> s
              | None -> failwith "Server state not initialized"
            in
            let response = Graphql_api.handle_request ~config:state.room_config body_str in
            let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
            h2_respond_json h2_reqd response.body ~status ~extra_headers:cors
          )

      (* ─────────────────────────────────────────────────────────────────────
         REST API
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/api/v1/dashboard" ->
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
          let config = state.Mcp_server.room_config in
          let json = dashboard_batch_json config in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/status" ->
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
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
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/events" ->
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
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
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
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

      | `POST, "/api/v1/trpg/dice/roll" ->
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
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
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
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
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
          h2_read_body h2_reqd (fun body_str ->
            let agent_name =
              Option.value
                ~default:"dashboard"
                (agent_from_request httpun_request)
            in
            match !current_sw, !current_clock with
            | Some sw, Some clock -> (
                match
                  trpg_round_run_json ~state ~agent_name ~sw ~clock ~body_str
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
          let state = match !server_state with Some s -> s | None -> failwith "Not initialized" in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/board" ->
          let hearth = query_param httpun_request "hearth" in
          let posts = Board_dispatch.list_posts ?hearth () in
          let karma_map = Board_dispatch.get_all_karma () in
          let get_karma author =
            try List.assoc author karma_map with Not_found -> 0
          in
          let posts_json = List.map (fun p ->
            Board_dispatch.post_to_yojson_with_karma p ~author_karma:(get_karma (Board.Agent_id.to_string p.author))
          ) posts in
          let json = `Assoc [("posts", `List posts_json); ("count", `Int (List.length posts))] in
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

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

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
