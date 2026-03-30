(** Keeper_exec_tools — keeper tool execution and tool-loop helpers. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting

(** Callback for recording keeper-internal tool calls.
    Set at server initialization to avoid Config dependency cycle.
    Default: no-op. Set to Tool_registry.record_call_if_known in mcp_server_eio.ml. *)
let on_keeper_tool_call :
  (tool_name:string -> success:bool -> duration_ms:int -> unit) ref =
  ref (fun ~tool_name:_ ~success:_ ~duration_ms:_ -> ())

let ensure_keeper_board_post_args ~author ~source = function
  | `Assoc fields ->
      let fields =
        List.filter
          (fun (k, _) -> k <> "author" && k <> "post_kind" && k <> "meta")
          fields
      in
      `Assoc
        ([
           ("author", `String author);
           ("post_kind", `String "automation");
           ("meta", `Assoc [ ("source", `String source) ]);
         ]
        @ fields)
  | other -> other

let keeper_read_tool_names =
  [
    "keeper_read";
    "keeper_fs_read";
    "keeper_memory_search";
    "keeper_library_search";
    "keeper_library_read";
    "keeper_time_now";
    "keeper_context_status";
  ]

let keeper_coordination_tool_names =
  [ "keeper_tasks_list"; "keeper_task_claim"; "keeper_task_done"; "keeper_broadcast" ]

let keeper_board_tool_names =
  [
    "keeper_board_get";
    "keeper_board_post";
    "keeper_board_comment";
    "keeper_board_vote";
    "keeper_board_list";
  ]

let keeper_voice_tool_names =
  [ "keeper_voice_speak"; "keeper_voice_agent"; "keeper_voice_sessions";
    "keeper_voice_session_start"; "keeper_voice_session_end" ]

let keeper_shell_readonly_tool_names = [ "keeper_shell_readonly" ]

let keeper_governance_tool_names =
  Tool_shard.governance_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_coding_shard_tool_names =
  Tool_shard.coding_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_autoresearch_tool_names =
  Tool_shard.autoresearch_keeper_tools
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_research_loop_tool_names =
  Tool_research.schemas
  |> List.map (fun (t : Types.tool_schema) -> t.name)

let keeper_coding_tool_names = Tool_code_write.tool_names

let keeper_voice_tool_schemas =
  match Tool_shard.get_shard "voice" with
  | Some shard -> shard.tools
  | None -> []

(** masc_* bridge for keepers.
    All masc_* schemas are injected at server init and exposed to keepers
    unconditionally. Execution dispatch (catch-all at bottom of
    execute_keeper_tool_call) already handles any masc_* tool. *)

let masc_schemas_ref : Types.tool_schema list ref = ref []

let inject_masc_schemas (schemas : Types.tool_schema list) =
  masc_schemas_ref :=
    List.filter (fun (s : Types.tool_schema) ->
      String.starts_with ~prefix:"masc_" s.name)
      schemas

(** Apply allowlist/denylist filtering to masc_* tool names.
    - allowlist empty → all masc_* tools allowed (no restriction)
    - allowlist non-empty → only listed tools allowed
    - denylist always wins (deny overrides allow) *)
let filter_by_access ~(allowlist : string list) ~(denylist : string list)
    (name : string) : bool =
  let allowed =
    match allowlist with
    | [] -> true
    | _ -> List.mem name allowlist
  in
  allowed && not (List.mem name denylist)

let keeper_masc_tool_names (meta : keeper_meta) : string list =
  !masc_schemas_ref
  |> List.filter_map (fun (schema : Types.tool_schema) ->
    if filter_by_access
         ~allowlist:meta.tool_allowlist
         ~denylist:meta.tool_denylist
         schema.name
    then Some schema.name
    else None)

let keeper_masc_tool_schemas (meta : keeper_meta) : Types.tool_schema list =
  !masc_schemas_ref
  |> List.filter (fun (schema : Types.tool_schema) ->
    filter_by_access
      ~allowlist:meta.tool_allowlist
      ~denylist:meta.tool_denylist
      schema.name)

let dedupe_tool_names names =
  dedupe_keep_order (List.filter (fun name -> String.trim name <> "") names)

let keeper_default_tool_names (_meta : keeper_meta) : string list =
  let base_names = keeper_model_tools |> List.map (fun tool -> tool.Types.name) in
  dedupe_tool_names (keeper_voice_tool_names @ base_names)

