(** MCP Protocol Server Implementation - Eio Native

    Direct-style async MCP server using OCaml 5.x Effect Handlers.
    Legacy bridges have been eliminated as of 2026-01-11.

    Key adapters for Session.registry compatibility:
    - unregister_sync: Direct hashtable removal without extra mutex layer
    - wait_for_message_eio: Polling with Eio.Time.sleep
*)

[@@@warning "-32"]  (* Suppress unused values - kept for potential future use *)

(** Re-export types from Mcp_server for compatibility *)
type server_state = Mcp_server.server_state
type jsonrpc_request = Mcp_server.jsonrpc_request
type tool_profile =
  | Full
  | Operator_remote

(** {1 Network Context for LLM Chain Calls} *)

(** Type alias for generic Eio network capability *)
type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

(** Compatibility wrappers around the shared Eio_context singleton.
    Mcp_server_eio no longer owns a separate copy of these refs. *)
let set_net net = Eio_context.set_net net
let set_clock clock = Eio_context.set_clock clock
let get_clock_opt () = Eio_context.get_clock_opt ()
let get_clock () = Eio_context.get_clock ()
let get_net_opt () : eio_net option = Eio_context.get_net_opt ()
let get_net () : eio_net = Eio_context.get_net ()

(** Re-export pure functions from Mcp_server *)
let create_state ?test_mode:_ ~base_path () =
  (* test_mode is ignored - Mcp_server.create_state doesn't support it *)
  Mcp_server.create_state ~base_path

(** Create state with Eio context - required for PostgresNative backend *)
let create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~net ~base_path =
  let state = Mcp_server.create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~net:(net :> Eio_context.eio_net) ~base_path in
  (* Recover any previously running team sessions after server restart. *)
  (try Team_session_engine_eio.recover_running_sessions ~sw ~clock ~config:state.Mcp_server.room_config
   with exn ->
     Printf.eprintf "[team_session] recovery skipped: %s\n%!" (Printexc.to_string exn));
  state

let is_jsonrpc_v2 = Mcp_server.is_jsonrpc_v2
let is_jsonrpc_response = Mcp_server.is_jsonrpc_response
let is_notification = Mcp_server.is_notification
let get_id = Mcp_server.get_id
let is_valid_request_id = Mcp_server.is_valid_request_id
let jsonrpc_request_of_yojson = Mcp_server.jsonrpc_request_of_yojson
let protocol_version_from_params = Mcp_server.protocol_version_from_params
let normalize_protocol_version = Mcp_server.normalize_protocol_version
let validate_initialize_params = Mcp_server.validate_initialize_params
let make_response = Mcp_server.make_response
let make_error = Mcp_server.make_error
let is_valid_request_id = Mcp_server.is_valid_request_id
let validate_initialize_params = Mcp_server.validate_initialize_params
let has_field = Mcp_server.has_field
let get_field = Mcp_server.get_field

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

(* Heartbeat module extracted to lib/heartbeat.ml for testability *)

(** Unregister agent synchronously - adapter for Session.registry

    Directly removes from hashtable without extra mutex layer.
    Safe in Eio single-fiber context.
*)
let unregister_sync (registry : Session.registry) ~agent_name =
  Hashtbl.remove registry.Session.sessions agent_name;
  Log.Session.info "Session unregistered (sync): %s (total: %d)"
    agent_name (Hashtbl.length registry.sessions)

(** Wait for message using Eio sleep - adapter for Session.registry

    Uses existing Session.pop_message but with Eio.Time.sleep for polling.
    This avoids the legacy bridge while keeping the existing registry structure.
*)
let wait_for_message_eio ~clock (registry : Session.registry) ~agent_name ~timeout =
  let start_time = Time_compat.now () in
  let check_interval = 2.0 in

  (* Ensure session exists *)
  (match Hashtbl.find_opt registry.Session.sessions agent_name with
   | Some _ -> ()
   | None ->
       (try ignore (Session.register registry ~agent_name)
        with exn -> Printf.eprintf "[mcp_server] session register (SSE) failed: %s\n%!" (Printexc.to_string exn)));

  Session.update_activity registry ~agent_name ~is_listening:(Some true) ();

  let rec wait_loop () =
    let elapsed = Time_compat.now () -. start_time in
    if elapsed >= timeout then begin
      Session.update_activity registry ~agent_name ~is_listening:(Some false) ();
      None
    end else begin
      match Session.pop_message registry ~agent_name with
      | Some msg ->
          Session.update_activity registry ~agent_name ~is_listening:(Some false) ();
          Some msg
      | None ->
          Eio.Time.sleep clock check_interval;
          wait_loop ()
    end
  in

  try wait_loop ()
  with exn ->
    Printf.eprintf "[WARN] listen wait_loop interrupted: %s\n%!" (Printexc.to_string exn);
    Session.update_activity registry ~agent_name ~is_listening:(Some false) ();
    None

(** Handle resources/read - Eio native (pure sync)

    Reads various MASC resources: status, tasks, who, messages.
    All underlying operations are already synchronous.
*)
let handle_read_resource_eio state id params =
  match params with
  | None -> make_error ~id (-32602) "Missing params"
  | Some (`Assoc _ as p) ->
      let uri_str = Safe_ops.json_string "uri" p in
      if uri_str = "" then
        make_error ~id (-32602) "Missing uri"
      else begin
        let resource_id, uri = Mcp_server.parse_masc_resource_uri uri_str in
        let config = state.Mcp_server.room_config in
        let registry = state.Mcp_server.session_registry in

        let read_messages_json ~since_seq ~limit =
          let msgs_path = Room.messages_dir config in
          if Sys.file_exists msgs_path then
            (* Extract seq number from filename like "000001885_unknown_broadcast.json" or "1664_codex_broadcast.json" *)
            let extract_seq name =
              match String.index_opt name '_' with
              | None -> 0
              | Some idx ->
                Safe_ops.int_of_string_with_default ~default:0 (String.sub name 0 idx)
            in
            let files = Sys.readdir msgs_path |> Array.to_list
              |> List.sort (fun a b -> compare (extract_seq b) (extract_seq a)) in
            let count = ref 0 in
            let msgs = ref [] in
            List.iter (fun name ->
              if !count < limit then begin
                let path = Filename.concat msgs_path name in
                let json = Room.read_json config path in
                match Types.message_of_yojson json with
                | Ok msg when msg.Types.seq > since_seq ->
                    msgs := (Types.message_to_yojson msg) :: !msgs;
                    incr count
                | _ -> ()
              end
            ) files;
            `List (List.rev !msgs)
          else
            `List []
        in

        let read_events_json ~limit =
          let lines = Mcp_server.read_event_lines config ~limit in
          let events =
            List.filter_map (fun line ->
              match Yojson.Safe.from_string line with
              | json -> Some json
              | exception Yojson.Json_error msg ->
                let preview = if String.length line > 50 then String.sub line 0 50 ^ "..." else line in
                Eio.traceln "[WARN] Failed to parse event JSON: %s (line: %s)" msg preview;
                None
            ) lines
          in
          `List events
        in

        let read_events_markdown ~limit =
          let lines = Mcp_server.read_event_lines config ~limit in
          if lines = [] then "(no events)"
          else String.concat "\n" (List.map (fun line -> "- " ^ line) lines)
        in

        let (mime_type, text_opt) =
          match resource_id with
          | "tool-help-index" ->
              ( "text/markdown",
                Some
                  (Tool_help_registry.index_markdown (public_tool_help_schemas ())) )
          | s when String.starts_with ~prefix:"tool-help/" s ->
              let tool_name =
                String.sub s (String.length "tool-help/")
                  (String.length s - String.length "tool-help/")
              in
              let text_opt =
                match
                  Tool_help_registry.find_entry (public_tool_help_schemas ()) tool_name
                with
                | Some entry -> Some (Tool_help_registry.entry_markdown entry)
                | None -> None
              in
              ("text/markdown", text_opt)
          | "status" -> ("text/markdown", Some (Room.status config))
          | "status.json" ->
              let state_json = Types.room_state_to_yojson (Room.read_state config) in
              let backlog_json = Types.backlog_to_yojson (Room.read_backlog config) in
              let connected_agents = Session.get_agent_statuses registry in
              let json = `Assoc [
                ("base_path", `String config.base_path);
                ("state", state_json);
                ("backlog", backlog_json);
                ("connected_agents", `List connected_agents);
              ] in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "tasks" -> ("text/markdown", Some (Room.list_tasks config))
          | "tasks.json" ->
              let backlog_json = Types.backlog_to_yojson (Room.read_backlog config) in
              ("application/json", Some (Yojson.Safe.pretty_to_string backlog_json))
          | "who" -> ("text/markdown", Some (Session.status_string registry))
          | "who.json" ->
              let statuses = Session.get_agent_statuses registry in
              ("application/json", Some (Yojson.Safe.pretty_to_string (`List statuses)))
          | "agents" ->
              let json = Room.get_agents_status config in
              ("text/markdown", Some (Yojson.Safe.pretty_to_string json))
          | "agents.json" ->
              let json = Room.get_agents_status config in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "messages" | "messages/recent" ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              ("text/markdown", Some (Room.get_messages config ~since_seq ~limit))
          | "messages.json" | "messages.json/recent" ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              let json = read_messages_json ~since_seq ~limit in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "events" ->
              let limit = Mcp_server.int_query_param uri "limit" ~default:50 in
              ("text/markdown", Some (read_events_markdown ~limit))
          | "events.json" ->
              let limit = Mcp_server.int_query_param uri "limit" ~default:50 in
              let json = read_events_json ~limit in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "worktrees" ->
              let json = Room.worktree_list config in
              ("text/markdown", Some (Yojson.Safe.pretty_to_string json))
          | "worktrees.json" ->
              let json = Room.worktree_list config in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "schema" ->
              ("text/markdown", Some Mcp_server.schema_markdown)
          | "schema.json" ->
              ("application/json", Some (Yojson.Safe.pretty_to_string Mcp_server.schema_json))
          (* Agent Being Protocol - Institution Memory *)
          | "institution" ->
              let file = Filename.concat config.base_path ".masc/institution.json" in
              if Sys.file_exists file then
                try
                  let json = Room.read_json config file in
                  let inst = Institution_eio.institution_of_json json in
                  ("text/markdown", Some (Institution_eio.format_for_injection inst))
                with
                | Yojson.Json_error _ | Sys_error _ ->
                  (* Fallback: return raw JSON if parsing fails *)
                  let content = In_channel.with_open_text file In_channel.input_all in
                  ("application/json", Some content)
              else
                ("text/markdown", Some "No institution memory found. Create one with masc_init.")
          | "institution.json" ->
              let file = Filename.concat config.base_path ".masc/institution.json" in
              if Sys.file_exists file then
                (* Read raw file to avoid parsing issues with int/float *)
                let content = In_channel.with_open_text file In_channel.input_all in
                ("application/json", Some content)
              else
                ("application/json", Some "{\"error\": \"No institution memory found\"}")
          (* Library - curated knowledge from direct research *)
          | s when String.length s >= 7 && String.sub s 0 7 = "library" ->
              let library_dir = Filename.concat config.base_path "docs/library" in
              if not (Sys.file_exists library_dir) then
                ("text/markdown", Some "Library directory not found. Create docs/library/ first.")
              else begin
                (* Parse frontmatter from a .md file *)
                let parse_frontmatter path fallback_name =
                  try
                    In_channel.with_open_text path (fun ic ->
                      match In_channel.input_line ic with
                      | Some "---" ->
                          let title = ref fallback_name in
                          let source = ref "" in
                          let verified_by = ref "" in
                          let date = ref "" in
                          let tags = ref [] in
                          let rec scan () =
                            match In_channel.input_line ic with
                            | Some "---" -> ()
                            | Some line ->
                                let try_field prefix r =
                                  let plen = String.length prefix in
                                  if String.length line > plen
                                     && String.sub line 0 plen = prefix then
                                    r := String.trim (String.sub line plen (String.length line - plen))
                                in
                                try_field "title: " title;
                                try_field "source: " source;
                                try_field "verified_by: " verified_by;
                                try_field "date: " date;
                                (* tags: [a, b, c] *)
                                let tp = "tags: " in
                                let tplen = String.length tp in
                                if String.length line > tplen
                                   && String.sub line 0 tplen = tp then begin
                                  let raw = String.trim (String.sub line tplen (String.length line - tplen)) in
                                  (* Strip surrounding brackets *)
                                  let inner =
                                    if String.length raw >= 2
                                       && raw.[0] = '[' && raw.[String.length raw - 1] = ']' then
                                      String.sub raw 1 (String.length raw - 2)
                                    else raw
                                  in
                                  tags := String.split_on_char ',' inner
                                    |> List.map String.trim
                                    |> List.filter (fun s -> s <> "")
                                end;
                                scan ()
                            | None -> ()
                          in
                          scan ();
                          (!title, !source, !verified_by, !date, !tags)
                      | _ -> (fallback_name, "", "", "", []))
                  with Sys_error _ -> (fallback_name, "", "", "", [])
                in
                (* Strip frontmatter from content, return body only *)
                let strip_frontmatter content =
                  if String.length content >= 3 && String.sub content 0 3 = "---" then
                    (* Find second --- *)
                    match String.index_from_opt content 3 '\n' with
                    | None -> content
                    | Some first_nl ->
                        let rec find_end pos =
                          match String.index_from_opt content pos '\n' with
                          | None -> content
                          | Some nl ->
                              let line_start = pos in
                              let line = String.sub content line_start (nl - line_start) in
                              if line = "---" then
                                let rest_start = nl + 1 in
                                if rest_start < String.length content then
                                  String.trim (String.sub content rest_start (String.length content - rest_start))
                                else ""
                              else find_end (nl + 1)
                        in
                        find_end (first_nl + 1)
                  else content
                in
                (* Determine format and topic *)
                let is_json, topic =
                  if s = "library.json" then (true, "")
                  else if s = "library" then (false, "")
                  else
                    let rest = if String.length s > 8 then String.sub s 8 (String.length s - 8) else "" in
                    if Filename.check_suffix rest ".json" then
                      (true, Filename.chop_suffix rest ".json")
                    else (false, rest)
                in
                let library_files () =
                  Sys.readdir library_dir |> Array.to_list
                    |> List.filter (fun f -> Filename.check_suffix f ".md" && f <> "README.md")
                    |> List.sort String.compare
                in
                if topic = "" && not is_json then begin
                  (* Markdown index *)
                  let files = library_files () in
                  let entries = List.map (fun f ->
                    let name = Filename.chop_suffix f ".md" in
                    let path = Filename.concat library_dir f in
                    let (title, source, _verified, _date, tags) = parse_frontmatter path name in
                    let tag_str = if tags = [] then ""
                      else " — " ^ String.concat ", " (List.map (fun t -> "`" ^ t ^ "`") tags) in
                    let src_str = if source = "" then "" else " ([source](" ^ source ^ "))" in
                    Printf.sprintf "- **%s** — `masc://library/%s`%s%s" title name src_str tag_str
                  ) files in
                  let body = if entries = [] then "Library is empty."
                    else "# Library Index\n\n" ^ String.concat "\n" entries ^ "\n"
                  in
                  ("text/markdown", Some body)
                end else if topic = "" && is_json then begin
                  (* JSON index *)
                  let files = library_files () in
                  let docs = List.map (fun f ->
                    let name = Filename.chop_suffix f ".md" in
                    let path = Filename.concat library_dir f in
                    let (title, source, verified_by, date, tags) = parse_frontmatter path name in
                    `Assoc [
                      ("topic", `String name);
                      ("title", `String title);
                      ("source", `String source);
                      ("verified_by", `String verified_by);
                      ("date", `String date);
                      ("tags", `List (List.map (fun t -> `String t) tags));
                      ("uri", `String ("masc://library/" ^ name));
                    ]
                  ) files in
                  let json = `Assoc [
                    ("documents", `List docs);
                    ("count", `Int (List.length docs));
                  ] in
                  ("application/json", Some (Yojson.Safe.to_string json))
                end else if is_json then begin
                  (* JSON single document *)
                  let path = Filename.concat library_dir (topic ^ ".md") in
                  if Sys.file_exists path then begin
                    let raw = In_channel.with_open_text path In_channel.input_all in
                    let (title, source, verified_by, date, tags) = parse_frontmatter path topic in
                    let body = strip_frontmatter raw in
                    let json = `Assoc [
                      ("topic", `String topic);
                      ("title", `String title);
                      ("source", `String source);
                      ("verified_by", `String verified_by);
                      ("date", `String date);
                      ("tags", `List (List.map (fun t -> `String t) tags));
                      ("content", `String body);
                    ] in
                    ("application/json", Some (Yojson.Safe.to_string json))
                  end else
                    ("application/json", Some (Yojson.Safe.to_string (`Assoc [("error", `String (Printf.sprintf "Library document '%s' not found" topic))])))
                end else begin
                  (* Markdown single document *)
                  let path = Filename.concat library_dir (topic ^ ".md") in
                  if Sys.file_exists path then
                    let content = In_channel.with_open_text path In_channel.input_all in
                    ("text/markdown", Some content)
                  else
                    ("text/markdown", Some (Printf.sprintf "Library document '%s' not found." topic))
                end
              end
          | _ -> ("text/plain", None)
        in

        match text_opt with
        | None ->
            make_error ~id
              ~data:(`Assoc [ ("uri", `String uri_str) ])
              (-32002) "Resource not found"
        | Some text ->
            let contents = `List [
              `Assoc [
                ("uri", `String uri_str);
                ("mimeType", `String mime_type);
                ("text", `String text);
              ]
            ] in
            make_response ~id (`Assoc [("contents", contents)])
      end
  | Some _ ->
      make_error ~id (-32602) "Invalid params"

(** Read Content-Length prefixed message from Eio flow *)
let read_framed_message buf =
  (* Read headers until empty line *)
  let rec read_headers acc =
    let line = Eio.Buf_read.line buf in
    if String.length line = 0 || line = "\r" then
      acc
    else
      read_headers (line :: acc)
  in
  let headers = read_headers [] in

  (* Parse Content-Length *)
  let content_length =
    List.find_map (fun header ->
      let header = String.trim header in
      if String.length header > 16 &&
         String.lowercase_ascii (String.sub header 0 15) = "content-length:" then
        let len_str = String.trim (String.sub header 15 (String.length header - 15)) in
        int_of_string_opt len_str
      else
        None
    ) headers
    |> Option.value ~default:0
  in

  if content_length > 0 then begin
    (* Read exact number of bytes *)
    let body = Eio.Buf_read.take content_length buf in
    Some body
  end else
    None

(** Write Content-Length prefixed message to Eio flow *)
let write_framed_message flow json =
  let body = Yojson.Safe.to_string json in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length body) in
  Eio.Flow.copy_string header flow;
  Eio.Flow.copy_string body flow

(** Read newline-delimited message from Eio flow *)
let read_line_message buf =
  try Some (Eio.Buf_read.line buf)
  with End_of_file -> None

(** Write newline-delimited message to Eio flow *)
let write_line_message flow json =
  let body = Yojson.Safe.to_string json in
  Eio.Flow.copy_string body flow;
  Eio.Flow.copy_string "\n" flow

(** Detect transport mode from first line *)
type transport_mode =
  | Framed      (* Content-Length prefixed - MCP stdio mode *)
  | LineDelimited  (* One JSON per line - simple mode *)

let detect_mode first_line =
  let lower = String.lowercase_ascii first_line in
  if String.length lower >= 14 &&
     String.sub lower 0 14 = "content-length" then
    Framed
  else
    LineDelimited

(* ============================================ *)
(* Governance & Audit (Lightweight)            *)
(* ============================================ *)

type governance_config = {
  level: string;
  audit_enabled: bool;
  anomaly_detection: bool;
}

let governance_defaults level =
  let level_lc = String.lowercase_ascii level in
  let audit_enabled =
    match level_lc with
    | "production" | "enterprise" | "paranoid" -> true
    | _ -> false
  in
  let anomaly_detection =
    match level_lc with
    | "enterprise" | "paranoid" -> true
    | _ -> false
  in
  { level = level_lc; audit_enabled; anomaly_detection }

let governance_path (config : Room.config) =
  Filename.concat (Room_utils.masc_dir config) "governance.json"

let ensure_masc_dir (config : Room.config) =
  let dir = Room_utils.masc_dir config in
  if not (Sys.file_exists dir) then
    Room_utils.mkdir_p dir

let load_governance (config : Room.config) : governance_config =
  let path = governance_path config in
  if Room_utils.path_exists config path then
    let json = Room_utils.read_json config path in
    let module U = Yojson.Safe.Util in
    let level = Json_util.get_string json "level" |> Option.value ~default:"development" in
    let defaults = governance_defaults level in
    let audit_enabled =
      match json |> U.member "audit_enabled" with
      | `Bool b -> b
      | _ -> defaults.audit_enabled
    in
    let anomaly_detection =
      match json |> U.member "anomaly_detection" with
      | `Bool b -> b
      | _ -> defaults.anomaly_detection
    in
    { level = String.lowercase_ascii level; audit_enabled; anomaly_detection }
  else
    governance_defaults "development"

let save_governance (config : Room.config) (g : governance_config) =
  ensure_masc_dir config;
  let json = `Assoc [
    ("level", `String g.level);
    ("audit_enabled", `Bool g.audit_enabled);
    ("anomaly_detection", `Bool g.anomaly_detection);
    ("updated_at", `String (Types.now_iso ()));
  ] in
  Room_utils.write_json config (governance_path config) json

(* Inline audit system removed in Phase 2 — all audit logging
   now goes through the canonical Audit_log module. *)

(* ============================================ *)
(* MCP Session (HTTP Session ID) helpers        *)
(* ============================================ *)

type mcp_session_record = {
  id: string;
  agent_name: string option;
  created_at: float;
  last_seen: float;
}

let mcp_sessions_path (config : Room.config) =
  Filename.concat (Room_utils.masc_dir config) "mcp-sessions.json"

let mcp_session_to_json (s : mcp_session_record) : Yojson.Safe.t =
  `Assoc [
    ("id", `String s.id);
    ("agent_name", match s.agent_name with Some a -> `String a | None -> `Null);
    ("created_at", `Float s.created_at);
    ("last_seen", `Float s.last_seen);
  ]

let mcp_session_of_json (json : Yojson.Safe.t) : mcp_session_record option =
  let module U = Yojson.Safe.Util in
  try
    let id = match Json_util.get_string json "id" with Some v -> v | None -> raise Not_found in
    let agent_name = Json_util.get_string json "agent_name" in
    let created_at = match Json_util.get_float json "created_at" with Some v -> v | None -> raise Not_found in
    let last_seen = match Json_util.get_float json "last_seen" with Some v -> v | None -> raise Not_found in
    Some { id; agent_name; created_at; last_seen }
  with Not_found | Yojson.Safe.Util.Type_error _ -> None

let load_mcp_sessions (config : Room.config) : mcp_session_record list =
  let path = mcp_sessions_path config in
  if Room_utils.path_exists config path then
    let json = Room_utils.read_json config path in
    match json with
    | `List items -> List.filter_map mcp_session_of_json items
    | _ -> []
  else
    []

let save_mcp_sessions (config : Room.config) (sessions : mcp_session_record list) =
  ensure_masc_dir config;
  let json = `List (List.map mcp_session_to_json sessions) in
  Room_utils.write_json config (mcp_sessions_path config) json

(* ============================================ *)
(* Drift Guard helpers (compat aliases)         *)
(* ============================================ *)

let tokenize = Drift_guard.tokenize
let jaccard_similarity = Drift_guard.jaccard_similarity
let cosine_similarity = Drift_guard.cosine_similarity

(** Execute tool - Eio native version.

    Direct-style implementation using Eio-native modules:
    - wait_for_message_eio for session listening (Eio.Time.sleep)
    - Metrics_store_eio for metrics recording (pure sync)
    - Planning_eio for planning operations (pure sync)
    - handle_read_resource_eio for resource reading (pure sync)

    All legacy bridges have been removed.
*)
let read_only_tools =
  ["masc_status"; "masc_tasks"; "masc_who"; "masc_agents";
   "masc_messages"; "masc_task_history"; "masc_votes"; "masc_vote_status";
   "masc_worktree_list"; "masc_pending_interrupts";
   "masc_cost_report"; "masc_portal_status";
   "masc_verify_handoff"; "masc_tool_help";
   "masc_goal_list"; "masc_team_session_status"; "masc_team_session_report";
   "masc_team_session_list"; "masc_team_session_compare";
   "masc_team_session_events"; "masc_team_session_prove";
   "masc_operator_snapshot"; "masc_operator_digest"]

(** Tools that require agent to be joined first.
    Extracted to module level for Tool_dispatch Hashtbl initialization. *)
let requires_join_tools = [
  "masc_claim"; "masc_claim_next"; "masc_done"; "masc_transition";
  "masc_broadcast"; "masc_add_task"; "masc_batch_add_tasks";
  "masc_worktree_create"; "masc_worktree_remove";
  "masc_release"; "masc_cancel_task";
  "masc_vote_create"; "masc_vote_cast"; "masc_interrupt"; "masc_approve"; "masc_reject";
  "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
  "masc_deliver"; "masc_note_add"; "masc_error_add"; "masc_error_resolve";
  "masc_lock"; "masc_unlock";
  "masc_goal_upsert"; "masc_goal_snapshot"; "masc_goal_refresh";
  "masc_goal_dispatch"; "masc_goal_review";
  "masc_team_session_start"; "masc_team_session_stop";
  "masc_team_session_turn"; "masc_operator_action";
  "masc_operator_confirm";
]

(** Initialize O(1) Hashtbl sets for read_only and requires_join checks.
    Replaces per-call List.mem O(n) with Hashtbl.mem O(1). *)
let () = Tool_dispatch.init_read_only_set read_only_tools
let () = Tool_dispatch.init_requires_join_set requires_join_tools

let execute_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state ~name ~arguments =
  (* clock parameter used for Session_eio.wait_for_message *)
  (* mcp_session_id: HTTP MCP session ID for agent_name persistence across tool calls *)
  let module U = Yojson.Safe.Util in

  let config = state.Mcp_server.room_config in
  let registry = state.Mcp_server.session_registry in

  (* === Agent Identity Resolution via Agent_registry_eio === *)
  (* This replaces file-based session persistence with proper identity tracking *)
  let identity = Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments in
  Log.Mcp.debug "[Identity] %s" (Agent_identity.to_display_string identity);

  (* Legacy helper for backward compatibility - reads from file if identity not in args *)
  let read_mcp_session_agent () =
    match mcp_session_id with
    | None -> None
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        try
          let ic = open_in file in
          let name =
            Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
              ~finally:(fun () -> close_in_noerr ic)
              (fun () -> input_line ic)
          in
          if name = "" then None else Some name
        with Sys_error _ | End_of_file -> None
  in

  (* Legacy helper - write to file for backward compat with non-identity-aware tools *)
  let write_mcp_session_agent agent_name =
    match mcp_session_id with
    | None -> ()
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        try
          let oc = open_out file in
          Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
            ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc agent_name)
        with Sys_error msg ->
          Printf.eprintf "[WARN] write_mcp_session_agent: %s\n%!" msg
  in

  (* Helper to get values from JSON arguments - delegates to Safe_ops *)
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments
  in
  let arg_get_int key default =
    Safe_ops.json_int ~default key arguments
  in
  let arg_get_float key default =
    Safe_ops.json_float ~default key arguments
  in
  let arg_get_bool key default =
    Safe_ops.json_bool ~default key arguments
  in
  let arg_get_string_list key =
    Safe_ops.json_string_list key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let _arg_get_int_opt key =
    Safe_ops.json_int_opt key arguments
  in
  let arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  (* Resolve agent_name via Agent Identity system (primary) with legacy fallback.
     Agent_registry_eio.get_or_create_identity already resolved identity above.
     Use identity.agent_name as the canonical source. *)
  let raw_agent_name = arg_get_string "agent_name" "" in
  let has_explicit_agent_name = raw_agent_name <> "" && raw_agent_name <> "unknown" in
  let identity_session_prefix =
    let len = min 8 (String.length identity.session_key) in
    if len = 0 then "anon" else String.sub identity.session_key 0 len
  in
  let generated_fallback_agent_name =
    Printf.sprintf "agent-%s" identity_session_prefix
  in
  let agent_name =
    (* Priority: explicit arg > identity > legacy file-based *)
    if has_explicit_agent_name then
      raw_agent_name
    else if identity.Agent_identity.agent_name <> "" then
      identity.Agent_identity.agent_name
    else
      (* Legacy fallback for edge cases *)
      match read_mcp_session_agent () with
      | Some name -> name
      | None ->
          if Option.is_some mcp_session_id then
            generated_fallback_agent_name
          else
            let term_session_id = Option.value ~default:"" (Sys.getenv_opt "TERM_SESSION_ID") in
            let term_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
            (try
              let ic = open_in term_file in
              let name =
                Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                  ~finally:(fun () -> close_in_noerr ic)
                  (fun () -> input_line ic)
              in
              if name <> "" then name else raise Not_found
            with Sys_error _ | End_of_file | Not_found ->
              generated_fallback_agent_name)
  in

  let token =
    match arg_get_string_opt "token" with
    | Some t -> Some t
    | None -> auth_token
  in

  let room_path = Room.masc_dir config in
  let mode_config = Config.load room_path in

  let mode_gate_error =
    if not (Tool_catalog.allow_direct_call name) then
      Some
        (Printf.sprintf
           "Tool '%s' is hidden from the default tool surface and not callable directly."
           name)
    else if not (Mode.is_tool_enabled mode_config.enabled_categories name) then
      Some
        (Printf.sprintf
           "Tool '%s' is disabled in current mode '%s'. Run masc_get_config or masc_switch_mode first."
           name (Mode.mode_to_string mode_config.mode))
    else
      None
  in

  let read_term_session_agent () =
    if Option.is_some mcp_session_id then
      None
    else
      match Sys.getenv_opt "TERM_SESSION_ID" with
      | None -> None
      | Some sid ->
          let file = Printf.sprintf "/tmp/.masc_agent_%s" sid in
          try
            let ic = open_in file in
            let name =
              Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                ~finally:(fun () -> close_in_noerr ic)
                (fun () -> input_line ic)
            in
            if name = "" then None else Some name
          with Sys_error _ | End_of_file -> None
  in

  let persisted_agent_name () =
    match read_mcp_session_agent () with
    | Some n -> Some n
    | None ->
        if Option.is_some mcp_session_id then None else read_term_session_agent ()
  in

  (* If no explicit agent_name was provided and we already have a persisted
     generated nickname, prefer it for backward compatibility.
     IMPORTANT: explicit agent_name must win to allow multi-agent spawning. *)
  let agent_name =
    match persisted_agent_name () with
    | Some persisted
      when Nickname.is_generated_nickname persisted
           && not has_explicit_agent_name
           && not (Nickname.is_generated_nickname agent_name) ->
        persisted
    | _ -> agent_name
  in

  let is_ephemeral_agent_name name =
    String.length name >= 6 && String.sub name 0 6 = "agent-"
  in

  let agent_name =
    match token with
    | Some t when is_ephemeral_agent_name agent_name ->
        (match Auth.resolve_agent_from_token config.base_path ~token:t with
         | Ok resolved -> resolved
         | Error _ -> agent_name)
    | _ -> agent_name
  in

  (* Explicit non-nickname aliases (e.g., "alpha-agent") should resolve to an
     existing generated nickname if one is already joined. This prevents
     claim/start/done calls from drifting across different nicknames. *)
  let agent_name =
    if has_explicit_agent_name && not (Nickname.is_generated_nickname agent_name) then
      let resolved = Room.resolve_agent_name config agent_name in
      if resolved <> agent_name then
        try
          if Room.is_agent_joined config ~agent_name:resolved then
            resolved
          else
            agent_name
        with exn ->
          Printf.eprintf "[warn] %s: %s\n" __FUNCTION__ (Printexc.to_string exn);
          agent_name
      else
        agent_name
    else
      agent_name
  in
  match mode_gate_error with
  | Some msg -> (false, msg)
  | None ->
  (* Enforce tool authorization when enabled *)
  let auth_enabled = Auth.is_auth_enabled config.base_path in
  let auth_result =
    if auth_enabled then
      match Auth.authorize_tool config.base_path ~agent_name ~token ~tool_name:name with
      | Ok () -> Ok ()
      | Error err -> Error err
    else
      Ok ()
  in

  match auth_result with
  | Error err -> (false, Types.masc_error_to_string err)
  | Ok () ->
  let extract_nickname_from_join_result ~fallback result =
    try
      let prefix = "  Nickname: " in
      let start_idx =
        let idx = ref 0 in
        while !idx < String.length result - String.length prefix &&
              String.sub result !idx (String.length prefix) <> prefix do
          incr idx
        done;
        !idx + String.length prefix
      in
      let end_idx = String.index_from result start_idx '\n' in
      String.sub result start_idx (end_idx - start_idx)
    with Not_found | Invalid_argument _ -> fallback
  in

  let write_term_session_agent nickname =
    if Option.is_some mcp_session_id then
      ()
    else
      match Sys.getenv_opt "TERM_SESSION_ID" with
      | None -> ()
      | Some sid ->
          let file = Printf.sprintf "/tmp/.masc_agent_%s" sid in
          (try
            let oc = open_out file in
            Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
              ~finally:(fun () -> close_out_noerr oc)
              (fun () -> output_string oc nickname)
          with e ->
            Printf.eprintf "[WARN] Failed to write agent file %s: %s\n%!"
              file (Printexc.to_string e))
  in

  (* Auto-init/auto-join for better UX.
     - Auto-init only when auth is disabled (avoid side effects in secured rooms).
     - Auto-join when allowed by auth (and safe for token-based auth). *)
  let join_required = Tool_dispatch.is_join_required name in

  let init_error =
    if (not auth_enabled) && join_required && not (Room.is_initialized config) then
      (try
         ignore (Room.init config ~agent_name:None);
         None
       with Invalid_argument msg -> Some msg
          | Sys_error msg -> Some msg
          | Yojson.Json_error msg -> Some msg
          | exn -> Some (Printexc.to_string exn))
    else
      None
  in
  match init_error with
  | Some msg ->
      (false, Printf.sprintf "❌ %s" msg)
  | None ->

  let is_read_only = Tool_dispatch.is_read_only name in

  let can_auto_join =
    if (not join_required) || agent_name = "unknown" then
      false
    else if not auth_enabled then
      true
    else
      (* If per-agent tokens are required, only auto-join when agent_name already
         looks like a stable nickname. Otherwise Room.join would generate a new
         nickname, breaking token verification for subsequent calls. *)
      let auth_cfg = Auth.load_auth_config config.base_path in
      if auth_cfg.require_token && not (Nickname.is_generated_nickname agent_name) then
        false
      else
        match Auth.authorize_tool config.base_path ~agent_name ~token ~tool_name:"masc_join" with
        | Ok () -> true
        | Error _ -> false
  in

  let agent_name =
    if can_auto_join then begin
      let room_initialized = Room.is_initialized config in
      let is_joined =
        if room_initialized then
          try Room.is_agent_joined config ~agent_name
          with Sys_error _ | Yojson.Json_error _ | Invalid_argument _ -> false
        else
          false
      in
      if is_joined then
        agent_name
      else begin
        let join_result = Room.join config ~agent_name ~capabilities:[] () in
        let nickname = extract_nickname_from_join_result ~fallback:agent_name join_result in
        Log.Mcp.info "Auto-joined for %s: %s -> %s" name agent_name nickname;
        (* Persist nickname so subsequent calls can use it. *)
        write_mcp_session_agent nickname;
        write_term_session_agent nickname;
        (try ignore (Session.register registry ~agent_name:nickname)
         with exn -> Printf.eprintf "[mcp_server] session register (nickname) failed: %s\n%!" (Printexc.to_string exn));
        nickname
      end
    end else
      agent_name
  in

  (* Auto-register session for non-read-only tools *)
  if agent_name <> "unknown" && not is_read_only then
    (try ignore (Session.register registry ~agent_name)
     with exn -> Printf.eprintf "[mcp_server] session register (tool) failed: %s\n%!" (Printexc.to_string exn));

  (* Log tool call *)
  Log.Mcp.debug "[%s] %s" agent_name name;

  (* Update activity for any tool call *)
  if agent_name <> "unknown" then begin
    Session.update_activity registry ~agent_name ();
    (* Keep read-only/fast tools non-blocking; heartbeat is best-effort. *)
    let skip_heartbeat =
      is_read_only
      || Tool_catalog.is_placeholder name
      || match Tool_catalog.implementation_status name with
         | Tool_catalog.Simulation -> true
         | Tool_catalog.Real | Tool_catalog.Adapter | Tool_catalog.Placeholder ->
             false
    in
    if (not skip_heartbeat) && Room.is_initialized config then
      try
        ignore (Room.heartbeat config ~agent_name)
      with
      | exn ->
          Printf.eprintf "[WARN] heartbeat update skipped for %s on %s: %s\n%!"
            agent_name name (Printexc.to_string exn)
  end;

  (* Check if agent must join first *)
  let room_initialized = Room.is_initialized config in
  let is_joined =
    if room_initialized then
      (* Some tools (e.g., masc_init) must run before initialization.
         Guard the join check to avoid raising and crashing the server. *)
      try Room.is_agent_joined config ~agent_name
      with Sys_error _ | Yojson.Json_error _ -> false
    else
      false
  in

  (* Debug: log join check *)
  Printf.eprintf
    "[DEBUG] tool=%s agent_name=%s join_required=%b room_initialized=%b is_joined=%b\n%!"
    name agent_name join_required room_initialized is_joined;

  if join_required && not room_initialized then
    (false, Printf.sprintf
      "⚠️ MASC room not initialized.\n\n💡 Workflow: masc_init → masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s room_initialized=%b"
      name agent_name room_initialized)
  else if join_required && not is_joined then
    (false, Printf.sprintf
      "❌ Join required: Call masc_join first before using %s.\n\n💡 Workflow: masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s is_joined=%b"
      name name agent_name is_joined)
  else

  (* Safe exec for checkpoint commands - Eio-native *)
  let safe_exec args =
    match Process_eio.run_argv_with_status ~timeout_sec:60.0 args with
    | Unix.WEXITED 0, output -> (true, output)
    | _, output -> (false, if output = "" then "❌ Command failed" else output)
  in

  (* Delegate to extracted tool modules first *)
  let simple_ctx_config = { Tool_plan.config } in
  let simple_ctx_run = { Tool_run.config } in
  let simple_ctx_team_session =
    { Tool_team_session.config; agent_name; sw; clock; proc_mgr = state.Mcp_server.proc_mgr }
  in
  let simple_ctx_operator =
    {
      Tool_operator.config;
      agent_name;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id;
    }
  in
  let simple_ctx_command_plane : (_, _) Tool_command_plane.context =
    {
      config;
      agent_name;
      sw = Some sw;
      clock = Some clock;
      net = state.Mcp_server.net;
      mcp_state = Some state;
      mcp_session_id;
      auth_token;
    }
  in
  let simple_ctx_cache = { Tool_cache.config } in
  let simple_ctx_tempo = { Tool_tempo.config; agent_name } in
  let simple_ctx_mitosis =
    Tool_mitosis.make_context_with_eio
      ~config
      ~sw
      ~proc_mgr:state.Mcp_server.proc_mgr
      ~clock
  in
  let simple_ctx_portal : Tool_portal.context = { config; agent_name } in
  let simple_ctx_worktree : Tool_worktree.context = { config; agent_name } in
  let simple_ctx_code : Tool_code.context = { config; agent_name } in
  let simple_ctx_vote : Tool_vote.context = { config; agent_name } in
  let simple_ctx_social : Tool_social.context = { config; agent_name } in
  let simple_ctx_council : Tool_council.context = {
    base_path = config.base_path;
    agent_name;
    room_config = Some config;
  } in
  let simple_ctx_experiment : Tool_experiment.context = { config; agent_name } in
  let simple_ctx_a2a : Tool_a2a.context = { config; agent_name } in
  let handover_ctx : Tool_handover.context = {
    config; agent_name;
    fs = state.Mcp_server.fs;
    proc_mgr = state.Mcp_server.proc_mgr;
    sw = Some sw;
  } in
  let simple_ctx_relay : Tool_relay.context = { config; agent_name; sw; proc_mgr = state.Mcp_server.proc_mgr } in
  let simple_ctx_goals : Tool_goals.context =
    {
      config;
      agent_name;
      call_keeper_msg =
        Some
          (fun keeper_args ->
            let keeper_ctx : _ Tool_keeper.context = { config; sw; clock } in
            match
              Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg"
                ~args:keeper_args
            with
            | Some result -> result
            | None -> (false, "masc_keeper_msg dispatch unavailable"));
    }
  in
  let simple_ctx_heartbeat = { Tool_heartbeat.config; agent_name; sw; clock } in
  let simple_ctx_encryption : Tool_encryption.context = { state } in
  let simple_ctx_auth : Tool_auth.context = { config; agent_name } in
  let simple_ctx_hat : Tool_hat.context = { config; agent_name } in
  let simple_ctx_audit : Tool_audit.context = { config } in
  let simple_ctx_rate_limit : Tool_rate_limit.context = { config; agent_name; registry } in
  let simple_ctx_cost : Tool_cost.context = { agent_name } in
  let simple_ctx_walph = lazy (
    match state.Mcp_server.net with
    | Some net -> ({ config; agent_name; net; clock } : _ Tool_walph.context)
    | None -> failwith "walph requires net (server_state.net is None)"
  ) in
  let simple_ctx_agent : Tool_agent.context = { config; agent_name } in
  let simple_ctx_task : Tool_task.context = { config; agent_name } in
  let simple_ctx_room : Tool_room.context = { config; agent_name } in
  let simple_ctx_control : Tool_control.context = { config; agent_name } in
  let simple_ctx_misc : Tool_misc.context = { config; agent_name } in
  let simple_ctx_llama : Tool_llama.context = { config; agent_name } in
  let simple_ctx_voice : _ Tool_voice.context =
    { agent_name; sw; clock; net = state.Mcp_server.net }
  in
  let simple_ctx_suspend : Tool_suspend.context = { config; caller_agent = Some agent_name } in
  let simple_ctx_library : Tool_library.context = { agent_name } in
  let simple_ctx_mdal : Tool_mdal.context = {
    agent_name;
    config = Some config;
    sw = Some sw;
    proc_mgr = state.Mcp_server.proc_mgr;
    worker_runner = None;
    clock = Some clock;
  } in
  let autoresearch_planned_workers ~loop_id ~target_file =
    let suffix =
      if String.length loop_id > 3 then
        String.sub loop_id 3 (min 6 (String.length loop_id - 3))
      else loop_id
    in
    let driver_actor = Printf.sprintf "autoresearch-driver-%s" suffix in
    let auditor_actor = Printf.sprintf "autoresearch-auditor-%s" suffix in
    let mk_worker ~runtime_actor ~spawn_role ~worker_class ~control_domain
        ~task_profile ~routing_reason =
      {
        Team_session_types.spawn_agent = "masc";
        runtime_actor = Some runtime_actor;
        spawn_role = Some spawn_role;
        spawn_model = None;
        worker_class = Some worker_class;
        parent_actor = Some agent_name;
        capsule_mode = Some Team_session_types.Capsule_inherit;
        runtime_pool = None;
        lane_id = Some loop_id;
        controller_level = Some Team_session_types.Controller_worker;
        control_domain = Some control_domain;
        supervisor_actor = Some agent_name;
        model_tier = None;
        task_profile = Some task_profile;
        risk_level = Some Team_session_types.Risk_medium;
        routing_confidence = Some 0.9;
        routing_reason = Some routing_reason;
        routing_escalated = false;
      }
    in
    [
      mk_worker ~runtime_actor:driver_actor ~spawn_role:"research-driver"
        ~worker_class:Team_session_types.Worker_executor
        ~control_domain:Team_session_types.Domain_execution
        ~task_profile:Team_session_types.Profile_normalize
        ~routing_reason:
          (Printf.sprintf "Drive autoresearch loop %s for %s" loop_id target_file);
      mk_worker ~runtime_actor:auditor_actor ~spawn_role:"research-auditor"
        ~worker_class:Team_session_types.Worker_metacog
        ~control_domain:Team_session_types.Domain_quality
        ~task_profile:Team_session_types.Profile_verify
        ~routing_reason:
          (Printf.sprintf
             "Audit keep/discard evidence for autoresearch loop %s" loop_id);
    ]
  in
  let start_autoresearch_operation ~goal ~target_file =
    let objective =
      Printf.sprintf "Autoresearch swarm: %s" goal
    in
    let args =
      `Assoc
        [
          ("assigned_unit_id", `String "company-runtime");
          ("objective", `String objective);
          ("workload_template", `String "research_team");
          ("workload_profile", `String "research_pipeline");
          ("stage", `String "normalize");
          ("search_strategy", `String "best_first_v1");
          ("artifact_scope", `List [ `String target_file ]);
          ("note", `String (Printf.sprintf "autoresearch target=%s" target_file));
        ]
    in
    match Command_plane_v2.start_operation config ~actor:agent_name args with
    | Ok operation -> Ok (Command_plane_v2.operation_to_json operation)
    | Error message -> Error message
  in
  let start_autoresearch_team_session ~goal ~operation_id ~loop_id ~target_file
      ~program_note =
    match
      Team_session_engine_eio.start_session ~sw ~clock ~config
        ~created_by:agent_name ~goal ~duration_seconds:3600
        ~execution_scope:Team_session_types.Observe_only
        ~checkpoint_interval_sec:60 ~min_agents:1
        ~scale_profile:Team_session_types.Scale_standard
        ~control_profile:Team_session_types.Control_flat
        ~orchestration_mode:Team_session_types.Assist
        ~communication_mode:Team_session_types.Comm_hybrid ~model_cascade:[]
        ~fallback_policy:Team_session_types.Fallback_none
        ~instruction_profile:Team_session_types.Profile_strict
        ~alert_channel:Team_session_types.Alert_both ~auto_resume:true
        ~report_formats:
          [ Team_session_types.Markdown; Team_session_types.Json ]
        ~agent_names:[] ~operation_id
    with
    | Error message -> Error message
    | Ok json -> (
        match
          Yojson.Safe.Util.(
            json |> member "session_id" |> to_string_option |> Option.map String.trim)
        with
        | None | Some "" -> Error "team session did not return session_id"
        | Some session_id ->
            let planned_workers =
              autoresearch_planned_workers ~loop_id ~target_file
            in
            ignore
              (Team_session_store.update_session config session_id (fun session ->
                   {
                     session with
                     planned_workers =
                       Team_session_types.dedup_planned_workers
                         (session.planned_workers @ planned_workers);
                     updated_at_iso = Types.now_iso ();
                   }));
            Team_session_store.append_event config session_id
              ~event_type:"linked_autoresearch_started"
              ~detail:
                (`Assoc
                  [
                    ("loop_id", `String loop_id);
                    ("target_file", `String target_file);
                    ( "program_note",
                      match program_note with
                      | Some value -> `String value
                      | None -> `Null );
                  ]);
            ignore
              (Team_session_engine_eio.record_turn ~config ~session_id
                 ~actor:agent_name ~turn_kind:Team_session_types.Turn_note
                 ~message:
                   (Some
                      (match program_note with
                      | Some note ->
                          Printf.sprintf
                            "Linked autoresearch loop %s on %s.\nProgram note: %s"
                            loop_id target_file note
                      | None ->
                          Printf.sprintf
                            "Linked autoresearch loop %s on %s."
                            loop_id target_file))
                 ~target_agent:None ~task_title:None ~task_description:None
                 ~task_priority:3);
            Ok json)
  in
  let simple_ctx_autoresearch : Tool_autoresearch.context = {
    base_path = config.base_path;
    agent_name = Some agent_name;
    start_operation = Some start_autoresearch_operation;
    start_team_session = Some start_autoresearch_team_session;
  } in
  let simple_ctx_perpetual : Tool_perpetual.context = {
    agent_name;
    start_loop = Some (fun loop_state loop_config ->
      Eio.Fiber.fork ~sw (fun () ->
        try
          Perpetual_loop.run ~config:loop_config ~state:loop_state
        with exn ->
          Printf.eprintf "[perpetual:error] loop crashed for %s: %s\n%!"
            loop_state.Perpetual_loop.trace_id (Printexc.to_string exn)));
    sw = Some sw;
    proc_mgr = state.Mcp_server.proc_mgr;
  } in
  let simple_ctx_keeper : _ Tool_keeper.context = { config; sw; clock } in
  let trpg_keeper_call ~name:keeper_name ~message ~timeout_sec :
      Tool_trpg.keeper_call_result =
    let keeper_args =
      `Assoc
        [
          ("name", `String keeper_name);
          ("message", `String message);
          ("timeout_sec", `Float timeout_sec);
        ]
    in
    (* Eio outer timeout includes LLM time + protocol overhead (serialization,
       network). Add 10s grace to avoid racing the LLM timeout. *)
    let eio_timeout = timeout_sec +. 10.0 in
    try
      Eio.Time.with_timeout_exn clock eio_timeout (fun () ->
          match
            Tool_keeper.dispatch simple_ctx_keeper ~name:"masc_keeper_msg"
              ~args:keeper_args
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
  in
  let trpg_keeper_probe ~name:keeper_name : Tool_trpg.keeper_probe_result =
    let keeper_args =
      `Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ]
    in
    try
      Eio.Time.with_timeout_exn clock 5.0 (fun () ->
          match
            Tool_keeper.dispatch simple_ctx_keeper ~name:"masc_keeper_status"
              ~args:keeper_args
          with
          | None -> `Error "masc_keeper_status dispatch unavailable"
          | Some (true, _body) -> `Ok
          | Some (false, msg) -> `Error msg)
    with
    | Eio.Time.Timeout -> `Error "timeout"
    | exn -> `Error (Printexc.to_string exn)
  in
  let trpg_dm_voice_emit ~agent_id ~message ~provider : Tool_trpg.dm_voice_emit_result =
    match state.Mcp_server.net with
    | None -> Error "trpg voice requires net (server_state.net is None)"
    | Some net ->
    let provider =
      match provider |> Option.map String.trim with
      | Some p when p <> "" && not (String.equal (String.lowercase_ascii p) "auto") ->
          Some p
      | _ -> None
    in
    Voice_bridge.agent_speak ~sw ~clock ~net ~agent_id ~message ?provider ()
  in
  let trpg_store = Trpg_store.make_sqlite ~base_dir:config.base_path in
  let simple_ctx_trpg : Tool_trpg.context =
    {
      store = trpg_store;
      agent_name;
      keeper_call = Some trpg_keeper_call;
      keeper_probe = Some trpg_keeper_probe;
      dm_voice_emit = Some trpg_dm_voice_emit;
    }
  in
  let simple_ctx_protocol : Tool_protocol_game_view.context =
    {
      config;
      store = trpg_store;
      agent_name;
      trpg_keeper_call = Some trpg_keeper_call;
      trpg_keeper_probe = Some trpg_keeper_probe;
      trpg_dm_voice_emit = Some trpg_dm_voice_emit;
    }
  in

  (* === V2 Dispatch: O(1) Hashtbl-based central dispatch ===
     When MASC_DISPATCH_V2=1, register all schema-exporting modules
     and try O(1) lookup first.  Falls through to the legacy chain
     for inline tools and modules without exported schemas.

     NOTE: Registration happens on every call because handler closures
     capture per-call state (e.g. simple_ctx_keeper holds the request's
     Eio.Switch [sw]).  Hashtbl.replace is idempotent and the cost
     (~210 replace ops) is negligible vs. the legacy 40-module sequential
     match chain.  The primary win is O(1) dispatch lookup. *)
  let v2_result =
    if Tool_dispatch.v2_enabled then begin
      let reg = Tool_dispatch.register_module in
      reg ~schemas:Tool_operator.schemas
        ~handler:(fun ~name ~args -> Tool_operator.dispatch simple_ctx_operator ~name ~args);
      reg ~schemas:Tool_command_plane.schemas
        ~handler:(fun ~name ~args -> Tool_command_plane.dispatch simple_ctx_command_plane ~name ~args);
      reg ~schemas:Tool_llama.schemas
        ~handler:(fun ~name ~args -> Tool_llama.dispatch simple_ctx_llama ~name ~args);
      reg ~schemas:Tool_team_session.schemas
        ~handler:(fun ~name ~args -> Tool_team_session.dispatch simple_ctx_team_session ~name ~args);
      reg ~schemas:Tool_voice.schemas
        ~handler:(fun ~name ~args -> Tool_voice.dispatch simple_ctx_voice ~name ~args);
      reg ~schemas:Tool_protocol_game_view.schemas
        ~handler:(fun ~name ~args -> Tool_protocol_game_view.dispatch simple_ctx_protocol ~name ~args);
      reg ~schemas:Tool_experiment.schemas
        ~handler:(fun ~name ~args -> Tool_experiment.dispatch simple_ctx_experiment ~name ~args);
      reg ~schemas:Tool_goals.schemas
        ~handler:(fun ~name ~args -> Tool_goals.dispatch simple_ctx_goals ~name ~args);
      reg ~schemas:Tool_perpetual.schemas
        ~handler:(fun ~name ~args -> Tool_perpetual.dispatch simple_ctx_perpetual ~name ~args);
      reg ~schemas:Tool_mdal.schemas
        ~handler:(fun ~name ~args -> Tool_mdal.dispatch simple_ctx_mdal ~name ~args);
      reg ~schemas:Tool_keeper.schemas
        ~handler:(fun ~name ~args -> Tool_keeper.dispatch simple_ctx_keeper ~name ~args);
      reg ~schemas:Tool_trpg.schemas
        ~handler:(fun ~name ~args -> Tool_trpg.dispatch simple_ctx_trpg ~name ~args);
      reg ~schemas:Tool_autoresearch.schemas
        ~handler:(fun ~name ~args -> Tool_autoresearch.dispatch simple_ctx_autoresearch ~name ~args);
      reg ~schemas:Tool_risc.schemas
        ~handler:(fun ~name ~args -> Some (Tool_risc.dispatch name args));
      Tool_dispatch.dispatch ~name ~args:arguments
    end else None
  in
  match v2_result with
  | Some result -> result
  | None ->

  (* Chain through all extracted tool modules *)
  match Tool_plan.dispatch simple_ctx_config ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_run.dispatch simple_ctx_run ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_operator.dispatch simple_ctx_operator ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_command_plane.dispatch simple_ctx_command_plane ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_llama.dispatch simple_ctx_llama ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_team_session.dispatch simple_ctx_team_session ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_voice.dispatch simple_ctx_voice ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cache.dispatch simple_ctx_cache ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_tempo.dispatch simple_ctx_tempo ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mitosis.dispatch simple_ctx_mitosis ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_portal.dispatch simple_ctx_portal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_worktree.dispatch simple_ctx_worktree ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_code.dispatch simple_ctx_code ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_vote.dispatch simple_ctx_vote ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_social.dispatch simple_ctx_social ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_council.dispatch simple_ctx_council ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_protocol_game_view.dispatch simple_ctx_protocol ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_experiment.dispatch simple_ctx_experiment ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_a2a.dispatch simple_ctx_a2a ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_handover.dispatch handover_ctx ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_relay.dispatch simple_ctx_relay ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_goals.dispatch simple_ctx_goals ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_heartbeat.dispatch simple_ctx_heartbeat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_encryption.dispatch simple_ctx_encryption ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_auth.dispatch simple_ctx_auth ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_hat.dispatch simple_ctx_hat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_audit.dispatch simple_ctx_audit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_rate_limit.dispatch simple_ctx_rate_limit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cost.dispatch simple_ctx_cost ~name ~args:arguments with
  | Some result -> result
  | None ->
  if String.length name >= 11 && String.equal (String.sub name 0 11) "masc_walph_" then
    try
      match Tool_walph.dispatch (Lazy.force simple_ctx_walph) ~name ~args:arguments with
      | Some result -> result
      | None -> (false, Printf.sprintf "Unknown Walph tool: %s" name)
    with Failure msg -> (false, msg)
  else
  match Tool_agent.dispatch simple_ctx_agent ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_task.dispatch simple_ctx_task ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_room.dispatch simple_ctx_room ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_control.dispatch simple_ctx_control ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_misc.dispatch simple_ctx_misc ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_suspend.dispatch simple_ctx_suspend ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_library.dispatch simple_ctx_library ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_keeper.dispatch simple_ctx_keeper ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_perpetual.dispatch simple_ctx_perpetual ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mdal.dispatch simple_ctx_mdal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_autoresearch.dispatch simple_ctx_autoresearch ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_trpg.dispatch simple_ctx_trpg ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_notifications.dispatch state.Mcp_server.session_registry ~agent_name ~name arguments with
  | Some result -> result
  | None ->
  (* Tool_gardener returns result directly, not option - wrap it *)
  if String.length name >= 14 && String.sub name 0 14 = "masc_gardener_" then
    Tool_gardener.dispatch () name arguments
  else

  (* SWARM-RISC Agent ISA tools — prefix guard like Tool_gardener *)
  if Tool_risc.is_risc_tool name then
    Tool_risc.dispatch name arguments
  else

  match name with
  | "masc_lock" ->
      let file = arg_get_string "file" "" in
      if file = "" then
        (false, "❌ file is required")
      else begin
        let expanded =
          if String.length file > 0 && file.[0] = '~' then
            match Sys.getenv_opt "HOME" with
            | Some home -> Filename.concat home (String.sub file 1 (String.length file - 1))
            | None -> file
          else if Filename.is_relative file then
            Filename.concat config.base_path file
          else
            file
        in
        match Room_utils.key_of_path_from_root config ~root:config.base_path expanded with
        | None ->
            (false, Printf.sprintf "❌ file must be under base_path: %s" config.base_path)
        | Some key ->
            let ttl_seconds = config.lock_expiry_minutes * 60 in
            let now = Time_compat.now () in
            let expires_at = now +. float_of_int ttl_seconds in
            (match Room_utils.backend_acquire_lock config ~key ~ttl_seconds ~owner:agent_name with
             | Ok true ->
                 let payload = `Assoc [
                   ("status", `String "acquired");
                   ("resource", `String expanded);
                   ("key", `String key);
                   ("owner", `String agent_name);
                   ("acquired_at", `Float now);
                   ("expires_at", `Float expires_at);
                 ] in
                 (true, Yojson.Safe.pretty_to_string payload)
             | Ok false ->
                 (false, Printf.sprintf "❌ Lock busy: %s" expanded)
             | Error e ->
                 (false, Printf.sprintf "❌ Lock error: %s" (Backend.show_error e)))
      end

  | "masc_unlock" ->
      let file = arg_get_string "file" "" in
      if file = "" then
        (false, "❌ file is required")
      else begin
        let expanded =
          if String.length file > 0 && file.[0] = '~' then
            match Sys.getenv_opt "HOME" with
            | Some home -> Filename.concat home (String.sub file 1 (String.length file - 1))
            | None -> file
          else if Filename.is_relative file then
            Filename.concat config.base_path file
          else
            file
        in
        match Room_utils.key_of_path_from_root config ~root:config.base_path expanded with
        | None ->
            (false, Printf.sprintf "❌ file must be under base_path: %s" config.base_path)
        | Some key ->
            (match Room_utils.backend_release_lock config ~key ~owner:agent_name with
             | Ok true ->
                 let payload = `Assoc [
                   ("status", `String "released");
                   ("resource", `String expanded);
                   ("key", `String key);
                   ("owner", `String agent_name);
                 ] in
                 (true, Yojson.Safe.pretty_to_string payload)
             | Ok false ->
                 (false, Printf.sprintf "❌ Lock not held by %s: %s" agent_name expanded)
             | Error e ->
                 (false, Printf.sprintf "❌ Lock release error: %s" (Backend.show_error e)))
      end

  | "masc_set_room" ->
      let path = arg_get_string "path" "" in
      let expanded =
        if String.length path > 0 && path.[0] = '~' then
          let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
          Filename.concat home (String.sub path 1 (String.length path - 1))
        else if Filename.is_relative path then
          Filename.concat (Sys.getcwd ()) path
        else
          path
      in
      if not (Sys.file_exists expanded && Sys.is_directory expanded) then
        (false, Printf.sprintf "❌ Directory not found: %s" expanded)
      else begin
        state.Mcp_server.room_config <- Room.default_config expanded;
        let status = if Room.is_initialized state.Mcp_server.room_config then "✅" else "⚠️ (not initialized)" in
        (true, Printf.sprintf "🎯 MASC room set to: %s\n   .masc/ status: %s" expanded status)
      end


  | "masc_join" ->
      let caps = arg_get_string_list "capabilities" in
      let result = Room.join config ~agent_name ~capabilities:caps () in
      (* Extract nickname from join result (format: "  Nickname: xxx\n...") *)
      let nickname =
        try
          let prefix = "  Nickname: " in
          let start_idx =
            let idx = ref 0 in
            while !idx < String.length result - String.length prefix &&
                  String.sub result !idx (String.length prefix) <> prefix do
              incr idx
            done;
            !idx + String.length prefix
          in
          let end_idx = String.index_from result start_idx '\n' in
          String.sub result start_idx (end_idx - start_idx)
        with Not_found | Invalid_argument _ -> agent_name (* Fallback to original if parsing fails *)
      in
      let _ = Session.register registry ~agent_name:nickname in
      (* Save nickname to MCP session file (HTTP persistence) *)
      write_mcp_session_agent nickname;
      Printf.eprintf "[DEBUG] masc_join: saved nickname=%s to MCP session (original=%s)\n%!" nickname agent_name;
      (* Also save to TERM_SESSION_ID file (terminal persistence) *)
      if Option.is_none mcp_session_id then begin
        let term_session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
        let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
        (try
          let oc = open_out agent_file in
          Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
            ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc nickname)
        with e ->
          Printf.eprintf "[WARN] Failed to write agent file %s: %s\n%!" agent_file (Printexc.to_string e))
      end;
      (* Cultural Inheritance: append institution welcome to join response *)
      let institution_welcome = match state.Mcp_server.fs with
        | Some fs ->
            (try Institution_eio.load_and_format_for_welcome ~fs config
             with
             | Eio.Io _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
             | exn ->
                 Eio.traceln "[WARN] Unexpected institution error: %s" (Printexc.to_string exn); "")
        | None -> ""
      in
      let final_result = if institution_welcome = "" then result
        else result ^ institution_welcome in
      (* Notification harness: push join event to all active sessions *)
      let _pushed = Session.push_notification_to_active_agents registry
        ~event:(`Assoc [
          ("type", `String "masc/agent_joined");
          ("agent_name", `String nickname);
          ("timestamp", `Float (Time_compat.now ()));
        ]) in
      (* Audit: log join event *)
      Audit_log.log_join config ~agent_id:nickname
        ~room_id:(Filename.basename config.base_path) ();
      (true, final_result)

  | "masc_leave" ->
      (* Notification harness: push leave event BEFORE unregistering *)
      let _pushed = Session.push_notification_to_active_agents registry
        ~event:(`Assoc [
          ("type", `String "masc/agent_left");
          ("agent_name", `String agent_name);
          ("timestamp", `Float (Time_compat.now ()));
        ]) in
      let result = Room.leave config ~agent_name in
      unregister_sync registry ~agent_name;
      (* Clean up self-echo filter file *)
      if Option.is_none mcp_session_id then begin
        let session_id = Option.value ~default:"default" (Sys.getenv_opt "TERM_SESSION_ID") in
        let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" session_id in
        Safe_ops.remove_file_logged ~context:"masc_leave" agent_file
      end;
      (* Audit: log leave event *)
      Audit_log.log_leave config ~agent_id:agent_name
        ~room_id:(Filename.basename config.base_path) ();
      (true, result)





















  | "masc_bounded_run" ->
      let module U = Yojson.Safe.Util in
      let agents = match arguments |> U.member "agents" with
        | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> []
      in
      let prompt = arg_get_string "prompt" "" in
      let constraints_json = arguments |> U.member "constraints" in
      let goal_json = arguments |> U.member "goal" in
      let constraints = Bounded.constraints_of_json constraints_json in
      let goal = Bounded.goal_of_json goal_json in
      (match state.Mcp_server.proc_mgr with
       | Some pm ->
           (* Create spawn function that uses proc_mgr *)
           let spawn_fn agent_name prompt =
             Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name ~prompt
               ~timeout_seconds:Env_config.Spawn.timeout_seconds
               ~room_config:state.Mcp_server.room_config ()
           in
           let result = Bounded.bounded_run ~constraints ~goal ~agents ~prompt ~spawn_fn in
           let json = Bounded.result_to_json result in
           (result.Bounded.status = `Goal_reached, Yojson.Safe.pretty_to_string json)
       | None ->
           (false, "❌ Process manager not available"))


  | "masc_broadcast" ->
      let message = arg_get_string "message" "" in
      (* Check rate limit - Eio native *)
      let allowed, wait_secs = Session.check_rate_limit registry ~agent_name in
      if not allowed then
        (false, Printf.sprintf "⏳ Rate limited! %d초 후 다시 시도하세요." wait_secs)
      else begin
        let result = Room.broadcast config ~from_agent:agent_name ~content:message in
        (* Use Mention module for consistent parsing (Stateless/Stateful/Broadcast) *)
        let mention = Mention.extract message in
        let _ = Session.push_message registry ~from_agent:agent_name ~content:message ~mention in
        (* Push to SSE clients immediately *)
        let notification = `Assoc [
          ("type", `String "masc/broadcast");
          ("from", `String agent_name);
          ("content", `String message);
          ("mention", match mention with Some m -> `String m | None -> `Null);
          ("timestamp", `Float (Time_compat.now ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        (* Notification harness: push broadcast to session queues for polling-only agents *)
        Subscriptions.push_event_to_sessions notification;
        (* macOS notification for @mention *)
        (match mention with
         | Some target -> Notify.notify_mention ~from_agent:agent_name ~target_agent:target ~message ()
         | None -> ());
        (* Notify A2A subscribers for polling *)
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:agent_name
          ~data:(`Assoc [
            ("message", `String message);
            ("mention", match mention with Some m -> `String m | None -> `Null);
          ]);
        (* Auto-Responder: spawn mentioned agent if enabled *)
        let _ = Auto_responder.maybe_respond
          ~sw
          ~base_path:config.base_path
          ~from_agent:agent_name
          ~content:message
          ~mention
        in
        (* Increment broadcast_count in active team sessions *)
        Team_session_engine_eio.increment_broadcast_from_external config
          ~agent_name;
        (* Audit: log broadcast event *)
        Audit_log.log_broadcast config ~agent_id:agent_name
          ~room_id:(Filename.basename config.base_path)
          ~message_preview:message ();
        (true, result)
      end

  | "masc_messages" ->
      let since_seq = arg_get_int "since_seq" 0 in
      let limit = arg_get_int "limit" 10 in
      (true, Room.get_messages config ~since_seq ~limit)



  | "masc_listen" ->
      let timeout = float_of_int (arg_get_int "timeout" 300) in
      Log.Mcp.info "%s is now listening (timeout: %.0fs)..." agent_name timeout;
      (* Eio native - uses Session registry with Eio.Time.sleep *)
      let msg_opt = wait_for_message_eio ~clock registry ~agent_name ~timeout in
      (match msg_opt with
       | Some msg ->
           let from = match Json_util.get_string msg "from" with Some v -> v | None -> raise Not_found in
           let content = match Json_util.get_string msg "content" with Some v -> v | None -> raise Not_found in
           let timestamp = match Json_util.get_string msg "timestamp" with Some v -> v | None -> raise Not_found in
           (true, Printf.sprintf {|
🔔 **MESSAGE RECEIVED!**
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
From: %s
Time: %s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💡 Call masc_listen again to continue listening.
|} from timestamp content)
       | None ->
           (true, Printf.sprintf "⏰ Listening timed out after %.0fs. No messages received." timeout))

  | "masc_who" ->
      (true, Session.status_string registry)





















  | "masc_verify_request" | "masc_verify_submit" | "masc_verify_status"
  | "masc_verify_pending" | "masc_verify_auto" ->
      Tool_verification.dispatch config agent_name name arguments

  (* A2A Agent Card - Discovery *)
























  | "masc_mcp_session" ->
      let action = arg_get_string "action" "" in
      let now = Time_compat.now () in
      let sessions = load_mcp_sessions config in
      let save sessions = save_mcp_sessions config sessions in
      let response =
        match action with
        | "create" ->
            let agent_name = arg_get_string_opt "agent_name" in
            let id = Mcp_session.generate () in
            let record = { id; agent_name; created_at = now; last_seen = now } in
            save (record :: sessions);
            Ok (`Assoc [
              ("status", `String "created");
              ("session", mcp_session_to_json record);
            ])
        | "get" ->
            let session_id = arg_get_string "session_id" "" in
            (match List.find_opt (fun s -> s.id = session_id) sessions with
             | None -> Error (Printf.sprintf "MCP session '%s' not found" session_id)
             | Some s ->
                 let updated = { s with last_seen = now } in
                 let others = List.filter (fun x -> x.id <> session_id) sessions in
                 save (updated :: others);
                 Ok (`Assoc [
                   ("status", `String "ok");
                   ("session", mcp_session_to_json updated);
                 ]))
        | "list" ->
            Ok (`Assoc [
              ("count", `Int (List.length sessions));
              ("sessions", `List (List.map mcp_session_to_json sessions));
            ])
        | "cleanup" ->
            let cutoff = now -. (7.0 *. 86400.0) in
            let remaining = List.filter (fun s -> s.last_seen >= cutoff) sessions in
            let removed = List.length sessions - List.length remaining in
            save remaining;
            Ok (`Assoc [
              ("status", `String "cleaned");
              ("removed", `Int removed);
              ("remaining", `Int (List.length remaining));
            ])
        | "remove" ->
            let session_id = arg_get_string "session_id" "" in
            let remaining = List.filter (fun s -> s.id <> session_id) sessions in
            if List.length remaining = List.length sessions then
              Error (Printf.sprintf "MCP session '%s' not found" session_id)
            else begin
              save remaining;
              Ok (`Assoc [
                ("status", `String "removed");
                ("session_id", `String session_id);
              ])
            end
        | other ->
            Error (Printf.sprintf "Unknown action: %s" other)
      in
      (match response with
       | Ok json -> (true, Yojson.Safe.pretty_to_string json)
       | Error e -> (false, e))

  | "masc_cancellation" ->
      Cancellation.handle_cancellation_tool arguments

  | "masc_subscription" ->
      Subscriptions.handle_subscription_tool arguments

  | "masc_progress" ->
      Progress.set_sse_callback (Mcp_server.sse_broadcast state);
      Progress.handle_progress_tool arguments

  (* Voting/Consensus tools *)







  | "masc_interrupt" ->
      let task_id = arg_get_string "task_id" "" in
      let step = arg_get_int "step" 1 in
      let action = arg_get_string "action" "" in
      let message = arg_get_string "message" "" in
      Notify.notify_interrupt ~agent:agent_name ~action;
      safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--step"; string_of_int step;
                 "--action"; action; "--agent"; agent_name; "--interrupt"; message]

  | "masc_approve" ->
      let task_id = arg_get_string "task_id" "" in
      safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                 "--task-id"; task_id; "--approve"]

  | "masc_reject" ->
      let task_id = arg_get_string "task_id" "" in
      let reason = arg_get_string "reason" "" in
      let args = if reason = "" then
        ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--task-id"; task_id; "--reject"]
      else
        ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--task-id"; task_id; "--reject"; "--reason"; reason]
      in
      safe_exec args

  | "masc_pending_interrupts" ->
      safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config; "--pending"]

  | "masc_branch" ->
      let task_id = arg_get_string "task_id" "" in
      let source_step = arg_get_int "source_step" 0 in
      let branch_name = arg_get_string "branch_name" "" in
      if task_id = "" || source_step = 0 || branch_name = "" then
        (false, "❌ task_id, source_step, and branch_name are required")
      else
        safe_exec ["masc-checkpoint"; "--masc-dir"; Room.masc_dir config;
                   "--task-id"; task_id; "--branch"; string_of_int source_step;
                   "--branch-name"; branch_name; "--agent"; agent_name]

  (* Cost Tracking *)










  | "masc_governance_set" ->
      let level = arg_get_string "level" "production" in
      let defaults = governance_defaults level in
      let audit_enabled = arg_get_bool "audit_enabled" defaults.audit_enabled in
      let anomaly_detection = arg_get_bool "anomaly_detection" defaults.anomaly_detection in
      let g = {
        level = String.lowercase_ascii level;
        audit_enabled;
        anomaly_detection;
      } in
      save_governance config g;
      let json = `Assoc [
        ("status", `String "ok");
        ("governance", `Assoc [
          ("level", `String g.level);
          ("audit_enabled", `Bool g.audit_enabled);
          ("anomaly_detection", `Bool g.anomaly_detection);
        ]);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

  (* Encryption tools *)





  | "masc_spawn" ->
      let spawn_agent_name = arg_get_string "agent_name" "" in
      let prompt = arg_get_string "prompt" "" in
      let timeout_seconds = arg_get_int "timeout_seconds" 300 in
      let model_name =
        match arguments |> Yojson.Safe.Util.member "model" with
        | `String s ->
            let trimmed = String.trim s in
            if trimmed = "" then None else Some trimmed
        | _ -> None
      in
      let runtime_model =
        match (spawn_agent_name, model_name) with
        | "llama", None -> Error "model is required when agent_name=llama"
        | "llama", Some raw ->
            let spec_name =
              if String.contains raw ':' then raw else "llama:" ^ raw
            in
            Llm_client.model_spec_of_string spec_name
        | _, Some _ -> Llm_client.default_execution_model_spec ()
        | _, None -> Llm_client.default_execution_model_spec ()
      in
      let module U = Yojson.Safe.Util in
      let working_dir = match arguments |> U.member "working_dir" with
        | `String s when s <> "" -> Some s
        | _ -> None
      in
       (match runtime_model with
       | Error e -> (false, e)
       | Ok runtime_model ->
           (match state.Mcp_server.proc_mgr with
            | Some pm ->
                let result =
                  Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:spawn_agent_name
                    ~prompt ~timeout_seconds ?working_dir
                    ~room_config:state.Mcp_server.room_config
                    ~runtime_model ()
                in
                (result.Spawn_eio.success, Spawn_eio.result_to_human_string result)
            | None ->
                (false, "❌ Process manager not available in this environment")))

  (* Dashboard tool *)









  | "masc_memento_mori" ->
      let context_ratio = arg_get_float "context_ratio" 0.0 in
      let full_context = arg_get_string "full_context" "" in
      let summary = arg_get_string "summary" "" in
      let current_task = arg_get_string "current_task" "" in
      let target_agent = arg_get_string "target_agent" "claude" in
      let cell = !(Mcp_server.current_cell) in
      let mitosis_config = Mitosis.default_config in

      (* Use should_prepare and should_handoff directly *)
      let should_prepare_now = Mitosis.should_prepare ~config:mitosis_config ~cell ~context_ratio in
      let should_handoff_now = Mitosis.should_handoff ~config:mitosis_config ~cell ~context_ratio in

      if not should_prepare_now && not should_handoff_now then begin
        (* <50%: Continue working, no action needed *)
        let warning = if context_ratio = 0.0 then
          [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
        else [] in
        let response = `Assoc ([
          ("status", `String "continue");
          ("context_ratio", `Float context_ratio);
          ("threshold_prepare", `Float mitosis_config.prepare_threshold);
          ("threshold_handoff", `Float mitosis_config.handoff_threshold);
          ("message", `String (Printf.sprintf "💚 Context healthy (%.0f%%). Continue working." (context_ratio *. 100.0)));
        ] @ warning) in
        (true, Yojson.Safe.pretty_to_string response)
      end
      else if should_prepare_now && not should_handoff_now then begin
        (* 50-80%: Prepare DNA but don't handoff yet *)
        if full_context = "" then
          (false, "❌ full_context required when context_ratio > 50%")
        else begin
          let prepared_cell = Mitosis.prepare_for_division ~config:mitosis_config ~cell ~full_context in
          Mcp_server.current_cell := prepared_cell;
          let response = `Assoc [
            ("status", `String "prepared");
            ("context_ratio", `Float context_ratio);
            ("phase", `String (Mitosis.phase_to_string prepared_cell.phase));
            ("dna_extracted", `Bool (prepared_cell.prepared_dna <> None));
            ("message", `String (Printf.sprintf "🟡 Context at %.0f%%. DNA prepared. Handoff at 80%%." (context_ratio *. 100.0)));
          ] in
          (true, Yojson.Safe.pretty_to_string response)
        end
      end
      else begin
        (* >80%: Execute division and spawn successor *)
        if full_context = "" then
          (false, "❌ full_context required for handoff")
        else begin
          (* Agent Being Protocol: Last Words - broadcast final reflection before division *)
          let last_words = Printf.sprintf
            "🕯️ **LAST WORDS from Generation %d**\n\n\
             I am %s, about to divide.\n\
             %s\n\n\
             Tasks completed: %d | Tool calls: %d\n\
             Age: %.1f minutes\n\n\
             My context is full (%.0f%%), but my work continues through Generation %d.\n\
             Carry on, successors. 🌱"
            cell.Mitosis.generation
            cell.Mitosis.id
            (if summary = "" then "My time has come." else summary)
            cell.Mitosis.task_count
            cell.Mitosis.tool_call_count
            ((Time_compat.now () -. cell.Mitosis.born_at) /. 60.0)
            (context_ratio *. 100.0)
            (cell.Mitosis.generation + 1)
          in
          (* Broadcast last words to the room *)
          let _ = Room.broadcast config ~from_agent:agent_name ~content:last_words in

          (* Create spawn function - use Eio-native spawn to avoid blocking *)
          match state.Mcp_server.proc_mgr with
          | None ->
              (false, "❌ Process manager not available for mitosis spawn")
          | Some pm ->
              let spawn_fn ~prompt =
                let result = Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:target_agent
                  ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds
                  ~room_config:state.Mcp_server.room_config ()
                in
                (* Convert Spawn_eio.spawn_result to Spawn.spawn_result for Mitosis compatibility *)
                { Spawn.success = result.Spawn_eio.success;
                  output = result.Spawn_eio.output;
                  exit_code = result.Spawn_eio.exit_code;
                  elapsed_ms = result.Spawn_eio.elapsed_ms;
                  input_tokens = result.Spawn_eio.input_tokens;
                  output_tokens = result.Spawn_eio.output_tokens;
                  cache_creation_tokens = result.Spawn_eio.cache_creation_tokens;
                  cache_read_tokens = result.Spawn_eio.cache_read_tokens;
                  cost_usd = result.Spawn_eio.cost_usd }
              in

              (* Execute full mitosis *)
              let (spawn_result, new_cell, new_pool, _handoff_dna) =
                Mitosis.execute_mitosis
                  ~config:mitosis_config
                  ~pool:!(Mcp_server.stem_pool)
                  ~parent:cell
                  ~full_context:(Printf.sprintf "Summary: %s\n\nCurrent Task: %s\n\nContext:\n%s"
                      (if summary = "" then "Memento mori - context limit reached" else summary)
                      current_task full_context)
                  ~spawn_fn
              in
              Mcp_server.current_cell := new_cell;
              Mcp_server.stem_pool := new_pool;

              let response = `Assoc [
                ("status", `String "divided");
                ("context_ratio", `Float context_ratio);
                ("previous_generation", `Int cell.generation);
                ("new_generation", `Int new_cell.generation);
                ("successor_spawned", `Bool spawn_result.Spawn.success);
                ("successor_agent", `String target_agent);
                ("successor_output", `String (String.sub spawn_result.Spawn.output 0 (min 500 (String.length spawn_result.Spawn.output))));
                ("message", `String (Printf.sprintf "🔴 Context critical (%.0f%%). Cell divided. %s successor spawned." (context_ratio *. 100.0) target_agent));
              ] in
              (true, Yojson.Safe.pretty_to_string response)
        end
      end

  (* ============================================ *)
  (* Agent Being Protocol - Episode Tools        *)
  (* ============================================ *)

  | "masc_episode_flush" ->
      let limit = arg_get_int "limit" 10 in
      let dry_run = arg_get_bool "dry_run" false in
      let base_path = config.Room_utils.base_path in
      let pending_dir = Filename.concat base_path ".masc/pending_episodes" in

      (* List pending episodes *)
      let pending_files =
        try
          Sys.readdir pending_dir
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.sort String.compare
          |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
        with Sys_error _ -> []
      in

      if dry_run then begin
        let response = `Assoc [
          ("dry_run", `Bool true);
          ("pending", `Int (List.length pending_files));
          ("would_flush", `List (List.map (fun f -> `String f) pending_files));
        ] in
        (true, Yojson.Safe.pretty_to_string response)
      end else begin
        (* Flush episodes to DB (requires Eio env - use jiphyeon module) *)
        let flushed = ref 0 in
        let failed = ref 0 in

        (* Helper to parse outcome *)
        let parse_outcome s = match s with
          | "success" -> `Success
          | "failure" -> `Failure
          | _ -> `Partial
        in

        (* Helper to parse string list *)
        let parse_string_list = function
          | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
        in

        (* Helper to parse context key-value pairs *)
        let parse_context = function
          | `Assoc l -> List.filter_map (fun (k, v) ->
              match v with `String s -> Some (k, s) | _ -> None) l
          | _ -> []
        in

        List.iter (fun file ->
          let file_path = Filename.concat pending_dir file in
          try
            let ic = open_in file_path in
            let content =
              Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                ~finally:(fun () -> close_in_noerr ic)
                (fun () ->
                  let buf = Buffer.create 4096 in
                  (try
                    while true do
                      Buffer.add_channel buf ic 1024
                    done
                  with End_of_file -> ());
                  Buffer.contents buf)
            in
            (* Parse and validate *)
            let json = Yojson.Safe.from_string content in
            let module U = Yojson.Safe.Util in
            let ep_id = match Json_util.get_string json "ep_id" with Some v -> v | None -> raise Not_found in

            (* Build Episode record from JSON *)
            let episode : Jiphyeon.Archive.episode = {
              ep_id;
              session_id = json |> U.member "session_id" |> U.to_string;
              agent_name = json |> U.member "agent_name" |> U.to_string;
              generation = json |> U.member "generation" |> U.to_int;
              parent_episode = Json_util.get_string json "parent_episode";
              event_type = json |> U.member "event_type" |> U.to_string;
              summary = json |> U.member "summary" |> U.to_string;
              dna = Json_util.get_string json "dna";
              outcome = json |> U.member "outcome" |> U.to_string |> parse_outcome;
              learnings = json |> U.member "learnings" |> parse_string_list;
              context = json |> U.member "context" |> parse_context;
              timestamp = json |> U.member "timestamp" |> U.to_string;
            } in

            (* Save to PostgreSQL + Neo4j using Jiphyeon.Archive *)
            (match state.Mcp_server.env with
             | Some env ->
               (* Use the existing sw from execute_tool_eio *)
               (match Jiphyeon.Archive.save_episode ~sw ~env episode with
                | Ok () ->
                  Printf.printf "[EPISODE/SAVED] Episode %s saved to PostgreSQL + Neo4j\n%!" ep_id
                | Error e ->
                  Printf.eprintf "[EPISODE/WARN] DB save failed (file kept): %s\n%!" e)
             | None ->
               Printf.eprintf "[EPISODE/WARN] No env available, skipping DB save\n%!"
            );

            (* Move to processed/ *)
            let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
            (try Unix.mkdir processed_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
            let new_path = Filename.concat processed_dir file in
            Sys.rename file_path new_path;
            Printf.printf "[EPISODE/FLUSH] Processed episode %s → %s\n%!" ep_id new_path;
            incr flushed
          with exn ->
            Printf.eprintf "[EPISODE/ERROR] Failed to flush %s: %s\n%!" file (Printexc.to_string exn);
            incr failed
        ) pending_files;

        let remaining =
          try Array.length (Sys.readdir pending_dir) with Sys_error _ -> 0
        in
        let response = `Assoc [
          ("flushed", `Int !flushed);
          ("failed", `Int !failed);
          ("remaining", `Int remaining);
          ("message", `String (Printf.sprintf "Flushed %d episodes (%d failed, %d remaining)" !flushed !failed remaining));
        ] in
        (true, Yojson.Safe.pretty_to_string response)
      end

  | "masc_episode_list" ->
      let agent_filter = arg_get_string_opt "agent_name" in
      let gen_filter = match arguments with
        | `Assoc fields -> (match List.assoc_opt "generation" fields with
            | Some (`Int n) -> Some n
            | _ -> None)
        | _ -> None
      in
      let limit = arg_get_int "limit" 20 in
      let base_path = config.Room_utils.base_path in

      (* Collect from processed_episodes (already flushed) *)
      let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
      let episodes =
        try
          Sys.readdir processed_dir
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.sort (fun a b -> String.compare b a)  (* Newest first *)
          |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
          |> List.filter_map (fun file ->
              try
                let path = Filename.concat processed_dir file in
                let ic = open_in path in
                let content =
                  Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                    ~finally:(fun () -> close_in_noerr ic)
                    (fun () ->
                      let buf = Buffer.create 4096 in
                      (try while true do Buffer.add_channel buf ic 1024 done with End_of_file -> ());
                      Buffer.contents buf)
                in
                let json = Yojson.Safe.from_string content in
                let ep_agent = let module U = Yojson.Safe.Util in
                U.(json |> member "agent_name" |> to_string) in
                let ep_gen = U.(json |> member "generation" |> to_int) in
                (* Apply filters *)
                let agent_ok = match agent_filter with None -> true | Some a -> ep_agent = a in
                let gen_ok = match gen_filter with None -> true | Some g -> ep_gen = g in
                if agent_ok && gen_ok then Some json else None
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
            )
        with Sys_error _ -> []
      in

      let response = `Assoc [
        ("count", `Int (List.length episodes));
        ("episodes", `List episodes);
      ] in
      (true, Yojson.Safe.pretty_to_string response)

  | "masc_self_introspect" ->
      let cell = !(Mcp_server.current_cell) in
      let generation = cell.Mitosis.generation in
      let tool_calls = cell.Mitosis.tool_call_count in
      let task_count = cell.Mitosis.task_count in

      (* Estimate context usage from tool calls *)
      let estimated_ratio = Float.min 1.0 (Float.of_int tool_calls /. Mitosis.Defaults.tool_calls_per_full_context) in
      let status =
        if estimated_ratio >= Mitosis.default_config.handoff_threshold then "critical"
        else if estimated_ratio >= Mitosis.default_config.prepare_threshold then "warning"
        else "healthy" in

      (* Estimate remaining lifespan *)
      let remaining_ratio = 1.0 -. estimated_ratio in
      let estimated_remaining_tools = int_of_float (remaining_ratio *. Mitosis.Defaults.tool_calls_per_full_context) in

      (* Calculate age in seconds *)
      let now = Time_compat.now () in
      let age_seconds = now -. cell.Mitosis.born_at in
      let age_human =
        if age_seconds < 60.0 then Printf.sprintf "%.0f seconds" age_seconds
        else if age_seconds < 3600.0 then Printf.sprintf "%.1f minutes" (age_seconds /. 60.0)
        else Printf.sprintf "%.1f hours" (age_seconds /. 3600.0)
      in

      (* Check for siblings (other agents of same generation in room) *)
      let all_statuses = Mitosis.get_all_statuses ~room_config:config in
      let siblings = List.filter (fun (_, _, _) -> true) all_statuses in

      (* Count episodes from PostgreSQL (memory count) *)
      (* Use cell.id as agent identifier for episode lookup *)
      let cell_id = cell.Mitosis.id in
      let episode_count, recent_episode =
        match state.Mcp_server.env with
        | Some env ->
          (try
            (* Use existing sw from execute_tool_eio *)
            (match Jiphyeon.Archive.get_agent_episodes ~sw ~env cell_id 5 with
             | Ok episodes -> (List.length episodes, List.nth_opt episodes 0)
             | Error _ -> (0, None))
          with exn ->
            Printf.eprintf "[warn] %s: %s\n" __FUNCTION__ (Printexc.to_string exn);
            (0, None))
        | None -> (0, None)
      in

      (* Mortality awareness message *)
      let mortality_msg =
        if estimated_ratio >= 0.8 then
          "⚠️ Approaching end of lifecycle. Consider preparing DNA for successor."
        else if estimated_ratio >= 0.5 then
          "📊 Mid-lifecycle. Context accumulating normally."
        else
          "🌱 Early lifecycle. Plenty of context remaining."
      in

      let response = `Assoc [
        ("generation", `Int generation);
        ("cell_id", `String cell_id);
        ("context_used", `Float estimated_ratio);
        ("status", `String status);
        ("tool_calls", `Int tool_calls);
        ("task_count", `Int task_count);
        ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
        ("born_at", `Float cell.Mitosis.born_at);
        ("age_seconds", `Float age_seconds);
        ("age_human", `String age_human);
        ("estimated_remaining_tools", `Int estimated_remaining_tools);
        ("siblings_in_room", `Int (List.length siblings));
        ("parent_dna", match cell.Mitosis.context_dna with Some _ -> `Bool true | None -> `Bool false);
        ("episode_count", `Int episode_count);
        ("recent_episode", match recent_episode with
          | Some (ep_id, event_type, _, summary) ->
            `Assoc [("ep_id", `String ep_id); ("event_type", `String event_type); ("summary", `String summary)]
          | None -> `Null);
        ("mortality_awareness", `String mortality_msg);
        ("message", `String (Printf.sprintf "Generation %d | Age %s | Context %.0f%% (%s) | ~%d tool calls remaining | %d memories"
          generation age_human (estimated_ratio *. 100.0) status estimated_remaining_tools episode_count));
      ] in
      (true, Yojson.Safe.pretty_to_string response)

  | "masc_recall_search" ->
      (* Agent Being Protocol: Semantic memory recall from local sources *)
      let module U = Yojson.Safe.Util in
      let query = match Json_util.get_string arguments "query" with Some v -> v | None -> raise Not_found in
      let limit = arguments |> U.member "limit" |> U.to_int_option |> Option.value ~default:5 in

      (match state.Mcp_server.env with
       | None ->
           (true, Yojson.Safe.pretty_to_string (`Assoc [
             ("success", `Bool false);
             ("error", `String "Database environment not available");
             ("suggestion", `String "Ensure runtime environment is initialized");
           ]))
       | Some env ->
           let recall_config = Auto_recall.make_config
             ~enabled:true
             ~sources:[Auto_recall.Recent_broadcasts; Auto_recall.Masc_cache; Auto_recall.File_context]
             ~max_tokens:4000
             ~max_broadcasts:limit
             ()
           in
           let result = Auto_recall.fetch_context_eio ~sw ~env ~clock config ~config:recall_config ~query () in
           let response = `Assoc [
             ("success", `Bool true);
             ("query", `String query);
             ("items", `List (List.map (fun (item : Auto_recall.recall_item) ->
               `Assoc [
                 ("source", `String (match item.source with
                   | Auto_recall.Masc_cache -> "cache"
                   | Auto_recall.Recent_broadcasts -> "broadcast"
                   | Auto_recall.File_context -> "file"));
                 ("content", `String item.content);
                 ("relevance", `Float item.relevance);
                 ("metadata", item.metadata);
               ]
             ) result.items));
             ("total_tokens", `Int result.total_tokens);
             ("truncated", `Bool result.truncated);
             ("message", `String (Printf.sprintf "Found %d relevant items for query: %s"
               (List.length result.items) query));
           ] in
           (* Audit: log search refinement *)
           let agent_name = Safe_ops.json_string ~default:"unknown" "agent_name" arguments in
           Audit_log.log_action config ~agent_id:agent_name ~action:Audit_log.SearchRefinement
             ~room_id:(Filename.basename config.base_path)
             ~details:(`Assoc [("query", `String query); ("results", `Int (List.length result.items))])
             ~outcome:Audit_log.Success ();
           (true, Yojson.Safe.pretty_to_string response))
  (* Board tools delegated to Tool_board module *)
  | "masc_board_post" ->
      let (success, message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        (* Push board_post event to SSE for event-spawner *)
        let notification = `Assoc [
          ("type", `String "masc/board_post");
          ("author", `String author);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("post_id", `String (
            (* Extract post_id from response message *)
            try
              let idx = String.index message '{' in
              let json = Yojson.Safe.from_string
                (String.sub message idx (String.length message - idx)) in
              Yojson.Safe.Util.(json |> member "id" |> to_string)
            with
            | Not_found | Invalid_argument _
            | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> "unknown"
          ));
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:author
          ~data:(`Assoc [
            ("event", `String "board_post");
            ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
          ])
      end;
      result
  | "masc_board_comment" ->
      let (success, message) as result = Tool_board.handle_tool name arguments in
      if success then begin
        let author = Safe_ops.json_string ~default:"anonymous" "author" arguments in
        let content = Safe_ops.json_string ~default:"" "content" arguments in
        let post_id = Safe_ops.json_string ~default:"unknown" "post_id" arguments in
        let notification = `Assoc [
          ("type", `String "board_comment");
          ("author", `String author);
          ("post_id", `String post_id);
          ("content", `String (String.sub content 0 (min 200 (String.length content))));
          ("timestamp", `String (Types.now_iso ()));
        ] in
        Mcp_server.sse_broadcast state notification;
        A2a_tools.notify_event
          ~event_type:A2a_tools.Broadcast
          ~agent:author
          ~data:(`Assoc [
            ("event", `String "board_comment");
            ("post_id", `String post_id);
            ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
          ])
      end;
      ignore message;
      result
  | "masc_board_list" | "masc_board_get"
  | "masc_board_vote" | "masc_board_stats"
  | "masc_board_search" | "masc_board_comment_vote" | "masc_board_profile"
  | "masc_board_hearths" | "masc_board_migrate" ->
      Tool_board.handle_tool name arguments

  (* Lodge tools delegated to Tool_lodge module *)
  | "lodge_heartbeat" | "lodge_classify" | "lodge_react" | "lodge_cycle"
  | "lodge_discussion" | "lodge_orchestrate" | "lodge_auto_chain"
  | "lodge_evolve" | "lodge_spawn" | "lodge_agents"
  | "lodge_agent_patrol" | "lodge_autonomous_loop"
  (* Project collaboration *)
  | "lodge_propose_project" | "lodge_join_project" | "lodge_share_code"
  | "lodge_research" | "lodge_profile"
  (* New: Search, Like, Progress *)
  | "lodge_search" | "lodge_comment_like" | "lodge_progress" ->
      (match state.Mcp_server.net with
       | Some net -> Tool_lodge.handle_tool ~net name arguments
       | None -> (false, "lodge tools require net (server_state.net is None)"))

  (* ============================================ *)
  (* Conversation Tools - Persistent Agent Dialogue *)
  (* ============================================ *)

  | "masc_convo_start" ->
      let topic = arg_get_string "topic" "" in
      let initiator = arg_get_string "initiator" agent_name in
      let initial_content = arg_get_string "initial_content" "" in
      let max_turns = arg_get_int "max_turns" 50 in
      let source_post_id = arg_get_string_opt "post_id" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if topic = "" then (false, "❌ topic required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.start ~config:convo_config ~topic ~initiator
                ~max_turns ~initial_content ?source_post_id () with
        | Ok thread ->
            (* Link Board post back to this thread *)
            let link_warning = match source_post_id with
              | Some pid ->
                  (match Board_dispatch.set_thread_id
                    ~post_id:pid ~thread_id:thread.Council.Conversation.id with
                   | Ok () -> ""
                   | Error e -> Printf.sprintf "\n⚠️ Board link failed: %s" (Board.show_board_error e))
              | None -> ""
            in
            let json = Council.Conversation.thread_to_yojson thread in
            (true, Printf.sprintf "✅ Thread started: %s%s\n%s"
              thread.Council.Conversation.id link_warning (Yojson.Safe.pretty_to_string json))
        | Error e -> (false, Printf.sprintf "❌ %s" e)
      end

  | "masc_convo_reply" ->
      let thread_id = arg_get_string "thread_id" "" in
      let speaker = arg_get_string "speaker" agent_name in
      let content = arg_get_string "content" "" in
      let confidence = arg_get_float_opt "confidence" in
      let reply_to = arg_get_string_opt "reply_to" in
      let mentions = arg_get_string_list "mentions" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" || content = "" then
        (false, "❌ thread_id and content required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        (* Check loop guard first *)
        match Council.Conversation.get ~config:convo_config ~thread_id with
        | None -> (false, Printf.sprintf "❌ Thread not found: %s" thread_id)
        | Some thread ->
            let loop_check = Council.Loop_guard.check
              ~thread ~speaker ~content
              ~config:Council.Loop_guard.default_config
            in
            match Council.Loop_guard.to_error_message loop_check with
            | Some err -> (false, Printf.sprintf "🛑 Loop detected: %s" err)
            | None ->
                match Council.Conversation.reply ~config:convo_config ~thread_id
                        ~speaker ~content ?confidence ?reply_to ~mentions () with
                | Ok updated ->
                    let json = Council.Conversation.thread_to_yojson updated in
                    (true, Printf.sprintf "✅ Reply added (turn %d)\n%s"
                      updated.Council.Conversation.current_turn
                      (Yojson.Safe.pretty_to_string json))
                | Error e -> (false, Printf.sprintf "❌ %s" e)
      end

  | "masc_convo_conclude" ->
      let thread_id = arg_get_string "thread_id" "" in
      let concluder = arg_get_string "concluder" agent_name in
      let conclusion = arg_get_string "conclusion" "" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" || conclusion = "" then
        (false, "❌ thread_id and conclusion required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.conclude ~config:convo_config ~thread_id
                ~concluder ~conclusion () with
        | Ok thread ->
            let json = Council.Conversation.thread_to_yojson thread in
            (true, Printf.sprintf "✅ Thread concluded: %s\n%s"
              thread.Council.Conversation.id (Yojson.Safe.pretty_to_string json))
        | Error e -> (false, Printf.sprintf "❌ %s" e)
      end

  | "masc_convo_get" ->
      let thread_id = arg_get_string "thread_id" "" in
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      if thread_id = "" then (false, "❌ thread_id required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = current_room;
        } in
        match Council.Conversation.get ~config:convo_config ~thread_id with
        | Some thread ->
            let json = Council.Conversation.thread_to_yojson thread in
            (true, Yojson.Safe.pretty_to_string json)
        | None -> (false, Printf.sprintf "❌ Thread not found: %s" thread_id)
      end

  | "masc_convo_list" ->
      let current_room = Room.read_current_room config |> Option.value ~default:"default" in
      let convo_config : Council.Conversation.config = {
        base_path = config.base_path;
        room = current_room;
      } in
      let threads = Council.Conversation.list_active ~config:convo_config in
      let json = `List (List.map (fun th ->
        `Assoc [
          ("id", `String th.Council.Conversation.id);
          ("topic", `String th.Council.Conversation.topic);
          ("status", `String (Council.Conversation.thread_status_to_string th.Council.Conversation.status));
          ("turns", `Int th.Council.Conversation.current_turn);
          ("participants", `List (List.map (fun p -> `String p) th.Council.Conversation.participants));
        ]
      ) threads) in
      (true, Printf.sprintf "📋 Active threads: %d\n%s"
        (List.length threads) (Yojson.Safe.pretty_to_string json))

  | _ ->
      (false, Printf.sprintf "Unknown tool: %s" name)

(** {1 Eio-Native JSON-RPC Handlers} *)

(** Parse bounded int from environment variable. *)
let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let parsed =
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v parsed)

let contains_casefold haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let parse_status_from_message ~success ~message =
  if not success then
    if
      contains_casefold message "input required"
      || contains_casefold message "ask agent"
      || contains_casefold message "ask agent question"
    then
      ("ask_agent_question", Some "ask_agent_question")
    else if
      contains_casefold message "auth required"
      || contains_casefold message "authentication required"
      || contains_casefold message "unauthorized"
    then
      ("ask_for_auth", Some "ask_for_auth")
    else
      ("error", None)
  else
    ("ok", None)

let quality_issue severity code message attempts =
  `Assoc [
    ("severity", `String severity);
    ("code", `String code);
    ("message", `String message);
    ("retry_attempts", `Int attempts);
  ]

let quality_from_result ~success ~message ~attempts =
  if success then
    `Assoc [
      ("passed", `Bool true);
      ("issues", `List []);
    ]
  else
    let issue =
      if contains_casefold message "timeout" then
        quality_issue "warning" "tool_timeout" message attempts
      else
        quality_issue "error" "tool_failure" message attempts
    in
    `Assoc [
      ("passed", `Bool false);
      ("issues", `List [issue]);
    ]

let read_only_retry_limit () =
  match Sys.getenv_opt "MASC_TOOL_READONLY_RETRY_LIMIT" with
  | Some raw ->
      (try
         let parsed = int_of_string (String.trim raw) in
         max 1 (min 5 parsed)
       with Failure _ -> 2)
  | None -> 2

let is_retryable_message message =
  contains_casefold message "timeout" ||
  contains_casefold message "temporary" ||
  contains_casefold message "temporarily" ||
  contains_casefold message "econn" ||
  contains_casefold message "connection" ||
  contains_casefold message "unavailable" ||
  contains_casefold message "rate limit" ||
  contains_casefold message "502" ||
  contains_casefold message "503"

let read_only_retry_wait ~attempt =
  let attempt = float_of_int attempt in
  min 1.5 (0.2 *. attempt)

let call_tool_with_readonly_retry
    ~clock
    ~run_tool
    ~is_read_only
    () =
  let max_attempts = read_only_retry_limit () in
  let rec loop attempt =
    let (success, message) =
      run_tool ()
    in
    if
      success
      || attempt >= max_attempts
      || not is_read_only
      || not (is_retryable_message message)
    then
      (success, message, attempt)
    else (
      Eio.Time.sleep clock (read_only_retry_wait ~attempt);
      loop (attempt + 1))
  in
  loop 1

let coerce_tool_timeout_sec (raw_timeout_sec : float option) : float option =
  match raw_timeout_sec with
  | None -> None
  | Some raw when raw <= 0.0 -> None
  | Some raw ->
      let raw_sec = int_of_float (Float.ceil raw) in
      Some (float_of_int (max 5 (min 300 raw_sec)))

(** Optional per-tool timeout to prevent long calls from starving the request loop.
    For request-specific controls (currently masc_keeper_msg), we clamp against an
    environment cap when present. *)
let tool_timeout_sec_opt ~(tool_name : string) ~(arguments : Yojson.Safe.t) : float option =
  let default_timeout_sec =
    float_of_int
      (int_of_env_default
         "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
         ~default:45
         ~min_v:10
         ~max_v:300)
  in
  match tool_name with
  | "masc_keeper_msg" ->
      let requested_timeout_sec = coerce_tool_timeout_sec (Safe_ops.json_float_opt "timeout_sec" arguments) in
      Some (Option.value requested_timeout_sec ~default:default_timeout_sec)
  | _ -> None

let resource_subscription_mutex = Eio.Mutex.create ()

let with_resource_subscription_lock f =
  try Eio.Mutex.use_rw ~protect:true resource_subscription_mutex f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let resource_subscriptions : (string, (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 64

let resource_is_dynamic uri =
  let lower = String.lowercase_ascii uri in
  not
    (String.contains lower '{'
     || String.starts_with ~prefix:"masc://schema" lower
     || String.starts_with ~prefix:"masc://institution" lower
     || String.starts_with ~prefix:"masc://tool-help" lower)

let subscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
      let uris =
        match Hashtbl.find_opt resource_subscriptions session_id with
        | Some uris -> uris
        | None ->
            let uris = Hashtbl.create 8 in
            Hashtbl.replace resource_subscriptions session_id uris;
            uris
      in
      Hashtbl.replace uris uri ())

let unsubscribe_resource_for_session ~session_id ~uri =
  with_resource_subscription_lock (fun () ->
      match Hashtbl.find_opt resource_subscriptions session_id with
      | Some uris ->
          Hashtbl.remove uris uri;
          if Hashtbl.length uris = 0 then
            Hashtbl.remove resource_subscriptions session_id
      | None -> ())

let clear_resource_subscriptions_for_session session_id =
  with_resource_subscription_lock (fun () ->
      Hashtbl.remove resource_subscriptions session_id)

let jsonrpc_notification ?params method_name =
  let base =
    [
      ("jsonrpc", `String "2.0");
      ("method", `String method_name);
    ]
  in
  `Assoc
    (base
    @
    match params with
    | Some params -> [ ("params", params) ]
    | None -> [])

let send_resource_updated_notification ~session_id ~uri =
  Sse.send_to session_id
    (jsonrpc_notification "notifications/resources/updated"
       ~params:(`Assoc [ ("uri", `String uri) ]))

let broadcast_tools_list_changed () =
  Sse.broadcast (jsonrpc_notification "notifications/tools/list_changed")

let dedup_strings items =
  items |> List.sort_uniq String.compare

let core_status_resource_ids =
  [ "status"; "status.json"; "events"; "events.json" ]

let task_resource_ids =
  dedup_strings (core_status_resource_ids @ [ "tasks"; "tasks.json" ])

let agent_resource_ids =
  dedup_strings
    (core_status_resource_ids
    @ [ "who"; "who.json"; "agents"; "agents.json" ])

let message_resource_ids =
  dedup_strings
    (core_status_resource_ids @ [ "messages"; "messages.json" ])

let worktree_resource_ids =
  dedup_strings
    (core_status_resource_ids @ [ "worktrees"; "worktrees.json" ])

let resource_id_of_uri uri =
  let resource_id, _uri = Mcp_server.parse_masc_resource_uri uri in
  resource_id

let affected_resource_ids_for_tool = function
  | "masc_add_task"
  | "masc_claim_next"
  | "masc_transition"
  | "masc_update_priority"
  | "masc_plan_set_task"
  | "masc_plan_clear_task" ->
      task_resource_ids
  | "masc_init"
  | "masc_join"
  | "masc_leave"
  | "masc_register_capabilities"
  | "masc_heartbeat"
  | "masc_suspend" ->
      agent_resource_ids
  | "masc_broadcast"
  | "masc_portal_open"
  | "masc_portal_send"
  | "masc_portal_close" ->
      message_resource_ids
  | "masc_worktree_create"
  | "masc_worktree_remove" ->
      worktree_resource_ids
  | _ -> core_status_resource_ids

let maybe_emit_resource_notifications ~success ~tool_name =
  if success && not (Tool_dispatch.is_read_only tool_name) then
    let affected_ids = affected_resource_ids_for_tool tool_name in
    with_resource_subscription_lock (fun () ->
        Hashtbl.iter
          (fun session_id uris ->
            Hashtbl.iter
              (fun uri () ->
                if
                  resource_is_dynamic uri
                  && List.mem (resource_id_of_uri uri) affected_ids
                then
                  send_resource_updated_notification ~session_id ~uri)
              uris)
          resource_subscriptions)

let () = Chain_native_eio.set_tool_executor execute_tool_eio

(** Eio-native handler for tools/call - uses execute_tool_eio directly *)
let handle_call_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state id params =
  let module U = Yojson.Safe.Util in
  let name = params |> U.member "name" |> U.to_string in
  let arguments = params |> U.member "arguments" in
  let is_read_only = Tool_dispatch.is_read_only name in

  (* Measure execution time for telemetry *)
  let start_time = Eio.Time.now clock in
  let timeout_hit = ref false in
let execute_with_timeout () =
    let local_timeout_hit = ref false in
    let result =
      try
        match tool_timeout_sec_opt ~tool_name:name ~arguments with
        | None ->
            execute_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state ~name ~arguments
        | Some timeout_sec ->
            (try
               Eio.Time.with_timeout_exn
                 clock
                 timeout_sec
                 (fun () ->
                   execute_tool_eio
                     ~sw
                     ~clock
                     ?mcp_session_id
                     ?auth_token
                     state
                     ~name
                     ~arguments)
             with Eio.Time.Timeout ->
               local_timeout_hit := true;
               Log.Mcp.error "tools/call timeout: %s after %.0fs" name timeout_sec;
               (false,
                Printf.sprintf
                  "❌ Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC)"
                  timeout_sec
                  name))
     with exn ->
       (* Never let a tool exception crash the MCP server. *)
       let err = Printexc.to_string exn in
       if contains_casefold err "Invalid_argument(\"MASC not initialized" then
         (false, Types.masc_error_to_string Types.NotInitialized)
       else
         (Log.Mcp.error "tools/call crashed: %s" err;
          false, Printf.sprintf "❌ Internal error: %s" err)
  in
  if !local_timeout_hit then timeout_hit := true;
  result
in
    let (success, message, attempts) =
    if is_read_only then
    call_tool_with_readonly_retry
      ~clock
      ~run_tool:execute_with_timeout
      ~is_read_only
      ()
  else
    let (success, message) = execute_with_timeout () in
    (success, message, 1)
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in

  (* Audit log (tool_call) if enabled *)
  let agent_name =
    Safe_ops.json_string ~default:"unknown" "agent_name" arguments
  in
  (* Audit: log tool_call via canonical Audit_log *)
  let error_msg = if success then None else Some (Printf.sprintf "timeout=%d|duration_ms=%d" (if !timeout_hit then 1 else 0) duration_ms) in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:name ~success ~error_msg ();

  (* Track tool call in telemetry (controlled by MASC_TELEMETRY_ENABLED) *)
  let telemetry_enabled =
    match Sys.getenv_opt "MASC_TELEMETRY_ENABLED" with
    | Some "false" | Some "0" -> false
    | _ -> true  (* Default: enabled *)
  in
  if telemetry_enabled then
    (match state.Mcp_server.fs with
     | Some fs ->
         (try Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
                ~tool_name:name ~success ~duration_ms ()
          with exn ->
            Printf.eprintf "[WARN] telemetry tracking failed: %s\n%!" (Printexc.to_string exn))
     | None -> ());

  (* Track in-memory call counter only for declared tool names. *)
  Tool_registry.record_call_if_known ~tool_name:name ~success ~duration_ms;

  let trace_id =
    match id with
    | `String s -> s
    | `Int i -> string_of_int i
    | `Intlit s -> s
    | `Float f -> Printf.sprintf "%0.0f" f
    | _ -> "unknown"
  in
  let (status, required_follow_up) = parse_status_from_message ~success ~message in
  let quality = quality_from_result ~success ~message ~attempts in
  let envelope =
    `Assoc [
      ("kind", `String "tool_call");
      ("summary", `String message);
      ("status", `String status);
      ("tool", `String name);
      ("required_follow_up",
       (match required_follow_up with
        | None -> `Null
        | Some value -> `String value));
      ("trace_id", `String trace_id);
      ("quality", quality);
    ]
  in
  let content_items =
    [
      `Assoc
        [
          ("type", `String "text");
          ("text", `String message);
        ]
    ]
  in
  let structured_content =
    match name with
    | "masc_swarm_live_run"
    | "masc_team_session_status"
    | "masc_operator_digest" -> (
        try Some (Yojson.Safe.from_string message) with _ -> None)
    | _ -> None
  in
  let result_fields =
    [
      ("resultEnvelope", envelope);
      ("content", `List content_items);
      ("isError", `Bool (not success));
    ]
    @
    match structured_content with
    | Some value -> [ ("structuredContent", value) ]
    | None -> []
  in
  let result = make_response ~id (`Assoc result_fields) in

  maybe_emit_resource_notifications ~success ~tool_name:name;
  if success
     && List.mem name [ "masc_switch_mode"; "masc_tool_admin_update" ]
  then
    broadcast_tools_list_changed ();

  (* Log result *)
  let preview =
    if String.length message > 80
    then String.sub message 0 80 ^ "..."
    else message
  in
  let preview = String.map (function '\n' -> ' ' | c -> c) preview in
  Log.Mcp.info "%s → %s" name preview;

  result

(** Eio-native handlers for simple methods *)
let operator_remote_instructions =
  "MASC remote operator profile exposes only four control-plane tools: \
masc_operator_snapshot, masc_operator_digest, masc_operator_action, and masc_operator_confirm. \
Read raw state with masc_operator_snapshot first when needed, and prefer masc_operator_digest for intervention-oriented supervision. \
Use masc_operator_action for guided actions only. \
When confirm_required=true, you must call masc_operator_confirm with the returned confirm_token before the action executes. \
Do not assume access to any other MASC tool from this endpoint."

let default_instructions =
  "MASC (Multi-Agent Streaming Coordination) enables AI agent collaboration. \
ROOM: Agents sharing the same base path (.masc/ folder) or PostgreSQL cluster coordinate together. \
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine coordination (defaults to basename of ME_ROOT). \
READ: use resources/list + resources/read (status/tasks/agents/events/schema) for snapshots. \
WRITE: prefer masc_transition (claim/start/done/cancel/release) with expected_version for CAS. \
WORKFLOW: masc_status → masc_transition(claim) → masc_worktree_create (isolation) → work → masc_transition(done). \
Use masc_heartbeat periodically; use @agent mentions in masc_broadcast. \
Prefer worktrees for parallel work."

let tool_schemas_for_profile ?(include_hidden = false) ?(include_deprecated = false)
    ?mode_override state profile =
  match profile with
  | Full ->
      let categories =
        match mode_override with
        | Some mode_str ->
            (match Mode.mode_of_string (String.lowercase_ascii mode_str) with
             | Some mode -> Mode.categories_for_mode mode
             | None ->
                 let room_path = Room.masc_dir state.Mcp_server.room_config in
                 let config = Config.load room_path in
                 config.Config.enabled_categories)
        | None ->
            let room_path = Room.masc_dir state.Mcp_server.room_config in
            let config = Config.load room_path in
            config.Config.enabled_categories
      in
      Config.enabled_tool_schemas ~include_hidden ~include_deprecated categories
  | Operator_remote -> Tool_operator.remote_schemas

let tool_allowed_in_profile profile tool_name =
  match profile with
  | Full -> true
  | Operator_remote -> List.mem tool_name Tool_operator.remote_tool_names

let is_destructive_tool_name name =
  let lowered = String.lowercase_ascii name in
  List.exists
    (fun fragment ->
      let len = String.length fragment in
      let lowered_len = String.length lowered in
      let rec loop idx =
        if idx + len > lowered_len then false
        else if String.sub lowered idx len = fragment then true
        else loop (idx + 1)
      in
      loop 0)
    [ "delete"; "remove"; "reset"; "revoke"; "disable"; "kill_switch"; "retire" ]

let is_idempotent_tool_name name =
  let lowered = String.lowercase_ascii name in
  List.exists
    (fun prefix ->
      let prefix_len = String.length prefix in
      String.length lowered >= prefix_len
      && String.sub lowered 0 prefix_len = prefix)
    [ "masc_status"; "masc_get_"; "masc_list"; "masc_tool_"; "masc_keeper_tool_catalog" ]

let tool_annotations_for_profile _profile tool_name =
  let read_only = Tool_dispatch.is_read_only tool_name in
  let fields =
    [ ("readOnlyHint", `Bool read_only) ]
    @
    if is_destructive_tool_name tool_name then
      [ ("destructiveHint", `Bool true) ]
    else
      []
    @
    if is_idempotent_tool_name tool_name || read_only then
      [ ("idempotentHint", `Bool true) ]
    else
      []
  in
  if fields = [] then None else Some (`Assoc fields)

let label_words_from_identifier ident =
  ident
  |> String.split_on_char '_'
  |> List.filter (fun chunk -> chunk <> "")
  |> List.map (fun word ->
         if String.length word = 0 then word
         else
           String.uppercase_ascii (String.sub word 0 1)
           ^ String.lowercase_ascii
               (String.sub word 1 (String.length word - 1)))

let tool_title_of_name name =
  let trimmed =
    if String.length name > 5 && String.sub name 0 5 = "masc_" then
      String.sub name 5 (String.length name - 5)
    else
      name
  in
  String.concat " " (label_words_from_identifier trimmed)

let tool_icons_for_name name =
  let icon =
    if Tool_dispatch.is_read_only name then
      Mcp_server.themed_icon ~label:"RD" ~bg:"#0F766E" ~fg:"#F0FDFA"
    else
      Mcp_server.themed_icon ~label:"WR" ~bg:"#9A3412" ~fg:"#FFF7ED"
  in
  [ icon ]

let maybe_assoc_field name = function
  | Some value -> [ (name, value) ]
  | None -> []

let permissive_object_schema properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("additionalProperties", `Bool true);
    ]

let tool_output_schema_field = function
  | "masc_swarm_live_run" ->
      Some
        (permissive_object_schema
           [
             ("status", `Assoc [ ("type", `String "string") ]);
             ("message", `Assoc [ ("type", `String "string") ]);
             ("run_id", `Assoc [ ("type", `String "string") ]);
             ("runtime_blocker", `Assoc [ ("type", `String "string") ]);
             ("runtime_doctor_path", `Assoc [ ("type", `String "string") ]);
             ("summary_path", `Assoc [ ("type", `String "string") ]);
             ("swarm", `Assoc [ ("type", `String "object") ]);
           ])
  | "masc_team_session_status" ->
      Some
        (permissive_object_schema
           [
             ("status", `Assoc [ ("type", `String "string") ]);
             ("result", `Assoc [ ("type", `String "object") ]);
           ])
  | "masc_operator_digest" ->
      Some
        (permissive_object_schema
           [
             ("target_type", `Assoc [ ("type", `String "string") ]);
             ("target_id", `Assoc [ ("type", `String "string") ]);
             ("health", `Assoc [ ("type", `String "string") ]);
             ("attention_items", `Assoc [ ("type", `String "array") ]);
             ("recommended_actions", `Assoc [ ("type", `String "array") ]);
           ])
  | _ -> None

