(** Keeper_exec_tools — keeper tool execution and tool-loop helpers. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting

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
    "keeper_time_now";
    "keeper_context_status";
  ]

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

let dedupe_tool_names names =
  dedupe_keep_order (List.filter (fun name -> String.trim name <> "") names)

let keeper_allowed_tool_names ?(write_done = false) (meta : keeper_meta) :
    string list =
  if write_done then
    []
  else if keeper_policy_mode_is_learned meta then
    let base = keeper_read_tool_names in
    let with_voice =
      if meta.policy_voice_enabled then keeper_voice_tool_names @ base else base
    in
    let with_shell =
      if canonical_policy_shell_mode meta.policy_shell_mode = "readonly" then
        keeper_shell_readonly_tool_names @ with_voice
      else with_voice
    in
    match canonical_policy_action_budget meta.policy_action_budget with
    | "board" -> dedupe_tool_names (keeper_board_tool_names @ with_shell)
    | _ -> dedupe_tool_names with_shell
  else keeper_llm_tools |> List.map (fun tool -> tool.Cascade.tool_name)

let keeper_allowed_llm_tools ?(write_done = false) (meta : keeper_meta) :
    Cascade.tool_def list =
  let allowed = keeper_allowed_tool_names ~write_done meta in
  if allowed = [] then
    []
  else
    keeper_llm_tools
    |> List.filter (fun tool -> List.mem tool.Cascade.tool_name allowed)

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
    ~(ctx_work : Context_manager.working_context)
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
            ("trace_id", `String meta.trace_id);
            ("generation", `Int meta.generation);
            ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
            ("context_tokens", `Int ctx_work.token_count);
            ("context_max", `Int ctx_work.max_tokens);
            ("message_count", `Int (List.length ctx_work.messages));
            ("last_model_used", `String meta.last_model_used);
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
  | "keeper_weather_note" ->
      let location =
        Safe_ops.json_string ~default:"current location" "location" args
      in
      let recent_weather_questions =
        extract_user_messages ctx_work
        |> List.filter is_weather_text
        |> List.rev
        |> take 5
        |> List.map (fun q -> `String q)
      in
      Yojson.Safe.to_string
        (`Assoc
          [
            ("location", `String location);
            ("capability", `String "no_realtime_weather_feed");
            ("note", `String "This keeper cannot fetch live weather by itself.");
            ("recent_weather_questions", `List recent_weather_questions);
          ])
  | "keeper_board_post" ->
      let author = meta.name in
      Log.Trpg.info "keeper_board_post called by %s, raw args: %s"
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
      Log.Trpg.info "board_args: %s"
        (Yojson.Safe.to_string board_args);
      let ok, msg = Tool_board.handle_tool "masc_board_post" board_args in
      Log.Trpg.info "handle_tool result: ok=%b msg=%s" ok
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
      (match resolve_keeper_target_path ~config ~raw_path:path with
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
      (match resolve_keeper_target_path ~config ~raw_path:path with
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
      else
        let root = project_root_of_config config in
        let shell_cmd =
          Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) cmd
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
  | "keeper_shell_readonly" ->
      let op =
        Safe_ops.json_string ~default:"" "op" args
        |> String.trim |> String.lowercase_ascii
      in
      let root = project_root_of_config config in
      let read_target () =
        let raw_path = Safe_ops.json_string ~default:"." "path" args in
        resolve_keeper_target_path ~config ~raw_path
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
        let agent = Printf.sprintf "gardener:%s" meta.name in
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
        let agent = Printf.sprintf "gardener:%s" meta.name in
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
        let agent = Printf.sprintf "gardener:%s" meta.name in
        let _ = Room.broadcast config ~from_agent:agent ~content:message in
        Yojson.Safe.to_string
          (`Assoc [ ("ok", `Bool true); ("broadcast", `String message) ])
  | other ->
      Yojson.Safe.to_string
        (`Assoc [ ("error", `String "unknown_tool"); ("tool", `String other) ])

let keeper_tool_loop_system_prompt ~(character_context : string) : string =
  Printf.sprintf
    "%s\n\n\
     TOOL-LOOP INSTRUCTIONS:\n\
     When you have all the information needed, produce a final text answer.\n\
     When you still need more data or actions, call the appropriate tool.\n\
     Never output SKILL: prefixes. Use function calling only.\n\
     Stay in character when writing content."
    character_context

let keeper_tool_followup_prompt
    ~(user_message : string)
    ~(draft_reply : string)
    ~(tool_outputs : (string * Yojson.Safe.t * string) list)
    ~(already_executed : string list) : string =
  let rendered =
    tool_outputs
    |> List.map (fun (name, input, output) ->
           Printf.sprintf "- %s(%s)\n  => %s" name
             (Yojson.Safe.to_string input) output)
    |> String.concat "\n"
  in
  let is_write_tool (name : string) : bool =
    List.mem name
      [
        "keeper_board_post";
        "keeper_board_comment";
        "keeper_board_vote";
        "keeper_fs_edit";
        "keeper_edit";
        "keeper_task_force_release";
        "keeper_task_force_done";
        "keeper_broadcast";
        "keeper_voice_speak";
        "keeper_voice_session_start";
        "keeper_voice_session_end";
      ]
  in
  let has_write = List.exists is_write_tool already_executed in
  let rules =
    if has_write then
      "RULES (follow strictly):\n\
       You have already posted to the board. ALL required actions are DONE.\n\
       Produce a brief final text answer confirming what you did. Do NOT call any more tools."
    else
      "RULES (follow strictly):\n\
       1. If the user asked you to POST, WRITE, or UPDATE something, you MUST call \
          the appropriate tool (e.g. keeper_board_post). Do NOT return the content as text.\n\
       2. If you still need information, call the appropriate read/list tool.\n\
       3. Only produce a final text answer when ALL required actions (reads AND writes) are done.\n\
       4. Use tool outputs as source of truth.\n\
       5. Reply in user's language and stay concise."
  in
  Printf.sprintf
    "You called tools. Here are the results.\n\n\
     User message: %s\n\
     Draft reply: %s\n\
     Tool results:\n%s\n\
     Previously executed: [%s]\n\n\
     %s\n"
    user_message draft_reply rendered (String.concat ", " already_executed) rules

let memory_correction_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" -> (
        match List.rev candidate_user_msgs with
        | earliest :: _ ->
            Printf.sprintf
              "- You MUST return the earliest question in the list exactly or near-verbatim: %s\n"
              earliest
        | [] ->
            "- User asked for the first question. Pick the earliest evidence if available.\n")
    | Some "weather" ->
        "- User asked about weather recall. Choose the weather-related question from evidence.\n"
    | _ ->
        "- Choose the single most relevant previous user question from evidence.\n"
  in
  Printf.sprintf
    "Memory correction required.\n\
     User asked: %s\n\
     Your previous answer: %s\n\
     Ground truth previous user questions:\n%s\n\n\
     Rewrite your answer using ONLY this evidence.\n\
     - If uncertain, explicitly say uncertain.\n\
     - Do not invent questions.\n\
     %s\
     - Keep concise.\n"
    user_message first_reply evidence topic_instruction

