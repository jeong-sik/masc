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

(** {1 Network Context for LLM Chain Calls} *)

(** Type alias for generic Eio network capability *)
type eio_net = [`Generic] Eio.Net.ty Eio.Resource.t

(** Global Eio network reference for Walph chain execution.
    Set by main_eio.ml during server initialization.
    Used by walph_loop for direct LLM API calls.

    Initialization order is enforced:
    - set_net MUST be called before any get_net usage
    - Callers should use get_net_opt for graceful degradation *)
let current_net : eio_net option ref = ref None
let net_initialized : bool ref = ref false

(** Eio clock reference for async sleep *)
let current_clock : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None

(** Set the Eio network reference. Called from main_eio.ml. *)
let set_net net =
  current_net := Some (net :> eio_net);
  net_initialized := true

(** Set the Eio clock reference. Called from main_eio.ml. *)
let set_clock clock = current_clock := Some clock

(** Get the Eio clock reference optionally. *)
let get_clock_opt () = !current_clock

(** Get the Eio clock reference. Raises if not set. *)
let get_clock () =
  match !current_clock with
  | Some clock -> clock
  | None -> invalid_arg "Eio clock not initialized"

(** Get the Eio network reference optionally - for graceful handling *)
let get_net_opt () : eio_net option = !current_net

(** Get the Eio network reference. Raises if not set.
    @raise Failure if set_net was not called *)
let get_net () : eio_net =
  match !current_net with
  | Some net -> net
  | None ->
    if !net_initialized then
      invalid_arg "Eio net was set but is now None (unexpected state)"
    else
      invalid_arg "Eio net not initialized - ensure set_net is called during server startup"

(** Re-export pure functions from Mcp_server *)
let create_state ?test_mode:_ ~base_path () =
  (* test_mode is ignored - Mcp_server.create_state doesn't support it *)
  Mcp_server.create_state ~base_path

(** Create state with Eio context - required for PostgresNative backend *)
let create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~base_path =
  Mcp_server.create_state_eio ~sw ~env ~proc_mgr ~fs ~clock ~base_path

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
        | None -> make_error ~id (-32602) ("Unknown resource: " ^ uri_str)
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

type audit_event = {
  timestamp: float;
  agent: string;
  event_type: string;
  success: bool;
  detail: string option;
}

let audit_log_path (config : Room.config) =
  Filename.concat (Room_utils.masc_dir config) "audit.log"

let audit_event_to_json (e : audit_event) : Yojson.Safe.t =
  `Assoc [
    ("timestamp", `Float e.timestamp);
    ("agent", `String e.agent);
    ("event_type", `String e.event_type);
    ("success", `Bool e.success);
    ("detail", match e.detail with Some d -> `String d | None -> `Null);
  ]

let append_audit_event (config : Room.config) (e : audit_event) =
  let g = load_governance config in
  if g.audit_enabled then begin
    ensure_masc_dir config;
    let path = audit_log_path config in
    let line = Yojson.Safe.to_string (audit_event_to_json e) ^ "\n" in
    Room_utils.with_file_lock config path (fun () ->
      let oc = open_out_gen [Open_creat; Open_append; Open_wronly] 0o600 path in
      Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer" ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc line)
    )
  end

let read_audit_events (config : Room.config) ~since : audit_event list =
  let path = audit_log_path config in
  if not (Sys.file_exists path) then []
  else
    let content = In_channel.with_open_text path In_channel.input_all in
    let lines = String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "") in
    List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        let module U = Yojson.Safe.Util in
        let timestamp = match Json_util.get_float json "timestamp" with Some v -> v | None -> raise Not_found in
        if timestamp < since then None
        else
          let agent = match Json_util.get_string json "agent" with Some v -> v | None -> raise Not_found in
          let event_type = match Json_util.get_string json "event_type" with Some v -> v | None -> raise Not_found in
          let success = match Json_util.get_bool json "success" with Some v -> v | None -> raise Not_found in
          let detail = Json_util.get_string json "detail" in
          Some { timestamp; agent; event_type; success; detail }
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
    ) lines

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
(* Drift Guard: similarity helpers              *)
(* ============================================ *)

let tokenize (s : string) : string list =
  let trimmed = String.trim s in
  if trimmed = "" then []
  else
    let tokens = Str.split (Str.regexp "[ \t\r\n]+") trimmed in
    let trim_punct token =
      let is_punct = function
        | '.' | ',' | ';' | ':' | '!' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '"' | '\'' | '`' | '-' | '_' | '/' | '\\' -> true
        | _ -> false
      in
      let len = String.length token in
      if len = 0 then token
      else
        let rec left i =
          if i >= len then len
          else if is_punct token.[i] then left (i + 1) else i
        in
        let rec right i =
          if i < 0 then -1
          else if is_punct token.[i] then right (i - 1) else i
        in
        let l = left 0 in
        let r = right (len - 1) in
        if r < l then "" else String.sub token l (r - l + 1)
    in
    tokens
    |> List.map String.lowercase_ascii
    |> List.map trim_punct
    |> List.filter (fun t -> t <> "")