let tool_json_for_profile ?usage_summary profile (schema : Types.tool_schema) =
  let base =
    [
      ("name", `String schema.name);
      ("title", `String (tool_title_of_name schema.name));
      ("description", `String schema.description);
      ( "icons",
        `List
          (List.map Mcp_server.icon_to_json (tool_icons_for_name schema.name)) );
      ("inputSchema", schema.input_schema);
    ]
    @ Tool_catalog.metadata_to_fields schema.name
    @ maybe_assoc_field "outputSchema" (tool_output_schema_field schema.name)
    @ maybe_assoc_field "annotations" (tool_annotations_for_profile profile schema.name)
    @
    match usage_summary with
    | Some summary -> Telemetry_eio.tool_usage_fields summary schema.name
    | None -> []
  in
  `Assoc base

type cursor_params = { cursor : string option }

type tools_list_params = {
  names : string list option;
  include_hidden : bool;
  include_deprecated : bool;
  include_usage : bool;
  mode : string option;
  tier : string option;
  cursor : string option;
}

let ( let* ) = Result.bind

let strict_assoc_params params =
  match params with
  | None -> Ok []
  | Some (`Assoc fields) -> Ok fields
  | Some _ -> Error "Invalid params: expected object"

let cursor_param payload =
  let open Yojson.Safe.Util in
  match payload |> member "cursor" with
  | `Null -> Ok None
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Error "Invalid params: cursor must not be empty"
      else
        Ok (Some trimmed)
  | _ -> Error "Invalid params: cursor must be a string"

let bool_param payload key =
  let open Yojson.Safe.Util in
  match payload |> member key with
  | `Null -> Ok false
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "Invalid params: %s must be a boolean" key)

