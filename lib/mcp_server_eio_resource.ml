(** Mcp_server_eio_resource — Resource reading handler

    Extracted from mcp_server_eio.ml.
    Handles resources/read JSON-RPC method for MASC resources.
*)

let make_response = Mcp_transport_protocol.make_response
let make_error = Mcp_transport_protocol.make_error

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

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
          let msgs_path = Coord.messages_dir config in
          if Sys.file_exists msgs_path then
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
                let json = Coord.read_json config path in
                match Types.message_of_yojson json with
                | Ok msg when msg.Types.seq > since_seq ->
                    msgs := (Types.message_to_yojson msg) :: !msgs;
                    incr count
                | Ok _ | Error _ -> ()
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
                let preview = String_util.utf8_safe ~max_bytes:53 ~suffix:"..." line |> String_util.to_string in
                Log.legacy_traceln ~level:Log.Warn ~module_name:"MCP"
                  (Printf.sprintf
                     "[WARN] Failed to parse event JSON: %s (line: %s)" msg
                     preview);
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
          | "status" -> ("text/markdown", Some (Coord.status config))
          | "status.json" ->
              let state_json = Types.room_state_to_yojson (Coord.read_state config) in
              let backlog_json = Types.backlog_to_yojson (Coord.read_backlog config) in
              let connected_agents = Session.get_agent_statuses registry in
              let json = `Assoc [
                ("base_path", `String config.base_path);
                ("state", state_json);
                ("backlog", backlog_json);
                ("connected_agents", `List connected_agents);
              ] in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "tasks" -> ("text/markdown", Some (Coord.list_tasks config))
          | "tasks.json" ->
              let backlog_json = Types.backlog_to_yojson (Coord.read_backlog config) in
              ("application/json", Some (Yojson.Safe.pretty_to_string backlog_json))
          | "who" -> ("text/markdown", Some (Session.status_string registry))
          | "who.json" ->
              let statuses = Session.get_agent_statuses registry in
              ("application/json", Some (Yojson.Safe.pretty_to_string (`List statuses)))
          | "agents" ->
              let json = Coord.get_agents_status config in
              ("text/markdown", Some (Yojson.Safe.pretty_to_string json))
          | "agents.json" ->
              let json = Coord.get_agents_status config in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "messages" | "messages/recent" ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              ("text/markdown", Some (Coord.get_messages config ~since_seq ~limit))
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
              let json = Coord.worktree_list config in
              ("text/markdown", Some (Yojson.Safe.pretty_to_string json))
          | "worktrees.json" ->
              let json = Coord.worktree_list config in
              ("application/json", Some (Yojson.Safe.pretty_to_string json))
          | "schema" ->
              ("text/markdown", Some Mcp_server.schema_markdown)
          | "schema.json" ->
              ("application/json", Some (Yojson.Safe.pretty_to_string Mcp_server.schema_json))
          | "institution" ->
              let file = Filename.concat config.base_path ".masc/institution.json" in
              if Sys.file_exists file then
                try
                  let json = Coord.read_json config file in
                  let inst = Institution_eio.institution_of_json json in
                  ("text/markdown", Some (Institution_eio.format_for_injection inst))
                with
                | Yojson.Json_error _ | Sys_error _ ->
                  let content = Fs_compat.load_file file in
                  ("application/json", Some content)
              else
                ("text/markdown", Some "No institution memory found. Create one with masc_init.")
          | "institution.json" ->
              let file = Filename.concat config.base_path ".masc/institution.json" in
              if Sys.file_exists file then
                let content = Fs_compat.load_file file in
                ("application/json", Some content)
              else
                ("application/json", Some "{\"error\": \"No institution memory found\"}")
          | s when Base.String.is_prefix s ~prefix:"library" ->
              let library_dir = Filename.concat config.base_path "docs/library" in
              if not (Sys.file_exists library_dir) then
                ("text/markdown", Some "Library directory not found. Create docs/library/ first.")
              else begin
                let parse_frontmatter path fallback_name =
                  try
                    let content = Fs_compat.load_file path in
                    let lines = String.split_on_char '\n' content in
                    match lines with
                    | "---" :: rest ->
                        let title = ref fallback_name in
                        let source = ref "" in
                        let verified_by = ref "" in
                        let date = ref "" in
                        let tags = ref [] in
                        let rec scan = function
                          | [] -> ()
                          | "---" :: _ -> ()
                          | line :: tl ->
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
                              let tp = "tags: " in
                              let tplen = String.length tp in
                              if String.length line > tplen
                                 && String.sub line 0 tplen = tp then begin
                                let raw = String.trim (String.sub line tplen (String.length line - tplen)) in
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
                              scan tl
                        in
                        scan rest;
                        (!title, !source, !verified_by, !date, !tags)
                    | _ -> (fallback_name, "", "", "", [])
                  with Sys_error _ -> (fallback_name, "", "", "", [])
                in
                let strip_frontmatter content =
                  if Base.String.is_prefix content ~prefix:"---" then
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
                  let path = Filename.concat library_dir (topic ^ ".md") in
                  if Sys.file_exists path then begin
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
                  end else
                    ("application/json", Some (Yojson.Safe.to_string (`Assoc [("error", `String (Printf.sprintf "Library document '%s' not found" topic))])))
                end else begin
                  let path = Filename.concat library_dir (topic ^ ".md") in
                  if Sys.file_exists path then
                    let content = Fs_compat.load_file path in
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