let keeper_default_model_tools (_meta : keeper_meta) : Types.tool_schema list =
  keeper_model_tools @ keeper_voice_tool_schemas

(** Return keeper tool names with allowlist/denylist gating on masc_*.
    keeper_* tools pass unconditionally. masc_* tools from any source
    (shards, passthrough, defaults) are filtered by tool_allowlist/tool_denylist. *)
let keeper_allowed_tool_names ?(write_done = false) (meta : keeper_meta) :
    string list =
  if write_done then
    []
  else
    let all_names =
      keeper_read_tool_names
      @ keeper_coordination_tool_names
      @ keeper_board_tool_names
      @ keeper_shell_readonly_tool_names
      @ keeper_governance_tool_names
      @ keeper_coding_shard_tool_names
      @ keeper_coding_tool_names
      @ keeper_autoresearch_tool_names
      @ keeper_research_loop_tool_names
      @ (keeper_masc_tool_names meta)
      @ (keeper_default_tool_names meta)
    in
    all_names
    |> List.filter (fun name ->
      if String.starts_with ~prefix:"masc_" name then
        filter_by_access
          ~allowlist:meta.tool_allowlist
          ~denylist:meta.tool_denylist
          name
      else
        true)
    |> dedupe_tool_names

(** Return keeper model tool schemas with allowlist/denylist gating. *)
let keeper_allowed_model_tools ?(write_done = false) (meta : keeper_meta) :
    Types.tool_schema list =
  let allowed = keeper_allowed_tool_names ~write_done meta in
  if allowed = [] then
    []
  else
    let all_schemas =
      (keeper_default_model_tools meta)
      @ Tool_research.schemas
      @ Tool_shard.autoresearch_keeper_tools
      @ Tool_shard.coding_tools
      @ Tool_code_write.schemas
      @ (keeper_masc_tool_schemas meta)
    in
    let result =
      all_schemas
      |> List.filter (fun tool -> List.mem tool.Types.name allowed)
    in
    let count = List.length result in
    if count > 100 then
      Log.Keeper.warn
        "tool budget exceeded: %d schemas in LLM context (~%dKB estimated). \
         Consider restricting tool tier."
        count (count * 470 / 1024);
    result

let keeper_text_fallback_json ~(agent_id : string) ~(message : string) =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [
      ("status", `String "text_fallback");
      ("agent_id", `String agent_id);
      ("voice", `String voice);
      ("message_preview", `String (short_preview ~max_len:50 message));
    ]

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))

let lines_to_json ?(limit = max_int) (text : string) : Yojson.Safe.t =
  let lines =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
    |> fun rows -> if List.length rows > limit then take limit rows else rows
  in
  `List (List.map (fun line -> `String line) lines)