let decode_cursor_offset = function
  | None -> Ok 0
  | Some raw -> (
      match int_of_string_opt raw with
      | Some offset when offset >= 0 -> Ok offset
      | _ -> Error "Invalid params: cursor must be a non-negative integer string")

let rec drop_list n = function
  | xs when n <= 0 -> xs
  | [] -> []
  | _ :: rest -> drop_list (n - 1) rest

let rec take_list n xs =
  if n <= 0 then
    []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take_list (n - 1) rest

let paginate_json_items ?(page_size = 128) ~field_name items cursor =
  match decode_cursor_offset cursor with
  | Error msg -> Error msg
  | Ok offset ->
      let total = List.length items in
      let page = items |> drop_list offset |> take_list page_size in
      let next_offset = offset + List.length page in
      let fields =
        [ (field_name, `List page) ]
        @
        if next_offset < total then
          [ ("nextCursor", `String (string_of_int next_offset)) ]
        else
          []
      in
      Ok (`Assoc fields)

let cursor_only_params params =
  match params with
  | None -> Ok None
  | Some (`Assoc _ as payload) -> cursor_param payload
  | Some _ -> Error "Invalid params: expected object"

let requested_tool_list_params params =
  let open Yojson.Safe.Util in
  match params with
  | None ->
      Ok {
        names = None;
        include_hidden = false;
        include_deprecated = false;
        include_usage = false;
        mode = None;
        tier = None;
        cursor = None;
      }
  | Some (`Assoc _ as payload) -> (
      let names_result =
        match payload |> member "names" with
        | `Null -> Ok None
        | `List items ->
            items
            |> List.fold_left
                 (fun acc item ->
                   match (acc, item) with
                   | Error _ as err, _ -> err
                   | Ok names, `String value -> Ok (value :: names)
                   | Ok _, _ ->
                       Error "Invalid params: names must be an array of strings")
                 (Ok [])
            |> Result.map (fun names -> Some (List.rev names))
        | _ -> Error "Invalid params: names must be an array of strings"
      in
      let mode_result =
        match payload |> member "mode" with
        | `Null -> Ok None
        | `String s -> Ok (Some s)
        | _ -> Error "Invalid params: mode must be a string"
      in
      let tier_result =
        match payload |> member "tier" with
        | `Null -> Ok None
        | `String s -> (
            match Tool_catalog.tier_of_string (String.lowercase_ascii s) with
            | Some _ -> Ok (Some s)
            | None -> Error "Invalid params: tier must be one of: essential, standard, full")
        | _ -> Error "Invalid params: tier must be a string"
      in
      match names_result with
      | Error _ as err -> err
      | Ok names -> (
          match cursor_param payload with
          | Error _ as err -> err
          | Ok cursor -> (
          match mode_result with
          | Error _ as err -> err
          | Ok mode -> (
          match tier_result with
          | Error _ as err -> err
          | Ok tier -> (
          match bool_param payload "include_hidden" with
          | Error _ as err -> err
          | Ok include_hidden -> (
              match bool_param payload "include_deprecated" with
              | Error _ as err -> err
              | Ok include_deprecated -> (
                  match bool_param payload "include_usage" with
                  | Error _ as err -> err
                  | Ok include_usage ->
                      Ok {
                        names;
                        include_hidden;
                        include_deprecated;
                        include_usage;
                        mode;
                        tier;
                        cursor;
                      })))))))
  | Some _ -> Error "Invalid params: expected object"

