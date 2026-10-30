(** Mcp_server_eio_resource — Resource reading handler

    Extracted from mcp_server_eio.ml.
    Handles resources/read JSON-RPC method for MASC resources.
*)

(* The wiki resource ids. The topic form carries the separator so a name
   like [wikifoo] is not read as the topic [foo]. *)
let wiki_index_id = "wiki"
let wiki_index_json_id = "wiki.json"
let wiki_topic_prefix = "wiki/"

(* The wiki's append-only log is one of its two own files, so it is not in
   [Tool_wiki.list_pages]. It is read as [masc://wiki/log]. [log] is a
   reserved page name, so no page can take that URI. *)
let wiki_log_topic = Filename.chop_suffix Wiki_journal.log_file ".md"

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
let run_blocking_resource_io f = Eio_unix.run_in_systhread ~label:"mcp-resource-io" f

module For_testing = struct
  let blocking_io_execution_context () =
    run_blocking_resource_io Eio_guard.execution_context
end

(* A page's header sits at the top, so the listing reads only this many bytes
   of a page to find it, not the whole file (task-2309). A page larger than
   this whose header still does not read from the prefix falls back to the
   whole file, so a header longer than the bound is listed exactly as before. *)
let frontmatter_read_limit = 8192

let read_listing_header ~path ~size =
  if size <= frontmatter_read_limit
  then Fs_compat.load_file path
  else begin
    let prefix = Fs_compat.read_slice ~path ~from:0 ~len:frontmatter_read_limit in
    match Tool_wiki.parse_frontmatter prefix with
    | Ok _ -> prefix
    | Error _ -> Fs_compat.load_file path
  end
;;

(* The log is append-only and grows without bound, so an explicit read returns
   its tail rather than the whole file (task-2309). The read is the last
   [log_read_limit] bytes, starting at a line boundary so the first line is
   whole; a log at or below the bound is returned as written. The listing's
   size is the whole file, so a client can tell a tail from the whole.

   When the last [log_read_limit] bytes hold no newline the file is a single
   line longer than the bound; the slice is then returned as read, and its
   first byte may sit inside a UTF-8 code point. Real logs add one short line
   per event, so this is a guard, not a path taken. *)
let log_read_limit = 65536

let read_log_tail ~path ~size =
  if size <= log_read_limit
  then Fs_compat.load_file path
  else begin
    let from = size - log_read_limit in
    let text = Fs_compat.read_slice ~path ~from ~len:log_read_limit in
    match String.index_opt text '\n' with
    | Some i -> String.sub text (i + 1) (String.length text - i - 1)
    | None -> text
  end
;;

(* One listed resource per page, or [None] when the name is not a valid page
   topic or the file vanished. The URI comes from the validated topic, never
   from concatenating the file name. The size is a stat, so a page's body is
   not read to list it. *)
let page_resource path : Mcp_server.mcp_resource option =
  let file = Filename.basename path in
  let topic = Filename.chop_suffix file ".md" in
  match Tool_wiki.validate_page_name topic with
  | Error _ -> None
  | Ok _ ->
    (match Fs_compat.file_size path with
     | None -> None
     | Some size ->
       (match read_listing_header ~path ~size with
        | exception Sys_error _ -> None
        | content ->
          let uri = "masc://" ^ wiki_topic_prefix ^ topic in
          (match Tool_wiki.parse_frontmatter content with
           | Ok (fm : Tool_wiki.frontmatter) ->
             Some
               (Mcp_server.make_resource
                  ~title:(fm.title :> string)
                  ~size
                  ~uri
                  ~name:topic
                  ~description:(fm.summary :> string)
                  ~mime_type:"text/markdown"
                  ())
           | Error error ->
             Some
               (Mcp_server.make_resource
                  ~size
                  ~uri
                  ~name:file
                  ~description:(Tool_wiki.frontmatter_error_to_string error)
                  ~mime_type:"text/markdown"
                  ()))))
;;

(* One listed resource per wiki page. The pages are otherwise reachable only
   through the [masc://wiki/{topic}] template, which a client that lists
   resources cannot expand, so it could not open a page. A page whose header
   does not read is listed by file name with the reason, as the index resource
   does. A file whose name is not a valid page topic is not listed: its URI
   would not read back as the same file ([notes.json.md] reads as a JSON
   request for [notes]; [?] and [#] fall to URI parsing), and the index
   resource still shows it with its reason. The log is listed once it exists.

   Read cost (task-2309): the listing no longer reads page bodies. Each page
   contributes a stat and, at most, a bounded header prefix, and the log is
   sized by stat. The TUI Resources screen follows [nextCursor], so a listing
   longer than one page is no longer cut off at its end, where the wiki entries
   sort. An explicit [masc://wiki/log] read now returns the log's tail
   ([log_read_limit]) instead of the whole file. *)
let wiki_resources ~base_path : Mcp_server.mcp_resource list =
  run_blocking_resource_io (fun () ->
    let uri_of_topic topic = "masc://" ^ wiki_topic_prefix ^ topic in
    (* [list_pages] raises [Sys_error] when the wiki root cannot be listed
       (a regular file in its place, or a stat failure other than ENOENT).
       The listing keeps every other resource and lists no wiki pages; the
       wiki tools report the failure itself. *)
    let pages =
      match Tool_wiki.list_pages ~base_path with
      | paths -> List.filter_map page_resource paths
      | exception Sys_error _ -> []
    in
    let log_path =
      Filename.concat (Tool_wiki.wiki_root ~base_path) Wiki_journal.log_file
    in
    let log =
      match Fs_compat.file_size log_path with
      | None -> []
      | Some size ->
        [ Mcp_server.make_resource
            ~title:"Wiki log"
            ~size
            ~uri:(uri_of_topic wiki_log_topic)
            ~name:wiki_log_topic
            ~description:
              "One line per wiki page creation or update, oldest first. Lines \
               are only appended. A read returns the tail: the last 65536 bytes, \
               starting at a line boundary; the size below is the whole file."
            ~mime_type:"text/markdown"
            ()
        ]
    in
    log @ pages)
;;

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
          | "messages" ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              ( "text/markdown"
              , Some
                  (run_blocking_resource_io (fun () ->
                     Workspace.get_messages config ~since_seq ~limit)) )
          | "messages.json" ->
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
          | s
            when s = wiki_index_id
                 || s = wiki_index_json_id
                 || String.starts_with s ~prefix:wiki_topic_prefix ->
              (* [Tool_wiki.list_pages] raises [Sys_error] when the wiki root
                 cannot be listed. The index and topic reads below call it,
                 so the failure answers the error envelope instead of
                 escaping the handler (the [.mli] promises [Never raises]). *)
              (match run_blocking_resource_io (fun () ->
                let base_path = config.base_path in
                let wiki_dir = Tool_wiki.wiki_root ~base_path in
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
                  if s = wiki_index_json_id then (true, "")
                  else if s = wiki_index_id then (false, "")
                  else
                    (* Past the prefix, not past a hardcoded 8: the guard above
                       matched [wiki_topic_prefix], and the two lengths have
                       to be the same number. *)
                    let prefix_len = String.length wiki_topic_prefix in
                    let rest =
                      String.sub s prefix_len (String.length s - prefix_len)
                    in
                    if Filename.check_suffix rest ".json" then
                      (true, Filename.chop_suffix rest ".json")
                    else (false, rest)
                in
                if not (Sys.file_exists wiki_dir) then
                  if topic <> "" then ("text/plain", None)
                  else if is_json then
                    ("application/json", Some (Yojson.Safe.to_string
                      (`Assoc [ ("documents", `List []); ("count", `Int 0) ])))
                  else ("text/markdown", Some "Wiki is empty.")
                else begin
                let topic_of path = Filename.chop_suffix (Filename.basename path) ".md" in
                let uri_of path = "masc://wiki/" ^ topic_of path in
                (* The same header rules as the wiki tools: a document that
                   does not read is named with its reason, never given a title
                   or a source it does not have. A file that vanishes between
                   the listing and the read is left out, as the tools do. *)
                let read_documents () =
                  Tool_wiki.list_pages ~base_path
                  |> List.filter_map (fun path ->
                    match Fs_compat.load_file path with
                    | content -> Some (path, Tool_wiki.parse_frontmatter content)
                    | exception Sys_error _ -> None)
                in
                let metadata_fields (fm : Tool_wiki.frontmatter) =
                  [ ("title", `String (fm.title :> string))
                  ; ("summary", `String (fm.summary :> string))
                  ; ("source", `String (Tool_wiki.source_to_string fm.source))
                  ; ("author", `String (fm.author :> string))
                  ; ("created", `String (fm.created :> string))
                  ; ("revision", `Int fm.revision)
                  ; ("tags", `List (List.map (fun (t : Tool_wiki.Tag.t) -> `String (t :> string)) fm.tags))
                  ]
                in
                let unreadable_fields error =
                  [ ("unreadable", `String (Tool_wiki.frontmatter_error_to_string error)) ]
                in
                (* [topic] arrives from the client's URI. Resolving it against
                   the listing rather than concatenating it onto [wiki_dir]
                   means a topic like [../../secrets] has nothing to match:
                   readdir never returns a name with a separator in it. *)
                let wiki_page_path topic =
                  let want = topic ^ ".md" in
                  List.find_opt
                    (fun path -> String.equal (Filename.basename path) want)
                    (Tool_wiki.list_pages ~base_path)
                in
                if topic = "" && not is_json then begin
                  let entries = List.map (fun (path, header) ->
                    match header with
                    | Ok (fm : Tool_wiki.frontmatter) ->
                      let tag_str = if fm.tags = [] then ""
                        else " -- " ^ String.concat ", " (List.map (fun (t : Tool_wiki.Tag.t) -> "`" ^ (t :> string) ^ "`") fm.tags) in
                      Printf.sprintf "- **%s** -- `%s` (%s)%s" (fm.title :> string) (uri_of path)
                        (Tool_wiki.source_to_string fm.source) tag_str
                    | Error error ->
                      Printf.sprintf "- %s -- `%s`"
                        (Tool_wiki.describe_unreadable path error) (uri_of path)
                  ) (read_documents ()) in
                  let body = if entries = [] then "Wiki is empty."
                    else "# Wiki index\n\n" ^ String.concat "\n" entries ^ "\n"
                  in
                  ("text/markdown", Some body)
                end else if topic = "" && is_json then begin
                  let docs = List.map (fun (path, header) ->
                    let described =
                      match header with
                      | Ok fm -> metadata_fields fm
                      | Error error -> unreadable_fields error
                    in
                    `Assoc
                      ((("topic", `String (topic_of path)) :: described)
                       @ [ ("uri", `String (uri_of path)) ])
                  ) (read_documents ()) in
                  let json = `Assoc [
                    ("documents", `List docs);
                    ("count", `Int (List.length docs));
                  ] in
                  ("application/json", Some (Yojson.Safe.to_string json))
                end else if is_json then begin
                  match wiki_page_path topic with
                  | Some path ->
                    (* A page can be listed and then become unreadable before
                       this read: deleted, or its permissions changed. Answer
                       with an error envelope rather than letting [Sys_error]
                       escape the handler, as the index and log branches
                       already do (the [.mli] promises [Never raises]). *)
                    (match Fs_compat.load_file path with
                     | exception Sys_error _ -> ("application/json", None)
                     | raw ->
                       let described =
                         match Tool_wiki.parse_frontmatter raw with
                         | Ok fm -> metadata_fields fm
                         | Error error -> unreadable_fields error
                       in
                       let json =
                         `Assoc
                           ((("topic", `String topic) :: described)
                            @ [ ("content", `String (strip_frontmatter raw)) ])
                       in
                       ("application/json", Some (Yojson.Safe.to_string json)))
                  | None -> ("application/json", None)
                end else begin
                  match wiki_page_path topic with
                  | Some path ->
                    (match Fs_compat.load_file path with
                     | content -> ("text/markdown", Some content)
                     | exception Sys_error _ -> ("text/markdown", None))
                  | None when String.equal topic wiki_log_topic ->
                    (* The log is not a page, so the listing above has no
                       entry for it. The path is the constant file name, never
                       the client's topic. The log is append-only and grows
                       without bound, so the read returns its tail rather than
                       the whole file (task-2309). *)
                    let log_path = Filename.concat wiki_dir Wiki_journal.log_file in
                    (match Fs_compat.file_size log_path with
                     | None -> ("text/markdown", None)
                     | Some size ->
                       (match read_log_tail ~path:log_path ~size with
                        | text -> ("text/markdown", Some text)
                        | exception Sys_error _ -> ("text/markdown", None)))
                  | None -> ("text/markdown", None)
                end
              end) with
               | read -> read
               | exception Sys_error _ -> ("text/plain", None))
          | _ -> ("text/plain", None)
        in

        match text_opt with
        | None ->
            make_error_typed ~id
              ~data:(`Assoc [ ("uri", `String uri_str) ])
              Mcp_error_code.Invalid_params
              "Resource not found"
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