let execute_keeper_tool_call
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(ctx_work : Keeper_working_context.working_context)
    ~(name : string) ~(input : Yojson.Safe.t) : string =
  let args = input in
  let now_ts = Time_compat.now () in
  match name with
  | "keeper_time_now" ->
      Yojson.Safe.to_string
        (`Assoc
          [ ("now_iso", `String (now_iso ())); ("now_unix", `Float now_ts) ])
  | "keeper_context_status" ->
      let continuity = latest_state_snapshot_from_messages ctx_work.messages in
      let continuity_summary =
        match continuity with
        | None ->
            let trimmed = String.trim meta.continuity_summary in
            if trimmed = "" then "No continuity snapshot available." else trimmed
        | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
      in
      Yojson.Safe.to_string
        (`Assoc
          [
            ("name", `String meta.name);
            ("trace_id", `String meta.runtime.trace_id);
            ("generation", `Int meta.runtime.generation);
            ("context_ratio", `Float (Keeper_working_context.context_ratio ctx_work));
            ("context_tokens", `Int ctx_work.token_count);
            ("context_max", `Int ctx_work.max_tokens);
            ("message_count", `Int (List.length ctx_work.messages));
            ("last_model_used", `String meta.runtime.usage.last_model_used);
            ( "continuity_state",
              match continuity with
              | None -> `Null
              | Some snapshot -> keeper_state_snapshot_to_json snapshot );
            ("continuity_summary", `String continuity_summary);
          ])
  | "keeper_memory_search" ->
      let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
      let limit = max 1 (min 8 (Safe_ops.json_int ~default:5 "limit" args)) in
      let user_msgs = extract_user_messages ctx_work in
      let matches =
        user_msgs
        |> List.filter (fun msg -> query <> "" && contains_ci msg query)
        |> List.rev
        |> take limit
        |> List.map (fun msg -> `String msg)
      in
      Yojson.Safe.to_string
        (`Assoc
          [
            ("query", `String query);
            ("match_count", `Int (List.length matches));
            ("matches", `List matches);
          ])
  | "keeper_library_search" ->
      let ok, msg = Tool_library.handle_search
        Tool_library.{ agent_name = meta.name }
        args
      in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_library_read" ->
      let ok, msg = Tool_library.handle_read
        Tool_library.{ agent_name = meta.name }
        args
      in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_board_post" ->
      let author = meta.name in
      Log.Keeper.info "keeper_board_post called by %s, raw args: %s"
        author (Yojson.Safe.to_string args);
      let board_args =
        match args with
        | `Assoc fields ->
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      let board_args =
        ensure_keeper_board_post_args
          ~author ~source:"keeper_board_post" board_args
      in
      Log.Keeper.info "board_args: %s"
        (Yojson.Safe.to_string board_args);
      let ok, msg = Tool_board.handle_tool "masc_board_post" board_args in
      Log.Keeper.info "handle_tool result: ok=%b msg=%s" ok
        (if String.length msg > 200 then String.sub msg 0 200 ^ "..." else msg);
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_board_list" ->
      let ok, msg = Tool_board.handle_tool "masc_board_list" args in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_board_get" ->
      let ok, msg = Tool_board.handle_tool "masc_board_get" args in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_board_comment" ->
      let author = meta.name in
      let board_args =
        match args with
        | `Assoc fields ->
            let fields' = List.filter (fun (k, _) -> k <> "author") fields in
            `Assoc (("author", `String author) :: fields')
        | other -> other
      in
      let ok, msg = Tool_board.handle_tool "masc_board_comment" board_args in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_board_vote" ->
      let voter = meta.name in
      let board_args =
        match args with
        | `Assoc fields ->
            let fields' = List.filter (fun (k, _) -> k <> "voter") fields in
            `Assoc (("voter", `String voter) :: fields')
        | other -> other
      in
      let ok, msg = Tool_board.handle_tool "masc_board_vote" board_args in
      if ok then msg
      else Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
  | "keeper_fs_read" | "keeper_read" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let max_bytes =
        Safe_ops.json_int ~default:20000 "max_bytes" args
        |> fun n -> max 512 (min 200000 n)
      in
      (match resolve_keeper_target_path ~config ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta) ~raw_path:path with
      | Error e -> Yojson.Safe.to_string (`Assoc [ ("error", `String e) ])
      | Ok target -> (
          match Safe_ops.read_file_safe target with
          | Error e ->
              Yojson.Safe.to_string
                (`Assoc [ ("error", `String e); ("path", `String target) ])
          | Ok content ->
              let total = String.length content in
              let truncated = total > max_bytes in
              let body =
                if truncated then String.sub content 0 max_bytes else content
              in
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("ok", `Bool true);
                    ("path", `String target);
                    ("bytes", `Int total);
                    ("truncated", `Bool truncated);
                    ("content", `String body);
                  ])))
  | "keeper_fs_edit" | "keeper_edit" ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      let content = Safe_ops.json_string ~default:"" "content" args in
      let mode =
        Safe_ops.json_string ~default:"overwrite" "mode" args
        |> String.lowercase_ascii
      in
      (match resolve_keeper_target_path ~config ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta) ~raw_path:path with
      | Error e -> Yojson.Safe.to_string (`Assoc [ ("error", `String e) ])
      | Ok target ->
          (try
             let parent = Filename.dirname target in
             Fs_compat.mkdir_p parent;
             (match mode with
             | "append" ->
                 Fs_compat.append_file target content
             | "overwrite" | "" ->
                 Fs_compat.save_file target content
             | other -> raise (Invalid_argument ("unsupported_mode:" ^ other)));
             Yojson.Safe.to_string
               (`Assoc
                 [
                   ("ok", `Bool true);
                   ("path", `String target);
                   ("mode", `String (if mode = "" then "overwrite" else mode));
                   ("bytes_written", `Int (String.length content));
                 ])
           with
          | Invalid_argument e ->
              Yojson.Safe.to_string
                (`Assoc [ ("error", `String e); ("path", `String target) ])
          | Sys_error e ->
              Yojson.Safe.to_string
                (`Assoc [ ("error", `String e); ("path", `String target) ])
          | Unix.Unix_error (err, _, _) ->
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("error", `String (Unix.error_message err));
                    ("path", `String target);
                  ])))
  | "keeper_bash" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      if cmd = "" then
        Yojson.Safe.to_string (`Assoc [ ("error", `String "cmd_required") ])
      else begin
        match Worker_dev_tools.validate_command cmd with
        | Error reason ->
          Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason cmd;
          Yojson.Safe.to_string
            (`Assoc [
              ("ok", `Bool false);
              ("error", `String "command_blocked");
              ("reason", `String reason);
            ])
        | Ok () ->
          if Worker_dev_tools.is_write_operation cmd then begin
            Log.Keeper.info
              "keeper_bash write-gate: %s (keeper=%s)"
              cmd (meta.name);
            Yojson.Safe.to_string
              (`Assoc [
                ("ok", `Bool false);
                ("error", `String "write_operation_gated");
                ("reason", `String
                  "This command modifies state (git push/commit, make deploy, etc.). \
                   Use keeper_shell_readonly for read operations, or request \
                   shell_mode=coding policy from the operator.");
                ("cmd", `String cmd);
              ])
          end else begin
            let root = project_root_of_config config in
            let shell_cmd =
              Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) cmd
            in
            let st, out =
              Process_eio.run_argv_with_status ~timeout_sec
                [ "/bin/bash"; "-lc"; shell_cmd ]
            in
            Yojson.Safe.to_string
              (`Assoc
                [
                  ("ok", `Bool (st = Unix.WEXITED 0));
                  ("status", process_status_to_json st);
                  ("output", `String (truncate_tool_output out));
                ])
          end
      end
  | "keeper_shell_readonly" ->
      let op =
        Safe_ops.json_string ~default:"" "op" args
        |> String.trim |> String.lowercase_ascii
      in
      let root = project_root_of_config config in
      let read_target () =
        let raw_path = Safe_ops.json_string ~default:"." "path" args in
        resolve_keeper_target_path ~config ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta) ~raw_path
      in
      let render_process_result ~cmd argv =
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:15.0 argv
        in
        Yojson.Safe.to_string
          (`Assoc
            [
              ("ok", `Bool (st = Unix.WEXITED 0));
              ("op", `String op);
              ("cmd", `String cmd);
              ("status", process_status_to_json st);
              ("output", `String (truncate_tool_output out));
            ])
      in
      (match op with
      | "pwd" -> render_process_result ~cmd:"pwd" [ "/bin/pwd" ]
      | "git_status" ->
          render_process_result
            ~cmd:"git -C <root> status --short --branch"
            [ "git"; "-C"; root; "status"; "--short"; "--branch" ]
      | "ls" -> (
          match read_target () with
          | Error e ->
              Yojson.Safe.to_string
                (`Assoc [ ("error", `String e); ("op", `String op) ])
          | Ok target ->
              let st, out =
                Process_eio.run_argv_with_status ~timeout_sec:15.0
                  [ "/bin/ls"; "-la"; target ]
              in
              let limit = shell_readonly_limit args in
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("ok", `Bool (st = Unix.WEXITED 0));
                    ("op", `String op);
                    ("path", `String target);
                    ("status", process_status_to_json st);
                    ("entries", lines_to_json ~limit out);
                  ]))
      | "cat" -> (
          match read_target () with
          | Error e ->
              Yojson.Safe.to_string
                (`Assoc [ ("error", `String e); ("op", `String op) ])
          | Ok target ->
              let max_bytes = shell_readonly_cat_max_bytes args in
              let st, out =
                Process_eio.run_argv_with_status ~timeout_sec:15.0
                  [ "/bin/cat"; target ]
              in
              let body =
                if String.length out > max_bytes then String.sub out 0 max_bytes
                else out
              in
              Yojson.Safe.to_string
                (`Assoc
                  [
                    ("ok", `Bool (st = Unix.WEXITED 0));
                    ("op", `String op);
                    ("path", `String target);
                    ("status", process_status_to_json st);
                    ("truncated", `Bool (String.length out > max_bytes));
                    ("content", `String body);
                  ]))
      | "rg" -> (
          let pattern =
            Safe_ops.json_string ~default:"" "pattern" args |> String.trim
          in
          if pattern = "" then
            Yojson.Safe.to_string
              (`Assoc
                [ ("error", `String "pattern_required"); ("op", `String op) ])
          else
            match read_target () with
            | Error e ->
                Yojson.Safe.to_string
                  (`Assoc [ ("error", `String e); ("op", `String op) ])
            | Ok target ->
                let limit = shell_readonly_limit args in
                let st, out =
                  Process_eio.run_argv_with_status ~timeout_sec:15.0
                    [ "rg"; "-n"; "-m"; string_of_int limit; pattern; target ]
                in
                Yojson.Safe.to_string
                  (`Assoc
                    [
                      ("ok", `Bool (st = Unix.WEXITED 0));
                      ("op", `String op);
                      ("path", `String target);
                      ("pattern", `String pattern);
                      ("status", process_status_to_json st);
                      ("matches", lines_to_json ~limit out);
                    ]))
      | _ ->
          Yojson.Safe.to_string
            (`Assoc
              [
                ("error", `String "unsupported_op");
                ("op", `String op);
                ( "supported_ops",
                  `List
                    (List.map
                       (fun name -> `String name)
                       [ "pwd"; "ls"; "cat"; "rg"; "git_status" ]) );
              ]))
  | "keeper_voice_speak" ->
      let message =
        Safe_ops.json_string ~default:"" "message" args |> String.trim
      in
      let provider =
        Safe_ops.json_string_opt "provider" args
        |> Option.map String.trim
        |> function
        | Some p when p <> "" -> Some p
        | _ -> None
      in
      let priority = max 1 (Safe_ops.json_int ~default:1 "priority" args) in
      if message = "" then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "message_required") ])
      else
        (match
           ( Eio_context.get_switch_opt (),
             Eio_context.get_clock_opt (),
             Eio_context.get_net_opt () )
         with
        | Some sw, Some clock, Some net -> (
            match
              Voice_bridge.agent_speak ~sw ~clock ~net ~agent_id:meta.name
                ~message ?provider ~priority ()
            with
            | Ok json -> Yojson.Safe.to_string json
            | Error err ->
                Yojson.Safe.to_string
                  (`Assoc
                    [
                      ("status", `String "error");
                      ("agent_id", `String meta.name);
                      ("message", `String err);
                    ]))
        | _ ->
            Yojson.Safe.to_string
              (keeper_text_fallback_json ~agent_id:meta.name ~message))
  | "keeper_voice_agent" ->
      (* No net required — reads local voice config *)
      (match Voice_bridge.get_agent_voice ~agent_id:meta.name with
      | Ok json -> Yojson.Safe.to_string json
      | Error err ->
          Yojson.Safe.to_string
            (`Assoc
              [ ("status", `String "error");
                ("agent_id", `String meta.name);
                ("message", `String err) ]))
  | "keeper_voice_sessions" ->
      (* Local session manager — no net/MCP dependency *)
      let mgr = Keeper_voice_local.get_session_manager () in
      let sessions = Voice_session_manager.list_sessions mgr in
      Yojson.Safe.to_string
        (`Assoc
          [ ("session_count", `Int (List.length sessions));
            ("sessions",
              `List (List.map Voice_session_manager.session_to_json sessions)) ])
  | "keeper_voice_session_start" ->
      (* Local session manager — no net/MCP dependency *)
      let voice =
        Safe_ops.json_string_opt "session_name" args
        |> Option.map String.trim
        |> function Some s when s <> "" -> Some s | _ -> None
      in
      let mgr = Keeper_voice_local.get_session_manager () in
      let session =
        Voice_session_manager.start_session mgr ~agent_id:meta.name ?voice ()
      in
      Yojson.Safe.to_string
        (Voice_session_manager.session_to_json session)
  | "keeper_voice_session_end" ->
      (* Local session manager — no net/MCP dependency *)
      let mgr = Keeper_voice_local.get_session_manager () in
      let ended = Voice_session_manager.end_session mgr ~agent_id:meta.name in
      Yojson.Safe.to_string
        (`Assoc
          [ ("status", `String (if ended then "ended" else "no_active_session"));
            ("agent_id", `String meta.name) ])
  | "keeper_github" ->
      let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
      let gh_args = Safe_ops.json_string_list "args" args in
      let timeout_sec =
        Safe_ops.json_float ~default:30.0 "timeout_sec" args
        |> fun n -> max 1.0 (min 180.0 n)
      in
      let gh_cmd =
        if cmd <> "" then "gh " ^ cmd
        else if gh_args <> [] then
          "gh " ^ String.concat " " (List.map Filename.quote gh_args)
        else ""
      in
      if gh_cmd = "" then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "cmd_or_args_required") ])
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) gh_cmd
        in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec
            [ "/bin/zsh"; "-lc"; shell_cmd ]
        in
        Yojson.Safe.to_string
          (`Assoc
            [
              ("ok", `Bool (st = Unix.WEXITED 0));
              ("status", process_status_to_json st);
              ("output", `String (truncate_tool_output out));
            ])
  | "keeper_tasks_list" ->
      let status_filter = Safe_ops.json_string_opt "status" args in
      let include_done =
        Safe_ops.json_bool ~default:false "include_done" args
      in
      Room.list_tasks ?status:status_filter ~include_done config
  | "keeper_tasks_audit" ->
      let orphans = Room.audit_orphan_tasks config in
      let items =
        List.map
          (fun (task, assignee) ->
            let task : Types.task = task in
            `Assoc
              [
                ("task_id", `String task.id);
                ("title", `String task.title);
                ("assignee", `String assignee);
                ("status", `String (Types.string_of_task_status task.task_status));
              ])
          orphans
      in
      Yojson.Safe.to_string
        (`Assoc
          [
            ("orphan_count", `Int (List.length orphans));
            ("orphans", `List items);
          ])
  | "keeper_task_force_release" ->
      let task_id =
        Safe_ops.json_string ~default:"" "task_id" args |> String.trim
      in
      let reason = Safe_ops.json_string ~default:"" "reason" args in
      if task_id = "" then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "task_id required") ])
      else
        let agent = Printf.sprintf "keeper:%s" meta.name in
        let _ =
          Room.broadcast config ~from_agent:agent
            ~content:
              (Printf.sprintf "Force-releasing task %s (reason: %s)" task_id
                 (if reason = "" then "no reason given" else reason))
        in
        (match Room.force_release_task_r config ~agent_name:agent ~task_id () with
        | Ok msg ->
            Yojson.Safe.to_string
              (`Assoc [ ("ok", `Bool true); ("result", `String msg) ])
        | Error e ->
            Yojson.Safe.to_string
              (`Assoc
                [
                  ("ok", `Bool false);
                  ("error", `String (Types.masc_error_to_string e));
                ]))
  | "keeper_task_force_done" ->
      let task_id =
        Safe_ops.json_string ~default:"" "task_id" args |> String.trim
      in
      let notes = Safe_ops.json_string ~default:"" "notes" args in
      if task_id = "" then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "task_id required") ])
      else
        let agent = Printf.sprintf "keeper:%s" meta.name in
        (match
           Room.force_done_task_r config ~agent_name:agent ~task_id ~notes ()
         with
        | Ok msg ->
            Yojson.Safe.to_string
              (`Assoc [ ("ok", `Bool true); ("result", `String msg) ])
        | Error e ->
            Yojson.Safe.to_string
              (`Assoc
                [
                  ("ok", `Bool false);
                  ("error", `String (Types.masc_error_to_string e));
                ]))
  | "keeper_broadcast" ->
      let message =
        Safe_ops.json_string ~default:"" "message" args |> String.trim
      in
      if message = "" then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "message required") ])
      else
        let agent = Printf.sprintf "keeper:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent ~content:message in
        Yojson.Safe.to_string
          (`Assoc [ ("ok", `Bool true); ("broadcast", `String message) ])
  | "keeper_task_claim" ->
      let result = Room.claim_next config ~agent_name:meta.agent_name in
      Yojson.Safe.to_string (`Assoc [ ("result", `String result) ])
  | "keeper_task_done" ->
      let task_id =
        Safe_ops.json_string ~default:"" "task_id" args |> String.trim
      in
      let result_text =
        Safe_ops.json_string ~default:"" "result" args |> String.trim
      in
      if task_id = "" then
        Yojson.Safe.to_string (`Assoc [ ("error", `String "task_id required") ])
      else
        let agent = Printf.sprintf "keeper:%s" meta.name in
        let notes = if result_text = "" then "" else result_text in
        (match
           Room.force_done_task_r config ~agent_name:agent ~task_id ~notes ()
         with
         | Ok msg ->
             Yojson.Safe.to_string
               (`Assoc [ ("ok", `Bool true); ("result", `String msg) ])
         | Error e ->
             Yojson.Safe.to_string
               (`Assoc [ ("ok", `Bool false);
                          ("error", `String (Types.masc_error_to_string e)) ]))
  | name when String.starts_with ~prefix:"masc_autoresearch_" name ->
      if not (filter_by_access
                ~allowlist:meta.tool_allowlist
                ~denylist:meta.tool_denylist name) then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "tool_not_allowed");
                    ("tool", `String name) ])
      else
      let ctx : Tool_autoresearch.context = {
        base_path = project_root_of_config config;
        agent_name = Some meta.name;
        start_operation = None;
        start_team_session = None;
        config = Some config;
        sw = None;
        clock = None;
      } in
      (match Tool_autoresearch.dispatch ctx ~name ~args with
      | Some (true, msg) -> msg
      | Some (false, msg) ->
          Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
      | None ->
          Yojson.Safe.to_string
            (`Assoc [ ("error", `String "unknown_autoresearch_tool");
                      ("tool", `String name) ]))
  | name when String.starts_with ~prefix:"masc_" name ->
      (* Allowlist/denylist enforcement at execution time.
         Even if the LLM hallucinates a tool name that wasn't in the schema,
         this gate blocks execution. Deny always wins. *)
      if not (filter_by_access
                ~allowlist:meta.tool_allowlist
                ~denylist:meta.tool_denylist name) then
        Yojson.Safe.to_string
          (`Assoc [ ("error", `String "tool_not_allowed");
                    ("tool", `String name) ])
      else
      (* Pre-dispatch path guard: if the tool args contain a path/file_path
         key, validate it against effective_allowed_paths before dispatching. *)
      let effective_paths = Keeper_alerting_path.effective_allowed_paths ~meta in
      let path_blocked =
        if effective_paths = [] && meta.execution_scope <> "observe_only" then None
        else if meta.execution_scope = "observe_only" && effective_paths = [] then
          (* observe_only with no explicit paths: block write-capable tool args *)
          let has_path_arg =
            List.exists (fun key ->
              match Yojson.Safe.Util.member key args with
              | `String p when String.trim p <> "" -> true
              | _ -> false) ["path"; "file_path"; "target_path"]
          in
          if has_path_arg then Some "observe_only_scope: write paths blocked"
          else None
        else
          let candidates =
            List.filter_map (fun key ->
              match Yojson.Safe.Util.member key args with
              | `String p when String.trim p <> "" -> Some p
              | _ -> None)
              ["path"; "file_path"; "target_path"]
          in
          List.find_map (fun raw ->
            match resolve_keeper_target_path ~config
                    ~allowed_paths:effective_paths ~raw_path:raw with
            | Error e -> Some e
            | Ok _ -> None) candidates
      in
      (match path_blocked with
      | Some err ->
          Yojson.Safe.to_string (`Assoc [ ("error", `String err) ])
      | None ->
      let t0 = Time_compat.now () in
      let result = Tool_dispatch.dispatch ~name ~args in
      let duration_ms =
        int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
      let success, msg = match result with
        | Some (true, msg) -> true, msg
        | Some (false, msg) ->
            false, Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
        | None ->
            false, Yojson.Safe.to_string
              (`Assoc [ ("error", `String "unregistered_masc_tool");
                        ("tool", `String name) ])
      in
      !on_keeper_tool_call ~tool_name:name ~success ~duration_ms;
      msg)
  | other ->
      Yojson.Safe.to_string
        (`Assoc [ ("error", `String "unknown_tool"); ("tool", `String other) ])

(* keeper_tool_loop_system_prompt and keeper_tool_followup_prompt removed:
   Agent.run() handles tool dispatch and follow-up natively. *)