let validate_optional_meta payload =
  match Yojson.Safe.Util.member "_meta" payload with
  | `Null
  | `Assoc _ -> Ok ()
  | _ -> Error "Invalid params: _meta must be an object"
let parse_cursor_only_params params =
  let open Yojson.Safe.Util in
  let* fields = strict_assoc_params params in
  let allowed = [ "_meta"; "cursor" ] in
  let unknown =
    fields
    |> List.filter_map (fun (key, _value) ->
           if List.mem key allowed then None else Some key)
  in
  if unknown <> [] then
    Error
      (Printf.sprintf "Invalid params: unsupported field(s): %s"
         (String.concat ", " unknown))
  else
    let payload = `Assoc fields in
    let* () = validate_optional_meta payload in
    match payload |> member "cursor" with
    | `Null -> Ok { cursor = None }
    | `String cursor -> Ok { cursor = Some cursor }
    | _ -> Error "Invalid params: cursor must be a string"

let list_page_size = 128

let encode_cursor ~kind offset =
  Base64.encode_string (Printf.sprintf "%s:%d" kind offset)

let decode_cursor ~kind cursor =
  match Base64.decode cursor with
  | Ok decoded ->
      let prefix = kind ^ ":" in
      let prefix_len = String.length prefix in
      if String.length decoded >= prefix_len
         && String.sub decoded 0 prefix_len = prefix
      then
        int_of_string_opt
          (String.sub decoded prefix_len (String.length decoded - prefix_len))
      else
        None
  | Error _ -> None

let page_items_with_cursor ~kind items cursor =
  let offset =
    match cursor with
    | None -> Ok 0
    | Some encoded -> (
        match decode_cursor ~kind encoded with
        | Some value when value >= 0 -> Ok value
        | _ -> Error "Invalid params: cursor is invalid")
  in
  let rec drop n xs =
    match (n, xs) with
    | 0, rest -> rest
    | _, [] -> []
    | n, _ :: rest -> drop (n - 1) rest
  in
  let rec take n xs =
    match (n, xs) with
    | 0, _ | _, [] -> []
    | n, x :: rest -> x :: take (n - 1) rest
  in
  let count = List.length items in
  let* offset = offset in
  let offset = min offset count in
  let page = items |> drop offset |> take list_page_size in
  let next_offset = offset + List.length page in
  let next_cursor =
    if next_offset < count then Some (encode_cursor ~kind next_offset) else None
  in
  Ok (page, next_cursor)

let handle_initialize_eio ?(profile = Full) id params =
  match validate_initialize_params params with
  | Error msg -> make_error ~id (-32602) msg
  | Ok () ->
      let protocol_version =
        params |> protocol_version_from_params |> normalize_protocol_version
      in
      make_response ~id (`Assoc [
        ("protocolVersion", `String protocol_version);
        ("serverInfo", Mcp_server.server_info);
        ("capabilities", Mcp_server.capabilities);
        ("instructions", `String (match profile with Full -> default_instructions | Operator_remote -> operator_remote_instructions));
      ])