let jaccard_similarity a b =
  let set_a = Hashtbl.create 128 in
  let set_b = Hashtbl.create 128 in
  List.iter (fun t -> Hashtbl.replace set_a t ()) a;
  List.iter (fun t -> Hashtbl.replace set_b t ()) b;
  let intersection = Hashtbl.fold (fun k _ acc -> if Hashtbl.mem set_b k then acc + 1 else acc) set_a 0 in
  let union = (Hashtbl.length set_a) + (Hashtbl.length set_b) - intersection in
  if union = 0 then 1.0 else float_of_int intersection /. float_of_int union

let cosine_similarity a b =
  let freq tbl t =
    let v = match Hashtbl.find_opt tbl t with Some n -> n | None -> 0 in
    Hashtbl.replace tbl t (v + 1)
  in
  let fa = Hashtbl.create 128 in
  let fb = Hashtbl.create 128 in
  List.iter (freq fa) a;
  List.iter (freq fb) b;
  let dot = Hashtbl.fold (fun k va acc ->
    match Hashtbl.find_opt fb k with
    | Some vb -> acc +. (float_of_int (va * vb))
    | None -> acc
  ) fa 0.0 in
  let norm tbl =
    Hashtbl.fold (fun _ v acc -> acc +. (float_of_int (v * v))) tbl 0.0 |> sqrt
  in
  let na = norm fa in
  let nb = norm fb in
  if na = 0.0 || nb = 0.0 then 0.0 else dot /. (na *. nb)

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
   "masc_goal_list"]

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
  let agent_name =
    (* Priority: explicit arg > identity > legacy file-based *)
    if raw_agent_name <> "" && raw_agent_name <> "unknown" then
      raw_agent_name
    else if identity.Agent_identity.agent_name <> "" then
      identity.Agent_identity.agent_name
    else
      (* Legacy fallback for edge cases *)
      match read_mcp_session_agent () with
      | Some name -> name
      | None ->
          let term_session_id = try Sys.getenv "TERM_SESSION_ID" with Not_found -> "" in
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
            Printf.sprintf "agent-%s" (String.sub identity.session_key 0 8))
  in

  let token =
    match arg_get_string_opt "token" with
    | Some t -> Some t
    | None -> auth_token
  in

  let read_term_session_agent () =
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
    | None -> read_term_session_agent ()
  in

  (* If the client keeps sending a legacy agent type (e.g. "claude") but we've
     already joined and have a generated nickname, prefer the nickname. This
     avoids repeated auto-joins and makes join-required tools "just work". *)
  let agent_name =
    match persisted_agent_name () with
    | Some persisted
      when Nickname.is_generated_nickname persisted
           && not (Nickname.is_generated_nickname agent_name) ->
        persisted
    | _ -> agent_name
  in

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

  (* Tools that require agent to be joined first *)
  let requires_join = [
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
  ] in

  (* Auto-init/auto-join for better UX.
     - Auto-init only when auth is disabled (avoid side effects in secured rooms).
     - Auto-join when allowed by auth (and safe for token-based auth). *)
  let join_required = List.mem name requires_join in

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

  let is_read_only = List.mem name read_only_tools in

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
    let skip_heartbeat = is_read_only || String.equal name "masc_archive_save" in
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
  let swarm_ctx : Tool_swarm.context = {
    config;
    fs = state.Mcp_server.fs;
    agent_name;
  } in
  let simple_ctx_config = { Tool_plan.config } in
  let simple_ctx_run = { Tool_run.config } in
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
  let simple_ctx_walph = lazy ({ config; agent_name; net = get_net (); clock } : _ Tool_walph.context) in
  let simple_ctx_agent : Tool_agent.context = { config; agent_name } in
  let simple_ctx_task : Tool_task.context = { config; agent_name } in
  let simple_ctx_room : Tool_room.context = { config; agent_name } in
  let simple_ctx_control : Tool_control.context = { config; agent_name } in
  let simple_ctx_misc : Tool_misc.context = { config; agent_name } in
  let simple_ctx_suspend : Tool_suspend.context = { config; caller_agent = Some agent_name } in
  let simple_ctx_library : Tool_library.context = { agent_name } in
  let simple_ctx_perpetual : Tool_perpetual.context = {
    agent_name;
    start_loop = Some (fun loop_state loop_config ->
      Eio.Fiber.fork ~sw (fun () ->
        try
          Perpetual_loop.run ~config:loop_config ~state:loop_state
        with exn ->
          Printf.eprintf "[perpetual:error] loop crashed for %s: %s\n%!"
            loop_state.Perpetual_loop.trace_id (Printexc.to_string exn)));
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
          ("ollama_timeout_sec", `Float timeout_sec);
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
    let net = get_net () in
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

  (* Chain through all extracted tool modules *)
  match Tool_swarm.dispatch swarm_ctx ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_plan.dispatch simple_ctx_config ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_run.dispatch simple_ctx_run ~name ~args:arguments with
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
  match Tool_walph.dispatch (Lazy.force simple_ctx_walph) ~name ~args:arguments with
  | Some result -> result
  | None ->
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
          Filename.concat (Sys.getenv "HOME") (String.sub path 1 (String.length path - 1))
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
      let term_session_id = try Sys.getenv "TERM_SESSION_ID" with Not_found -> "default" in
      let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
      (try
        let oc = open_out agent_file in
        Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
          ~finally:(fun () -> close_out_noerr oc)
          (fun () -> output_string oc nickname)
      with e ->
        Printf.eprintf "[WARN] Failed to write agent file %s: %s\n%!" agent_file (Printexc.to_string e));
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
      let session_id = try Sys.getenv "TERM_SESSION_ID" with Not_found -> "default" in
      let agent_file = Printf.sprintf "/tmp/.masc_agent_%s" session_id in
      Safe_ops.remove_file_logged ~context:"masc_leave" agent_file;
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
             Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds ()
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





















  | "masc_verify_handoff" ->
      let original = arg_get_string "original" "" in
      let received = arg_get_string "received" "" in
      let threshold = arg_get_float "threshold" (Level2_config.Drift_guard.default_threshold ()) in
      let tokens_a = tokenize original in
      let tokens_b = tokenize received in
      let jacc = jaccard_similarity tokens_a tokens_b in
      let cos = cosine_similarity tokens_a tokens_b in
      let weights = Level2_config.Drift_guard.weights () in
      let combined = (weights.jaccard *. jacc)
                     +. (weights.cosine *. cos) in
      let passed = combined >= threshold in
      let json = `Assoc [
        ("similarity", `Float combined);
        ("jaccard", `Float jacc);
        ("cosine", `Float cos);
        ("threshold", `Float threshold);
        ("passed", `Bool passed);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
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
      let module U = Yojson.Safe.Util in
      let working_dir = match arguments |> U.member "working_dir" with
        | `String s when s <> "" -> Some s
        | _ -> None
      in
      (match state.Mcp_server.proc_mgr with
       | Some pm ->
           let result = Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:spawn_agent_name ~prompt ~timeout_seconds ?working_dir () in
           (result.Spawn_eio.success, Spawn_eio.result_to_human_string result)
       | None ->
           (false, "❌ Process manager not available in this environment"))

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
                let result = Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name:target_agent ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds () in
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
          with _ -> (0, None))
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
           (true, Yojson.Safe.pretty_to_string response))

  (* Swarm tools delegated to Tool_swarm module *)

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
  | "masc_board_list" | "masc_board_get"
  | "masc_board_comment" | "masc_board_vote" | "masc_board_stats"
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
      let net = get_net () in
      Tool_lodge.handle_tool ~net name arguments

  (* ============================================ *)
  (* Conversation Tools - Persistent Agent Dialogue *)
  (* ============================================ *)

  | "masc_convo_start" ->
      let topic = arg_get_string "topic" "" in
      let initiator = arg_get_string "initiator" agent_name in
      let initial_content = arg_get_string "initial_content" "" in
      let max_turns = arg_get_int "max_turns" 50 in
      let source_post_id = arg_get_string_opt "post_id" in
      if topic = "" then (false, "❌ topic required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = "default";
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
      if thread_id = "" || content = "" then
        (false, "❌ thread_id and content required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = "default";
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
      if thread_id = "" || conclusion = "" then
        (false, "❌ thread_id and conclusion required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = "default";
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
      if thread_id = "" then (false, "❌ thread_id required")
      else begin
        let convo_config : Council.Conversation.config = {
          base_path = config.base_path;
          room = "default";
        } in
        match Council.Conversation.get ~config:convo_config ~thread_id with
        | Some thread ->
            let json = Council.Conversation.thread_to_yojson thread in
            (true, Yojson.Safe.pretty_to_string json)
        | None -> (false, Printf.sprintf "❌ Thread not found: %s" thread_id)
      end

  | "masc_convo_list" ->
      let convo_config : Council.Conversation.config = {
        base_path = config.base_path;
        room = "default";
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
        with _ -> default
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
       with _ -> 2)
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

(** Eio-native handler for tools/call - uses execute_tool_eio directly *)
let handle_call_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state id params =
  let module U = Yojson.Safe.Util in
  let name = params |> U.member "name" |> U.to_string in
  let arguments = params |> U.member "arguments" in
  let is_read_only = List.mem name read_only_tools in

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
  let audit_detail =
    Printf.sprintf
      "%s|timeout=%d|duration_ms=%d"
      name
      (if !timeout_hit then 1 else 0)
      duration_ms
  in
  append_audit_event state.Mcp_server.room_config {
    timestamp = Time_compat.now ();
    agent = agent_name;
    event_type = "tool_call";
    success;
    detail = Some audit_detail;
  };

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
  let result = make_response ~id (`Assoc [
    ("resultEnvelope", envelope);
    ("content", `List [
      `Assoc [
        ("type", `String "text");
        ("text", `String message);
      ]
    ]);
    ("isError", `Bool (not success));
  ]) in

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
let handle_initialize_eio id params =
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
        ("instructions", `String "MASC (Multi-Agent Streaming Coordination) enables AI agent collaboration. \
          ROOM: Agents sharing the same base path (.masc/ folder) or PostgreSQL cluster coordinate together. \
          CLUSTER: Set MASC_CLUSTER_NAME for multi-machine coordination (defaults to basename of ME_ROOT). \
          READ: use resources/list + resources/read (status/tasks/agents/events/schema) for snapshots. \
          WRITE: prefer masc_transition (claim/start/done/cancel/release) with expected_version for CAS. \
          WORKFLOW: masc_status → masc_transition(claim) → masc_worktree_create (isolation) → work → masc_transition(done). \
          Use masc_heartbeat periodically; use @agent mentions in masc_broadcast. \
          Prefer worktrees for parallel work.");
      ])

let handle_list_tools_eio state id =
  let room_path = Room.masc_dir state.Mcp_server.room_config in
  let config = Config.load room_path in
  let enabled_categories = config.enabled_categories in
  let all_tools =
    Tools.all_schemas
    @ Tool_board.tools
    @ Tool_lodge.tools
    @ Tool_perpetual.schemas
    @ Tool_keeper.schemas
    @ Tool_goals.schemas
    @ Tool_protocol_game_view.schemas
  in
  let filtered_schemas = List.filter (fun (schema : Types.tool_schema) ->
    Mode.is_tool_enabled enabled_categories schema.name
  ) all_tools in
  let tools = List.map (fun (schema : Types.tool_schema) ->
    `Assoc [
      ("name", `String schema.name);
      ("description", `String schema.description);
      ("inputSchema", schema.input_schema);
    ]
  ) filtered_schemas in
  make_response ~id (`Assoc [("tools", `List tools)])

let handle_list_resources_eio id =
  let resources_json = List.map Mcp_server.resource_to_json Mcp_server.resources in
  make_response ~id (`Assoc [("resources", `List resources_json)])

