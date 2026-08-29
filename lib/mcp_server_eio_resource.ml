(** Mcp_server_eio_resource — Resource reading handler

    Extracted from mcp_server_eio.ml.
    Handles resources/read JSON-RPC method for MASC resources.
*)

(* The library resource ids. The topic form carries the separator so a name
   like [libraryfoo] is not read as the topic [oo]. *)
let library_index_id = "library"
let library_index_json_id = "library.json"
let library_topic_prefix = "library/"

let make_response = Mcp_transport_protocol.make_response
let make_error = Mcp_transport_protocol.make_error

(* Typed wrapper.  The bare [-32602] literal at three call sites was a
   "Magic Number repetition" anti-pattern (sw-dev §"Magic Number 금지")
   that bypassed the existing [Mcp_error_code.t] typed sum.  Mirrors
   the [make_error_typed] helper already used in
   [mcp_server_eio_protocol.ml]; routes the typed variant through
   [to_wire_code] so the JSON-RPC envelope stays unchanged. *)
let make_error_typed ?data ~id (code : Mcp_error_code.t) message =
  make_error ?data ~id (Mcp_error_code.to_wire_code code) message

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

(* Resource projections use the synchronous Workspace/Fs_compat APIs.  Keep
   those reads off the cooperative Eio domain; Session actor access remains on
   the calling fiber because it may yield through the registry mailbox. *)
let run_blocking_resource_io f = Eio_unix.run_in_systhread f

module For_testing = struct
  let blocking_io_execution_context () =
    run_blocking_resource_io Eio_guard.execution_context
end