let handle_list_tools_eio ?(profile = Full) ?names ?(include_hidden = false)
    ?(include_deprecated = false) ?(include_usage = false) ?mode ?tier ?cursor
    state id =
  let usage_summary =
    if include_usage then
      Some (Telemetry_eio.summarize_tool_usage ?fs:state.Mcp_server.fs state.Mcp_server.room_config)
    else
      None
  in
  let tier_filter =
    match tier with
    | None -> None
    | Some s -> Tool_catalog.tier_of_string (String.lowercase_ascii s)
  in
  let tools =
    tool_schemas_for_profile ~include_hidden ~include_deprecated
      ?mode_override:mode state profile
    |> (match names with
       | None -> Fun.id
       | Some wanted ->
           List.filter (fun (schema : Types.tool_schema) ->
             List.mem schema.name wanted))
    |> (match tier_filter with
       | None -> Fun.id
       | Some t ->
           List.filter (fun (schema : Types.tool_schema) ->
             Tool_catalog.is_in_tier t schema.name))
    |> List.sort (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
           String.compare a.name b.name)
  in
  match page_items_with_cursor ~kind:"tools" tools cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let result_fields =
        [
          ( "tools",
            `List
              (List.map (tool_json_for_profile ?usage_summary profile) page) );
        ]
        @ maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      let result_fields =
        result_fields
        @
        match usage_summary with
        | Some summary ->
            [
              ("usageTelemetryAvailable", `Bool summary.telemetry_available);
              ("usageTelemetryPath", `String summary.telemetry_path);
              ("usageTotalCalls", `Int summary.total_calls);
            ]
        | None -> []
      in
      make_response ~id (`Assoc result_fields)

let handle_list_resources_eio id cursor =
  let tool_help_resources =
    public_tool_help_schemas ()
    |> List.sort (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
           String.compare a.name b.name)
    |> List.map (fun (schema : Types.tool_schema) ->
           let entry = Tool_help_registry.entry_of_schema schema in
           Mcp_server.make_resource ~uri:("masc://tool-help/" ^ schema.name)
             ~name:(schema.name ^ " Help") ~description:entry.short_description
             ~mime_type:"text/markdown" ())
  in
  let resources =
    Mcp_server.resources @ tool_help_resources
    |> List.sort (fun (a : Mcp_server.mcp_resource) b ->
           String.compare a.uri b.uri)
  in
  match page_items_with_cursor ~kind:"resources" resources cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let resources_json = List.map Mcp_server.resource_to_json page in
      let result_fields =
        [ ("resources", `List resources_json) ]
        @ maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_list_resource_templates_eio id cursor =
  let templates =
    Mcp_server.resource_templates
    |> List.sort (fun (a : Mcp_server.mcp_resource_template) b ->
           String.compare a.uri_template b.uri_template)
  in
  match page_items_with_cursor ~kind:"resourceTemplates" templates cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let templates_json =
        List.map Mcp_server.resource_template_to_json page
      in
      let result_fields =
        [ ("resourceTemplates", `List templates_json) ]
        @ maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_list_prompts_eio id cursor =
  let prompts =
    Mcp_prompt_surface.prompt_defs
    |> List.sort (fun (a : Mcp_prompt_surface.prompt_def)
                       (b : Mcp_prompt_surface.prompt_def) ->
           String.compare a.name b.name)
  in
  match page_items_with_cursor ~kind:"prompts" prompts cursor with
  | Error msg -> make_error ~id (-32602) msg
  | Ok (page, next_cursor) ->
      let prompts_json = List.map Mcp_prompt_surface.prompt_json page in
      let result_fields =
        [ ("prompts", `List prompts_json) ]
        @ maybe_assoc_field "nextCursor"
            (Option.map (fun value -> `String value) next_cursor)
      in
      make_response ~id (`Assoc result_fields)

let handle_get_prompt_eio state id params =
  match params with
  | None -> make_error ~id (-32602) "Missing params"
  | Some (`Assoc _ as payload) -> (
      let open Yojson.Safe.Util in
      match payload |> member "name" with
      | `String name -> (
          let arguments =
            match payload |> member "arguments" with
            | `Assoc _ as args -> args
            | `Null -> `Assoc []
            | _ -> `Assoc []
          in
          match
            Mcp_prompt_surface.get_json ~config:state.Mcp_server.room_config
              ~name ~arguments Config.raw_all_tool_schemas
          with
          | Ok json -> make_response ~id json
          | Error msg -> make_error ~id (-32602) msg)
      | _ -> make_error ~id (-32602) "Invalid params: name must be a string")
  | Some _ -> make_error ~id (-32602) "Invalid params: expected object"

let handle_resources_subscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match (mcp_session_id, params) with
  | None, _ -> make_error ~id (-32600) "resources/subscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) -> (
      match payload |> member "uri" with
      | `String uri ->
          subscribe_resource_for_session ~session_id ~uri;
          make_response ~id (`Assoc [])
      | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"