let memory_forced_grounding_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        "- Intent: user asked for the first question. Evidence list order is newest->oldest, so choose the LAST evidence line.\n"
    | Some "weather" ->
        "- Intent: user asked about weather. Choose the weather-related evidence line.\n"
    | _ ->
        "- Intent: user asked about previous question. Prefer the most recent evidence unless user asked otherwise.\n"
  in
  Printf.sprintf
    "Strict memory grounding retry.\n\
     User asked: %s\n\
     Your previous answer failed grounding validation: %s\n\
     Evidence (ordered newest to oldest):\n%s\n\n\
     You MUST answer using exactly one evidence line.\n\
     - The first line MUST be the chosen evidence question copied verbatim and wrapped in double quotes.\n\
     - Then add one concise sentence in the user's language.\n\
     - Do not invent or paraphrase the chosen question.\n\
     - Keep [STATE] continuity block at the end.\n\
     %s"
    user_message first_reply evidence topic_instruction

let contains_korean_text (s : string) : bool =
  try
    let _ = Str.search_forward (Str.regexp "[가-힣]") s 0 in
    true
  with Not_found -> false

let is_recent_question_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) s 0 in
      true
    with Not_found -> false
  in
  let has_en needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) q 0 in
      true
    with Not_found -> false
  in
  has_ko "방금"
  || has_ko "직전"
  || has_ko "바로 전"
  || has_ko "좀 전에"
  || has_ko "전 질문"
  || has_en "just asked"
  || has_en "last question"
  || has_en "previous question"
  || has_en "most recent question"