let handle_list_resource_templates_eio id =
  let templates_json = List.map Mcp_server.resource_template_to_json Mcp_server.resource_templates in
  make_response ~id (`Assoc [("resourceTemplates", `List templates_json)])

let handle_list_prompts_eio id =
  make_response ~id (`Assoc [("prompts", `List [])])

(** Handle incoming JSON-RPC request - Pure Eio Native

    Direct-style async using OCaml 5.x Effect Handlers.
    Uses execute_tool_eio for tool calls.
    mcp_session_id: HTTP MCP session ID for agent_name persistence
*)
let handle_request ~clock ~sw ?mcp_session_id ?auth_token state request_str =
  try
    let json =
      try Ok (Yojson.Safe.from_string request_str)
      with exn -> Error (Printexc.to_string exn)
    in
    match json with
    | Error msg ->
        make_error ~id:`Null ~data:(`String msg) (-32700) "Parse error"
    | Ok json ->
        if is_jsonrpc_response json then
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
                   | "initialize" -> handle_initialize_eio id req.params
                   | "initialized"
                   | "notifications/initialized" -> make_response ~id `Null
                   | "resources/list" -> handle_list_resources_eio id
                   | "resources/read" ->
                       (* Eio native - pure sync resource reading *)
                       handle_read_resource_eio state id req.params
                   | "resources/templates/list" -> handle_list_resource_templates_eio id
                   | "prompts/list" -> handle_list_prompts_eio id
                   | "tools/list" -> handle_list_tools_eio state id
                   | "tools/call" ->
                       (match req.params with
                       | Some params ->
                           (try
                             let name = Yojson.Safe.Util.(params |> member "name" |> to_string) in
                             Printf.eprintf "[MCP] tools/call: %s (id=%s, session=%s)\n%!" name
                               (match id with `Int i -> string_of_int i | `String s -> s | _ -> "?")
                               (match mcp_session_id with Some s -> s | None -> "none");
                             let result =
                               handle_call_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state id params
                             in
                             Printf.eprintf "[MCP] tools/call done: %s\n%!" name;
                             result
                           with _ ->
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