let handle_resources_unsubscribe_eio id ?mcp_session_id params =
  let open Yojson.Safe.Util in
  match (mcp_session_id, params) with
  | None, _ ->
      make_error ~id (-32600) "resources/unsubscribe requires an MCP session"
  | Some session_id, Some (`Assoc _ as payload) -> (
      match payload |> member "uri" with
      | `String uri ->
          unsubscribe_resource_for_session ~session_id ~uri;
          make_response ~id (`Assoc [])
      | _ -> make_error ~id (-32602) "Invalid params: uri must be a string")
  | Some _, None -> make_error ~id (-32602) "Missing params"
  | Some _, Some _ -> make_error ~id (-32602) "Invalid params: expected object"

(** Handle incoming JSON-RPC request - Pure Eio Native

    Direct-style async using OCaml 5.x Effect Handlers.
    Uses execute_tool_eio for tool calls.
    mcp_session_id: HTTP MCP session ID for agent_name persistence
*)
let handle_request
    ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t)
    ~sw
    ?(profile = Full)
    ?mcp_session_id
    ?auth_token
    state
    request_str =
  try
    let json =
      try Ok (Yojson.Safe.from_string request_str)
      with exn -> Error (Printexc.to_string exn)
    in
    match json with
    | Error msg ->
        make_error ~id:`Null ~data:(`String msg) (-32700) "Parse error"
    | Ok json ->
        if
          match json with
          | `List _ -> true
          | _ -> false
        then
          make_error ~id:`Null (-32600)
            "JSON-RPC batch requests are not supported on this MCP endpoint"
        else if is_jsonrpc_response json then
          `Null
        else if not (is_jsonrpc_v2 json) then
          make_error ~id:`Null (-32600) "Invalid Request: jsonrpc must be 2.0"
        else
        match jsonrpc_request_of_yojson json with
        | Error msg -> make_error ~id:`Null ~data:(`String msg) (-32600) "Invalid Request"
        | Ok req ->
            let id = get_id req in
            if not (is_valid_request_id id) then
              make_error ~id:`Null (-32600) "Invalid Request: id must be string, number, or null"
            else if is_notification req then
              `Null
            else
                (try
                   (match req.method_ with
                   | "initialize" -> handle_initialize_eio ~profile id req.params
                   | "initialized"
                   | "notifications/initialized" -> make_response ~id `Null
                   | "resources/list" -> (
                       match parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } -> handle_list_resources_eio id cursor)
                   | "resources/read" ->
                       (* Eio native - pure sync resource reading *)
                       handle_read_resource_eio state id req.params
                   | "resources/templates/list" -> (
                       match parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } ->
                           handle_list_resource_templates_eio id cursor)
                   | "resources/subscribe" ->
                       handle_resources_subscribe_eio id ?mcp_session_id req.params
                   | "resources/unsubscribe" ->
                       handle_resources_unsubscribe_eio id ?mcp_session_id req.params
                   | "prompts/list" -> (
                       match parse_cursor_only_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { cursor } -> handle_list_prompts_eio id cursor)
                   | "prompts/get" -> handle_get_prompt_eio state id req.params
                   | "tools/list" -> (
                       match requested_tool_list_params req.params with
                       | Error msg -> make_error ~id (-32602) msg
                       | Ok { names; include_hidden; include_deprecated; include_usage; mode; tier; cursor } ->
                           handle_list_tools_eio ~profile ?names ~include_hidden
                             ~include_deprecated ~include_usage ?mode ?tier ?cursor
                             state id)
                   | "tools/call" ->
                       (match req.params with
                       | Some params ->
                           (try
                             let name = Yojson.Safe.Util.(params |> member "name" |> to_string) in
                             if not (tool_allowed_in_profile profile name) then
                               make_error ~id (-32601)
                                 (Printf.sprintf
                                    "Tool '%s' is not available on this MCP endpoint."
                                    name)
                             else (
                               Printf.eprintf "[MCP] tools/call: %s (id=%s, session=%s)\n%!" name
                                 (match id with `Int i -> string_of_int i | `String s -> s | _ -> "?")
                                 (match mcp_session_id with Some s -> s | None -> "none");
                               let result =
                                 handle_call_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state id params
                               in
                               Printf.eprintf "[MCP] tools/call done: %s\n%!" name;
                               result)
                           with Yojson.Safe.Util.Type_error (_, _) ->
                             make_error ~id (-32602) "Invalid params: name must be a string")
                       | None -> make_error ~id (-32602) "Missing params")
                   | method_ -> make_error ~id (-32601) ("Method not found: " ^ method_))
                 with
                 | Invalid_argument msg
                   when contains_casefold msg "invalid_argument(\"masc not initialized" ->
                     make_error ~id (-32603) (Types.masc_error_to_string Types.NotInitialized)
                   | exn ->
                       let err = Printexc.to_string exn in
                       Log.Mcp.error "Request handling failed: %s" err;
                       make_error ~id (-32603) (Printf.sprintf "Internal error: %s" err))
  with exn ->
    make_error ~id:`Null ~data:(`String (Printexc.to_string exn)) (-32603) "Internal error"