let has_weather_keyword (s : string) : bool =
  let q = String.lowercase_ascii s in
  (try
     let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in
     true
   with Not_found -> false)
  ||
  (try
     let _ = Str.search_forward (Str.regexp_string "weather") q 0 in
     true
   with Not_found -> false)

let select_recall_candidate
    ~(user_message : string)
    ~(expected_topic : string option)
    ~(best_match : string option)
    (candidates : string list) : string option =
  let best_match =
    match best_match with
    | Some text ->
        let text = String.trim text in
        if text = "" then None else Some text
    | None -> None
  in
  let most_recent =
    match candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let oldest =
    match List.rev candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let weather_candidate =
    match List.find_opt has_weather_keyword candidates with
    | None -> None
    | Some c ->
        let c = String.trim c in
        if c = "" then None else Some c
  in
  match expected_topic with
  | Some "first_question" -> (
      match oldest with Some _ as x -> x | None -> best_match)
  | Some "weather" -> (
      match weather_candidate with
      | Some _ as x -> x
      | None -> (
          match best_match with Some _ as x -> x | None -> most_recent))
  | _ ->
      if is_recent_question_query user_message then
        match most_recent with Some _ as x -> x | None -> best_match
      else best_match

let recall_fallback_reply
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(selected_question : string)
    ~(expected_topic : string option) : string =
  let ko =
    contains_korean_text user_message || contains_korean_text selected_question
  in
  if ko then
    let lead =
      match expected_topic with
      | Some "first_question" -> "내 기록상 가장 처음 물어본 건 이거야:"
      | Some "weather" -> "내 기록에 남아있는 날씨 관련 질문은 이거야:"
      | _ -> "내 기록 기준으로는, 직전에 이런 질문을 했어:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: 회상 실패 시 저장된 질문 기록으로 자연스럽게 직접 응답\n\
       Next: 필요하면 첫 질문/직전 질문/주제별로 다시 좁혀서 조회\n\
       Decisions: 회상 질의는 추측보다 저장된 사용자 질문 기록 우선\n\
       OpenQuestions: 없음\n\
       Constraints: 저장된 대화 기록 범위 밖으로는 추측하지 않음\n\
       [/STATE]"
      lead selected_question meta.goal
  else
    let lead =
      match expected_topic with
      | Some "first_question" -> "From stored history, your earliest question was:"
      | Some "weather" -> "From stored history, your weather-related question was:"
      | _ -> "From stored history, your previous question was:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: Returned a deterministic recall answer from stored user messages\n\
       Next: Narrow to earliest/most-recent/topic-specific question if needed\n\
       Decisions: For recall queries, prefer stored user-message evidence over generation\n\
       OpenQuestions: none\n\
       Constraints: Do not infer outside stored conversation history\n\
       [/STATE]"
      lead selected_question meta.goal

let deterministic_recall_fallback
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(eval : memory_recall_eval)
    ~(candidates : string list) : (string * memory_recall_eval) option =
  if (not eval.performed) || eval.passed || eval.candidate_count <= 0 then
    None
  else
    match
      select_recall_candidate ~user_message
        ~expected_topic:eval.expected_topic ~best_match:eval.best_match candidates
    with
    | None -> None
    | Some selected_question ->
        let forced_reply =
          recall_fallback_reply ~meta ~user_message ~selected_question
            ~expected_topic:eval.expected_topic
        in
        let eval2 =
          evaluate_memory_recall ~user_message ~assistant_reply:forced_reply
            ~candidates
        in
        Some (forced_reply, eval2)