let handle_read_resource_eio state id params =
  match params with
  | None -> make_error_typed ~id Mcp_error_code.Invalid_params "Missing params"
  | Some (`Assoc _ as p) ->
      let uri_str = Safe_ops.json_string "uri" p in
      if uri_str = "" then
        make_error_typed ~id Mcp_error_code.Invalid_params "Missing uri"
      else begin
        let resource_id, uri = Mcp_server.parse_masc_resource_uri uri_str in
        let config = (Mcp_server.workspace_config state) in
        let registry = state.Mcp_server.session_registry in

        let read_messages_json ~since_seq ~limit =
          run_blocking_resource_io (fun () ->
            let msgs_path = Workspace.messages_dir config in
            if Sys.file_exists msgs_path then
              let extract_seq name =
                match String.index_opt name '_' with
                | None -> 0
                | Some idx ->
                  Safe_ops.int_of_string_with_default
                    ~default:0
                    (String.sub name 0 idx)
              in
              let files =
                Sys.readdir msgs_path
                |> Array.to_list
                |> List.sort (fun a b -> compare (extract_seq b) (extract_seq a))
              in
              let count = ref 0 in
              let msgs = ref [] in
              List.iter
                (fun name ->
                   if !count < limit
                   then (
                     let path = Filename.concat msgs_path name in
                     let json = Workspace.read_json config path in
                     match Masc_domain.message_of_yojson json with
                     | Ok msg when msg.Masc_domain.seq > since_seq ->
                       msgs := Masc_domain.message_to_yojson msg :: !msgs;
                       incr count
                     | Ok _ -> ()
                     | Error detail ->
                       Log.legacy_traceln
                         ~level:Log.Warn
                         ~module_name:"MCP"
                         (Printf.sprintf
                            "[WARN] Failed to decode message resource %s: %s"
                            path
                            detail)))
                files;
              `List (List.rev !msgs)
            else `List [])
        in

        let read_events_json ~limit =
          run_blocking_resource_io (fun () ->
            let lines = Mcp_server.read_event_lines config ~limit in
            let events =
              List.filter_map
                (fun line ->
                   match Yojson.Safe.from_string line with
                   | json -> Some json
                   | exception Yojson.Json_error msg ->
                     let preview =
                       String_util.utf8_safe ~max_bytes:53 ~suffix:"..." line
                       |> String_util.to_string
                     in
                     Log.legacy_traceln
                       ~level:Log.Warn
                       ~module_name:"MCP"
                       (Printf.sprintf
                          "[WARN] Failed to parse event JSON: %s (line: %s)"
                          msg
                          preview);
                     None)
                lines
            in
            `List events)
        in

        let read_events_markdown ~limit =
          run_blocking_resource_io (fun () ->
            let lines = Mcp_server.read_event_lines config ~limit in
            if lines = []
            then "(no events)"
            else String.concat "\n" (List.map (fun line -> "- " ^ line) lines))
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
          | "status" ->
              ( "text/markdown"
              , Some (run_blocking_resource_io (fun () -> Workspace.status config)) )
          | "status.json" ->
              let state_json, backlog_json =
                run_blocking_resource_io (fun () ->
                  ( Masc_domain.workspace_state_to_yojson (Workspace.read_state config)
                  , Masc_domain.backlog_to_yojson (Workspace.read_backlog config) ))
              in
              let connected_agents = Session.get_agent_statuses registry in
              let json = `Assoc [
                ("base_path", `String config.base_path);
                ("state", state_json);
                ("backlog", backlog_json);
                ("connected_agents", `List connected_agents);
              ] in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "tasks" ->
              ( "text/markdown"
              , Some (run_blocking_resource_io (fun () -> Workspace.list_tasks config)) )
          | "tasks.json" ->
              let backlog_json =
                run_blocking_resource_io (fun () ->
                  Masc_domain.backlog_to_yojson (Workspace.read_backlog config))
              in
              ("application/json", Some (Yojson.Safe.pretty_to_string backlog_json))
          | "who" -> ("text/markdown", Some (Session.status_string registry))
          | "who.json" ->
              let statuses = Session.get_agent_statuses registry in
              ("application/json", Some (Yojson.Safe.pretty_to_string (`List statuses)))
          | "agents" ->
              let statuses = Session.get_agent_statuses registry in
              let body =
                if statuses = [] then "No active agents."
                else Session.status_string registry
              in
              ("text/markdown", Some body)
          | "agents.json" ->
              let statuses = Session.get_agent_statuses registry in
              let json =
                `Assoc
                  [
                    ("replacement", `String "masc://who.json");
                    ("agents", `List statuses);
                  ]
              in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "messages" | "messages/recent" ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              ( "text/markdown"
              , Some
                  (run_blocking_resource_io (fun () ->
                     Workspace.get_messages config ~since_seq ~limit)) )
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
          | "worktrees.json" ->
              let worktrees_dir = Filename.concat config.base_path ".worktrees" in
              let entries =
                run_blocking_resource_io (fun () ->
                  if Sys.file_exists worktrees_dir && Sys.is_directory worktrees_dir
                  then
                    Sys.readdir worktrees_dir
                    |> Array.to_list
                    |> List.sort String.compare
                    |> List.map (fun name ->
                      `Assoc
                        [ "name", `String name
                        ; "path", `String (Filename.concat worktrees_dir name)
                        ])
                  else [])
              in
              let json =
                `Assoc
                  [ "base_path", `String config.base_path
                  ; "worktrees", `List entries
                  ]
              in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | s
            when s = library_index_id
                 || s = library_index_json_id
                 || String.starts_with s ~prefix:library_topic_prefix ->
              run_blocking_resource_io (fun () ->
                let library_dir = Filename.concat config.base_path "docs/library" in
                if not (Sys.file_exists library_dir)
                then
                  ( "text/markdown"
                  , Some "Library directory not found. Create docs/library/ first." )
                else begin
                let parse_frontmatter path fallback_name =
                  try
                    let parsed = Frontmatter.parse (Fs_compat.load_file path) in
                    if parsed.Frontmatter.fields = []
                       && not (Frontmatter.has_frontmatter (Fs_compat.load_file path))
                    then fallback_name, "", "", "", []
                    else (
                      let field name = Frontmatter.field parsed name in
                      let title =
                        match field "title" with
                        | "" -> fallback_name
                        | value -> value
                      in
                      ( title
                      , field "source"
                      , field "verified_by"
                      , field "date"
                      , Frontmatter.list_field parsed "tags" ))
                  with
                  | Sys_error _ -> fallback_name, "", "", "", []
                in
                (* Trimmed here, not in the parser. The three readers this
                   replaced disagreed: prompt_registry kept the body verbatim
                   and this one trimmed it. Frontmatter.parse follows the
                   verbatim reading -- it returns what the file says -- so the
                   surface that wants a tidy body asks for it. Without the
                   trim, a file ending in a newline renders as "Alpha body\n"
                   in the JSON resource. *)
                let strip_frontmatter content =
                  String.trim (Frontmatter.parse content).Frontmatter.body
                in
                let is_json, topic =
                  if s = library_index_json_id then (true, "")
                  else if s = library_index_id then (false, "")
                  else
                    (* Past the prefix, not past a hardcoded 8: the guard above
                       matched [library_topic_prefix], and the two lengths have
                       to be the same number. *)
                    let prefix_len = String.length library_topic_prefix in
                    let rest =
                      String.sub s prefix_len (String.length s - prefix_len)
                    in
                    if Filename.check_suffix rest ".json" then
                      (true, Filename.chop_suffix rest ".json")
                    else (false, rest)
                in
                let library_files () =
                  Sys.readdir library_dir |> Array.to_list
                    |> List.filter (fun f -> Filename.check_suffix f ".md" && f <> "README.md")
                    |> List.sort String.compare
                in
                (* [topic] arrives from the client's URI. Resolving it against
                   the listing rather than concatenating it onto [library_dir]
                   means a topic like [../../secrets] has nothing to match:
                   readdir never returns a name with a separator in it. *)
                let library_doc_path topic =
                  let want = topic ^ ".md" in
                  if List.exists (String.equal want) (library_files ()) then
                    Some (Filename.concat library_dir want)
                  else None
                in
                if topic = "" && not is_json then begin
                  let files = library_files () in
                  let entries = List.map (fun f ->
                    let name = Filename.chop_suffix f ".md" in
                    let path = Filename.concat library_dir f in
                    let (title, source, _verified, _date, tags) = parse_frontmatter path name in
                    let tag_str = if tags = [] then ""
                      else " -- " ^ String.concat ", " (List.map (fun t -> "`" ^ t ^ "`") tags) in
                    let src_str = if source = "" then "" else " ([source](" ^ source ^ "))" in
                    Printf.sprintf "- **%s** -- `masc://library/%s`%s%s" title name src_str tag_str
                  ) files in
                  let body = if entries = [] then "Library is empty."
                    else "# Library Index\n\n" ^ String.concat "\n" entries ^ "\n"
                  in
                  ("text/markdown", Some body)
                end else if topic = "" && is_json then begin
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
                  match library_doc_path topic with
                  | Some path -> begin
                    let raw = Fs_compat.load_file path in
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
                  end
                  | None ->
                    ("application/json", Some (Yojson.Safe.to_string (`Assoc [("error", `String (Printf.sprintf "Library document '%s' not found" topic))])))
                end else begin
                  match library_doc_path topic with
                  | Some path ->
                    let content = Fs_compat.load_file path in
                    ("text/markdown", Some content)
                  | None ->
                    ("text/markdown", Some (Printf.sprintf "Library document '%s' not found." topic))
                end
              end)
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
            make_response ~id
              (`Assoc
                ([ ("contents", contents) ]
                @ Mcp_server.(cache_hint_fields live_state_cache_hint)))
      end
  | Some _ ->
      make_error_typed ~id Mcp_error_code.Invalid_params "Invalid params"