(** {1 Server Entry Points} *)

(** Run MCP server in stdio mode with Eio

    Supports both:
    - Framed mode (Content-Length header) - standard MCP
    - Line-delimited mode - for simple testing
*)
let run_stdio ~sw ~env state =
  let stdin = Eio.Stdenv.stdin env in
  let stdout = Eio.Stdenv.stdout env in
  let clock = Eio.Stdenv.clock env in

  Log.Mcp.info "MASC MCP Server (Eio stdio mode)";
  Log.Mcp.info "Default room: %s" Mcp_server.(state.room_config.Room.base_path);

  (* Buffer for reading - framed mode (Content-Length) only for now *)
  let buf = Eio.Buf_read.of_flow stdin ~max_size:(16 * 1024 * 1024) in

  Log.Mcp.debug "Transport mode: framed (Content-Length)";

  (* Main loop - framed mode only *)
  let rec loop () =
    match read_framed_message buf with
    | None ->
        Log.Mcp.info "EOF received, shutting down";
        ()
    | Some "" ->
        (* Empty body, skip *)
        loop ()
    | Some request_str ->
        (* Handle request with Eio clock - use "stdio" as session ID for agent persistence *)
        let response = handle_request ~clock ~sw ~mcp_session_id:"stdio" state request_str in

        (* Write response if not null *)
        (match response with
         | `Null -> ()
         | json -> write_framed_message stdout json);

        loop ()
  in

  try loop ()
  with
  | End_of_file ->
      Log.Mcp.info "Connection closed"
  | exn ->
      Log.Mcp.error "Server error: %s" (Printexc.to_string exn)
