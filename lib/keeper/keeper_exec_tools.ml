(** Keeper_exec_tools — keeper tool execution and tool-loop helpers.

    Split into three layers:
    - [Keeper_tool_registry]: declarative tool name lists (data)
    - [Keeper_tool_policy]: access control, presets, allowed-tool resolution (logic)
    - This module: execution dispatch + shared helpers (side-effects) *)

open Keeper_types
open Keeper_memory
open Keeper_alerting

(* Re-export registry and policy so external callers keep using
   [Keeper_exec_tools.foo] without changing import paths. *)
include Keeper_tool_registry
include Keeper_tool_policy

(** Callback for recording keeper-internal tool calls.
    Set at server initialization to avoid Config dependency cycle.
    Default: no-op. Set to Tool_registry.record_call_if_known in mcp_server_eio.ml.

    Growth constraint: this callback is only invoked from
    [Keeper_tools_oas.make_tools], which iterates over
    [keeper_allowed_model_tools]. The set of recordable tool names
    is therefore bounded by the keeper's allowed tool list — not
    by arbitrary user input. *)
let on_keeper_tool_call
  : (tool_name:string -> success:bool -> duration_ms:int -> unit) ref
  =
  ref (fun ~tool_name:_ ~success:_ ~duration_ms:_ -> ())
;;

(** Tag-based dispatch callback for masc_* tools.
    Set at server initialization to Keeper_tag_dispatch.dispatch.
    Breaks the dependency cycle: keeper_exec_tools cannot import Tool_*
    modules directly because Config -> Operator_control -> Keeper_exec_tools
    creates a cycle with any Tool_* that depends on Config.

    Default: returns None (falls through to "unregistered" error).
    See: mcp_server_eio.ml initialization, #4579. *)
let tag_dispatch_fn
  : (config:Room.config
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> (bool * string) option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~tag:_ ~name:_ ~args:_ -> None)
;;

(** Estimate total token count for a working context (system prompt + messages).
    Mirrors [Keeper_exec_context.token_count] but avoids a dependency cycle. *)
let count_context_tokens (ctx : working_context) =
  Agent_sdk.Context_reducer.estimate_char_tokens ctx.system_prompt
  + List.fold_left
      (fun acc m -> acc + Agent_sdk.Context_reducer.estimate_message_tokens m)
      0
      ctx.messages
;;

let ensure_keeper_board_post_args ~author ~source = function
  | `Assoc fields ->
    let fields =
      List.filter (fun (k, _) -> k <> "author" && k <> "post_kind" && k <> "meta") fields
    in
    let has_hearth =
      List.exists
        (fun (k, v) ->
           k = "hearth"
           &&
           match v with
           | `String s -> String.trim s <> ""
           | _ -> false)
        fields
    in
    let fields =
      if has_hearth
      then fields
      else ("hearth", `String author) :: List.filter (fun (k, _) -> k <> "hearth") fields
    in
    `Assoc
      ([ "author", `String author
       ; "post_kind", `String "automation"
       ; "meta", `Assoc [ "source", `String source ]
       ]
       @ fields)
  | other -> other
;;

let keeper_text_fallback_json ~(agent_id : string) ~(message : string) =
  let voice = Voice_bridge.get_voice_for_agent agent_id in
  `Assoc
    [ "status", `String "text_fallback"
    ; "agent_id", `String agent_id
    ; "voice", `String voice
    ; "message_preview", `String (short_preview ~max_len:50 message)
    ]
;;

let shell_readonly_limit args =
  max 1 (min 200 (Safe_ops.json_int ~default:40 "limit" args))
;;

let shell_readonly_cat_max_bytes args =
  max 256 (min 100000 (Safe_ops.json_int ~default:4000 "max_bytes" args))
;;

let lines_to_json ?(limit = max_int) (text : string) : Yojson.Safe.t =
  let lines =
    String.split_on_char '\n' text
    |> List.filter (fun line -> line <> "")
    |> fun rows -> if List.length rows > limit then take limit rows else rows
  in
  `List (List.map (fun line -> `String line) lines)
;;

let error_json ?(fields = []) (message : string) =
  Yojson.Safe.to_string (`Assoc (("error", `String message) :: fields))
;;

let tool_result_or_error (ok, msg) = if ok then msg else error_json msg

let assoc_override_string (key : string) (value : string) = function
  | `Assoc fields ->
    let kept_fields = List.filter (fun (k, _) -> k <> key) fields in
    `Assoc ((key, `String value) :: kept_fields)
  | other -> other
;;

let keeper_effective_allowed_paths ~(meta : keeper_meta) =
  Keeper_alerting_path.effective_allowed_paths ~meta
;;

let resolve_keeper_path ~(config : Room.config) ~(meta : keeper_meta) ~(raw_path : string)
  =
  resolve_keeper_target_path
    ~config
    ~allowed_paths:(keeper_effective_allowed_paths ~meta)
    ~raw_path
;;

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error (Tool_board.handle_tool tool_name tool_args)
  in
  match name with
  | "keeper_board_post" ->
    let author = meta.name in
    Log.Keeper.info
      "keeper_board_post called by %s, raw args: %s"
      author
      (Yojson.Safe.to_string args);
    let board_args =
      ensure_keeper_board_post_args
        ~author
        ~source:"keeper_board_post"
        (assoc_override_string "author" author args)
    in
    Log.Keeper.info "board_args: %s" (Yojson.Safe.to_string board_args);
    let result = Tool_board.handle_tool "masc_board_post" board_args in
    let ok, msg = result in
    Log.Keeper.info
      "handle_tool result: ok=%b msg=%s"
      ok
      (if String.length msg > 200 then String.sub msg 0 200 ^ "..." else msg);
    tool_result_or_error result
  | "keeper_board_list" -> dispatch "masc_board_list" args
  | "keeper_board_get" -> dispatch "masc_board_get" args
  | "keeper_board_comment" ->
    dispatch "masc_board_comment" (assoc_override_string "author" meta.name args)
  | "keeper_board_vote" ->
    dispatch "masc_board_vote" (assoc_override_string "voter" meta.name args)
  | "keeper_board_stats" -> dispatch "masc_board_stats" args
  | "keeper_board_search" -> dispatch "masc_board_search" args
  | "keeper_board_delete" -> dispatch "masc_board_delete" args
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_board_tool"
;;

let handle_keeper_fs_read
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:20000 "max_bytes" args |> fun n -> max 512 (min 200000 n)
  in
  match resolve_keeper_path ~config ~meta ~raw_path:path with
  | Error e -> error_json e
  | Ok target ->
    (match Safe_ops.read_file_safe target with
     | Error e -> error_json ~fields:[ "path", `String target ] e
     | Ok content ->
       let total = String.length content in
       let truncated = total > max_bytes in
       let body = if truncated then String.sub content 0 max_bytes else content in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "bytes", `Int total
             ; "truncated", `Bool truncated
             ; "content", `String body
             ]))
;;

let handle_keeper_fs_edit
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let mode =
    Safe_ops.json_string ~default:"overwrite" "mode" args |> String.lowercase_ascii
  in
  match resolve_keeper_path ~config ~meta ~raw_path:path with
  | Error e -> error_json e
  | Ok target ->
    (try
       let parent = Filename.dirname target in
       Fs_compat.mkdir_p parent;
       (match mode with
        | "append" -> Fs_compat.append_file target content
        | "overwrite" | "" -> Fs_compat.save_file target content
        | other -> raise (Invalid_argument ("unsupported_mode:" ^ other)));
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "mode", `String (if mode = "" then "overwrite" else mode)
             ; "bytes_written", `Int (String.length content)
             ])
     with
     | Invalid_argument e -> error_json ~fields:[ "path", `String target ] e
     | Sys_error e -> error_json ~fields:[ "path", `String target ] e
     | Unix.Unix_error (err, _, _) ->
       error_json ~fields:[ "path", `String target ] (Unix.error_message err))
;;

let handle_keeper_bash
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let timeout_sec =
    Safe_ops.json_float ~default:30.0 "timeout_sec" args |> fun n -> max 1.0 (min 180.0 n)
  in
  if cmd = ""
  then error_json "cmd_required"
  else (
    match Worker_dev_tools.validate_command cmd with
    | Error reason ->
      Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason cmd;
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "command_blocked"
            ; "reason", `String reason
            ])
    | Ok () ->
      if Worker_dev_tools.is_write_operation cmd
      then (
        Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s)" cmd meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "write_operation_gated"
              ; ( "reason"
                , `String
                    "This command modifies state (git push/commit, make deploy, etc.). \
                     Use keeper_shell_readonly for read operations, or request \
                     shell_mode=coding policy from the operator." )
              ; "cmd", `String cmd
              ]))
      else (
        let root = project_root_of_config config in
        let shell_cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) cmd in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec [ "/bin/bash"; "-lc"; shell_cmd ]
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "status", process_status_to_json st
              ; "output", `String (truncate_tool_output out)
              ])))
;;

let handle_keeper_shell_readonly
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let op =
    Safe_ops.json_string ~default:"" "op" args |> String.trim |> String.lowercase_ascii
  in
  let root = project_root_of_config config in
  let read_target () =
    let raw_path = Safe_ops.json_string ~default:"." "path" args in
    resolve_keeper_path ~config ~meta ~raw_path
  in
  let render_process_result ~cmd argv =
    let st, out = Process_eio.run_argv_with_status ~timeout_sec:15.0 argv in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool (st = Unix.WEXITED 0)
          ; "op", `String op
          ; "cmd", `String cmd
          ; "status", process_status_to_json st
          ; "output", `String (truncate_tool_output out)
          ])
  in
  match op with
  | "pwd" -> render_process_result ~cmd:"pwd" [ "/bin/pwd" ]
  | "git_status" ->
    render_process_result
      ~cmd:"git -C <root> status --short --branch"
      [ "git"; "-C"; root; "status"; "--short"; "--branch" ]
  | "ls" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:15.0 [ "/bin/ls"; "-la"; target ]
       in
       let limit = shell_readonly_limit args in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "status", process_status_to_json st
             ; "entries", lines_to_json ~limit out
             ]))
  | "cat" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let max_bytes = shell_readonly_cat_max_bytes args in
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:15.0 [ "/bin/cat"; target ]
       in
       let body =
         if String.length out > max_bytes then String.sub out 0 max_bytes else out
       in
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool (st = Unix.WEXITED 0)
             ; "op", `String op
             ; "path", `String target
             ; "status", process_status_to_json st
             ; "truncated", `Bool (String.length out > max_bytes)
             ; "content", `String body
             ]))
  | "rg" ->
    let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern_required"
    else (
      match read_target () with
      | Error e -> error_json ~fields:[ "op", `String op ] e
      | Ok target ->
        let limit = shell_readonly_limit args in
        let st, out =
          Process_eio.run_argv_with_status
            ~timeout_sec:15.0
            [ "rg"; "-n"; "-m"; string_of_int limit; pattern; target ]
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "op", `String op
              ; "path", `String target
              ; "pattern", `String pattern
              ; "status", process_status_to_json st
              ; "matches", lines_to_json ~limit out
              ]))
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
            , `List
                (List.map
                   (fun name -> `String name)
                   [ "pwd"; "ls"; "cat"; "rg"; "git_status" ]) )
          ])
;;

let handle_keeper_github
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let gh_args = Safe_ops.json_string_list "args" args in
  let timeout_sec =
    Safe_ops.json_float ~default:30.0 "timeout_sec" args |> fun n -> max 1.0 (min 180.0 n)
  in
  let gh_raw =
    if cmd <> "" then cmd else if gh_args <> [] then String.concat " " gh_args else ""
  in
  if gh_raw = ""
  then error_json "cmd_or_args_required"
  else (
    match Worker_dev_tools.validate_gh_command gh_raw with
    | Error reason ->
      Log.Keeper.warn "keeper_github blocked: %s (cmd=%s)" reason gh_raw;
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "command_blocked"
            ; "reason", `String reason
            ])
    | Ok () ->
      if Worker_dev_tools.is_gh_destructive_operation gh_raw
      then (
        Log.Keeper.info "keeper_github destructive-gate: %s (keeper=%s)" gh_raw meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "destructive_operation_gated"
              ; ( "reason"
                , `String
                    "This gh command performs a destructive mutation \
                     (merge/close/delete/archive). Use read-only commands \
                     (view/list/diff/checks) or request operator approval." )
              ; "cmd", `String ("gh " ^ gh_raw)
              ]))
      else (
        let gh_cmd =
          if cmd <> ""
          then "gh " ^ cmd
          else "gh " ^ String.concat " " (List.map Filename.quote gh_args)
        in
        let root = project_root_of_config config in
        let shell_cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) gh_cmd in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec [ "/bin/zsh"; "-lc"; shell_cmd ]
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "status", process_status_to_json st
              ; "output", `String (truncate_tool_output out)
              ])))
;;

let keeper_agent_sender ~(meta : keeper_meta) = Printf.sprintf "keeper-%s" meta.name

let keeper_tools_list_json ~(meta : keeper_meta) =
  let names = keeper_allowed_tool_names meta in
  let categorize n =
    if String.starts_with ~prefix:"keeper_board" n
    then "board"
    else if String.starts_with ~prefix:"keeper_voice" n
    then "voice"
    else if String.starts_with ~prefix:"keeper_task" n
    then "coordination"
    else if
      String.starts_with ~prefix:"keeper_shell" n
      || n = "keeper_bash"
      || n = "keeper_github"
    then "shell"
    else if
      String.starts_with ~prefix:"keeper_fs" n
      || String.starts_with ~prefix:"keeper_library" n
    then "filesystem"
    else if
      String.starts_with ~prefix:"masc_code" n
      || String.starts_with ~prefix:"masc_worktree" n
    then "coding"
    else if
      String.starts_with ~prefix:"masc_governance" n
      || String.starts_with ~prefix:"masc_petition" n
      || String.starts_with ~prefix:"masc_case" n
    then "governance"
    else if String.starts_with ~prefix:"masc_autoresearch" n
    then "autoresearch"
    else if String.starts_with ~prefix:"masc_" n
    then "masc_bridge"
    else if String.starts_with ~prefix:"keeper_" n
    then "base"
    else "other"
  in
  let groups : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun n ->
       let cat = categorize n in
       let prev =
         match Hashtbl.find_opt groups cat with
         | Some l -> l
         | None -> []
       in
       Hashtbl.replace groups cat (n :: prev))
    names;
  let entries =
    Hashtbl.fold
      (fun cat ns acc -> (cat, `List (List.rev_map (fun n -> `String n) ns)) :: acc)
      groups
      []
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "total", `Int (List.length names)
        ; ( "categories"
          , `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) entries) )
        ])
;;

let keeper_context_status_json ~(meta : keeper_meta) ~(ctx_work : working_context) =
  let continuity = latest_state_snapshot_from_messages ctx_work.messages in
  let continuity_summary =
    match continuity with
    | None ->
      let trimmed = String.trim meta.continuity_summary in
      if trimmed = "" then "No continuity snapshot available." else trimmed
    | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
  in
  let ctx_tokens = count_context_tokens ctx_work in
  let ctx_ratio =
    if ctx_work.max_tokens = 0
    then 0.0
    else float_of_int ctx_tokens /. float_of_int ctx_work.max_tokens
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "name", `String meta.name
        ; "trace_id", `String meta.runtime.trace_id
        ; "generation", `Int meta.runtime.generation
        ; "context_ratio", `Float ctx_ratio
        ; "context_tokens", `Int ctx_tokens
        ; "context_max", `Int ctx_work.max_tokens
        ; "message_count", `Int (List.length ctx_work.messages)
        ; "last_model_used", `String meta.runtime.usage.last_model_used
        ; ( "continuity_state"
          , match continuity with
            | None -> `Null
            | Some snapshot -> keeper_state_snapshot_to_json snapshot )
        ; "continuity_summary", `String continuity_summary
        ])
;;

let keeper_memory_search_json ~(ctx_work : working_context) ~(args : Yojson.Safe.t) =
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
        [ "query", `String query
        ; "match_count", `Int (List.length matches)
        ; "matches", `List matches
        ])
;;

let handle_keeper_voice_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match name with
  | "keeper_voice_speak" ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    let provider =
      Safe_ops.json_string_opt "provider" args
      |> Option.map String.trim
      |> function
      | Some p when p <> "" -> Some p
      | _ -> None
    in
    let priority = max 1 (Safe_ops.json_int ~default:1 "priority" args) in
    if message = ""
    then error_json "message_required"
    else (
      match
        ( Eio_context.get_switch_opt ()
        , Eio_context.get_clock_opt ()
        , Eio_context.get_net_opt () )
      with
      | Some sw, Some clock, Some net ->
        (match
           Voice_bridge.agent_speak
             ~sw
             ~clock
             ~net
             ~agent_id:meta.name
             ~message
             ?provider
             ~priority
             ()
         with
         | Ok json -> Yojson.Safe.to_string json
         | Error err ->
           Yojson.Safe.to_string
             (`Assoc
                 [ "status", `String "error"
                 ; "agent_id", `String meta.name
                 ; "message", `String err
                 ]))
      | _ ->
        Yojson.Safe.to_string (keeper_text_fallback_json ~agent_id:meta.name ~message))
  | "keeper_voice_listen" ->
    let timeout_sec = Safe_ops.json_float ~default:15.0 "timeout_seconds" args in
    let language_code = Safe_ops.json_string_opt "language_code" args in
    (match
       Voice_bridge.record_and_transcribe
         ~agent_id:meta.name
         ~timeout_sec
         ?language_code
         ()
     with
     | Ok json -> Yojson.Safe.to_string json
     | Error err ->
       Yojson.Safe.to_string
         (`Assoc
             [ "status", `String "error"
             ; "error", `String err
             ; "agent_id", `String meta.name
             ]))
  | "keeper_voice_agent" ->
    (match Voice_bridge.get_agent_voice ~agent_id:meta.name with
     | Ok json -> Yojson.Safe.to_string json
     | Error err ->
       Yojson.Safe.to_string
         (`Assoc
             [ "status", `String "error"
             ; "agent_id", `String meta.name
             ; "message", `String err
             ]))
  | "keeper_voice_sessions" ->
    let mgr = Keeper_voice_local.get_session_manager () in
    let sessions = Voice_session_manager.list_sessions mgr in
    Yojson.Safe.to_string
      (`Assoc
          [ "session_count", `Int (List.length sessions)
          ; "sessions", `List (List.map Voice_session_manager.session_to_json sessions)
          ])
  | "keeper_voice_session_start" ->
    let voice =
      Safe_ops.json_string_opt "session_name" args
      |> Option.map String.trim
      |> function
      | Some s when s <> "" -> Some s
      | _ -> None
    in
    let mgr = Keeper_voice_local.get_session_manager () in
    let session = Voice_session_manager.start_session mgr ~agent_id:meta.name ?voice () in
    Yojson.Safe.to_string (Voice_session_manager.session_to_json session)
  | "keeper_voice_session_end" ->
    let mgr = Keeper_voice_local.get_session_manager () in
    let ended = Voice_session_manager.end_session mgr ~agent_id:meta.name in
    Yojson.Safe.to_string
      (`Assoc
          [ "status", `String (if ended then "ended" else "no_active_session")
          ; "agent_id", `String meta.name
          ])
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_voice_tool"
;;

let keeper_task_result_json = function
  | Ok msg -> Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "result", `String msg ])
  | Error e ->
    Yojson.Safe.to_string
      (`Assoc [ "ok", `Bool false; "error", `String (Types.masc_error_to_string e) ])
;;

let handle_keeper_task_tool
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match name with
  | "keeper_tasks_list" ->
    let status_filter = Safe_ops.json_string_opt "status" args in
    let include_done = Safe_ops.json_bool ~default:false "include_done" args in
    Room.list_tasks ?status:status_filter ~include_done config
  | "keeper_tasks_audit" ->
    let orphans = Room.audit_orphan_tasks config in
    let items =
      List.map
        (fun (task, assignee) ->
           let task : Types.task = task in
           `Assoc
             [ "task_id", `String task.id
             ; "title", `String task.title
             ; "assignee", `String assignee
             ; "status", `String (Types.string_of_task_status task.task_status)
             ])
        orphans
    in
    Yojson.Safe.to_string
      (`Assoc [ "orphan_count", `Int (List.length orphans); "orphans", `List items ])
  | "keeper_task_force_release" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let reason = Safe_ops.json_string ~default:"" "reason" args in
    if task_id = ""
    then error_json "task_id required"
    else (
      let agent = keeper_agent_sender ~meta in
      let _ =
        Room.broadcast
          config
          ~from_agent:agent
          ~content:
            (Printf.sprintf
               "Force-releasing task %s (reason: %s)"
               task_id
               (if reason = "" then "no reason given" else reason))
      in
      keeper_task_result_json
        (Room.force_release_task_r config ~agent_name:agent ~task_id ()))
  | "keeper_task_force_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let notes = Safe_ops.json_string ~default:"" "notes" args in
    if task_id = ""
    then error_json "task_id required"
    else
      keeper_task_result_json
        (Room.force_done_task_r
           config
           ~agent_name:(keeper_agent_sender ~meta)
           ~task_id
           ~notes
           ())
  | "keeper_broadcast" ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    if message = ""
    then error_json "message required"
    else (
      let _ =
        Room.broadcast config ~from_agent:(keeper_agent_sender ~meta) ~content:message
      in
      Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "broadcast", `String message ]))
  | "keeper_task_claim" ->
    let result = Room.claim_next config ~agent_name:meta.agent_name in
    Yojson.Safe.to_string (`Assoc [ "result", `String result ])
  | "keeper_task_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    if task_id = ""
    then error_json "task_id required"
    else
      keeper_task_result_json
        (Room.force_done_task_r
           config
           ~agent_name:(keeper_agent_sender ~meta)
           ~task_id
           ~notes:(if result_text = "" then "" else result_text)
           ())
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_task_tool"
;;

let handle_keeper_autoresearch_tool
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let ctx : Tool_autoresearch.context =
    { base_path = project_root_of_config config
    ; agent_name = Some meta.name
    ; start_operation = None
    ; start_team_session = None
    ; config = Some config
    ; sw = None
    ; clock = None
    }
  in
  match Tool_autoresearch.dispatch ctx ~name ~args with
  | Some (true, msg) -> msg
  | Some (false, msg) -> error_json msg
  | None -> error_json ~fields:[ "tool", `String name ] "unknown_autoresearch_tool"
;;

let keeper_masc_path_blocked
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let effective_paths = keeper_effective_allowed_paths ~meta in
  if effective_paths = [] && meta.execution_scope <> "observe_only"
  then None
  else if meta.execution_scope = "observe_only" && effective_paths = []
  then (
    let has_path_arg =
      List.exists
        (fun key ->
           match Yojson.Safe.Util.member key args with
           | `String p when String.trim p <> "" -> true
           | _ -> false)
        [ "path"; "file_path"; "target_path" ]
    in
    if has_path_arg then Some "observe_only_scope: write paths blocked" else None)
  else (
    let candidates =
      List.filter_map
        (fun key ->
           match Yojson.Safe.Util.member key args with
           | `String p when String.trim p <> "" -> Some p
           | _ -> None)
        [ "path"; "file_path"; "target_path" ]
    in
    List.find_map
      (fun raw ->
         match
           resolve_keeper_target_path ~config ~allowed_paths:effective_paths ~raw_path:raw
         with
         | Error e -> Some e
         | Ok _ -> None)
      candidates)
;;

let handle_keeper_masc_tool
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match keeper_masc_path_blocked ~config ~meta ~args with
  | Some err -> error_json err
  | None ->
    (match Tool_dispatch.mint_token ~name with
     | Error reason ->
       Yojson.Safe.to_string
         (`Assoc
             [ "error", `String "unregistered_masc_tool"
             ; "tool", `String name
             ; "reason", `String reason
             ])
     | Ok token ->
       (match Tool_dispatch.dispatch ~token ~args with
        | Some (true, msg) -> msg
        | Some (false, msg) -> error_json msg
        | None ->
          if Tool_dispatch.is_mcp_context_required name
          then
            error_json
              (Printf.sprintf
                 "tool '%s' requires MCP session (use keeper_* equivalent)"
                 name)
          else (
            match Tool_dispatch.lookup_tag name with
            | Some tag ->
              let keeper_agent = keeper_agent_sender ~meta in
              (match
                 !tag_dispatch_fn ~config ~agent_name:keeper_agent ~tag ~name ~args
               with
               | Some (true, msg) -> msg
               | Some (false, msg) -> error_json msg
               | None ->
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "error", `String "tool_not_supported_in_keeper"
                       ; "tool", `String name
                       ; ( "hint"
                         , `String
                             "tag dispatch returned None; tool may be unsupported, \
                              blocked, or misconfigured" )
                       ]))
            | None ->
              Yojson.Safe.to_string
                (`Assoc
                    [ "error", `String "unregistered_masc_tool"; "tool", `String name ]))))
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(name : string)
      ~(input : Yojson.Safe.t)
  : string
  =
  let args = input in
  let now_ts = Time_compat.now () in
  let lookup = tool_access_lookup_of_meta meta in
  if not (can_execute ~lookup name)
  then
    Yojson.Safe.to_string
      (`Assoc [ "error", `String "tool_not_allowed"; "tool", `String name ])
  else (
    match name with
    | "keeper_tools_list" -> keeper_tools_list_json ~meta
    | "keeper_time_now" ->
      Yojson.Safe.to_string
        (`Assoc [ "now_iso", `String (now_iso ()); "now_unix", `Float now_ts ])
    | "keeper_context_status" -> keeper_context_status_json ~meta ~ctx_work
    | "keeper_memory_search" -> keeper_memory_search_json ~ctx_work ~args
    | "keeper_library_search" ->
      let ok, msg =
        Tool_library.handle_search Tool_library.{ agent_name = meta.name } args
      in
      if ok then msg else Yojson.Safe.to_string (`Assoc [ "error", `String msg ])
    | "keeper_library_read" ->
      let ok, msg =
        Tool_library.handle_read Tool_library.{ agent_name = meta.name } args
      in
      tool_result_or_error (ok, msg)
    | "keeper_board_post"
    | "keeper_board_list"
    | "keeper_board_get"
    | "keeper_board_comment"
    | "keeper_board_vote"
    | "keeper_board_stats"
    | "keeper_board_search"
    | "keeper_board_delete" -> handle_keeper_board_tool ~meta ~name ~args
    | "keeper_fs_read" -> handle_keeper_fs_read ~config ~meta ~args
    | "keeper_fs_edit" -> handle_keeper_fs_edit ~config ~meta ~args
    | "keeper_bash" -> handle_keeper_bash ~config ~meta ~args
    | "keeper_shell_readonly" -> handle_keeper_shell_readonly ~config ~meta ~args
    | "keeper_voice_speak"
    | "keeper_voice_listen"
    | "keeper_voice_agent"
    | "keeper_voice_sessions"
    | "keeper_voice_session_start"
    | "keeper_voice_session_end" -> handle_keeper_voice_tool ~meta ~name ~args
    | "keeper_github" -> handle_keeper_github ~config ~meta ~args
    | "keeper_tasks_list"
    | "keeper_tasks_audit"
    | "keeper_task_force_release"
    | "keeper_task_force_done"
    | "keeper_broadcast"
    | "keeper_task_claim"
    | "keeper_task_done" -> handle_keeper_task_tool ~config ~meta ~name ~args
    | name when String.starts_with ~prefix:"masc_autoresearch_" name ->
      handle_keeper_autoresearch_tool ~config ~meta ~name ~args
    | name when String.starts_with ~prefix:"masc_" name ->
      handle_keeper_masc_tool ~config ~meta ~name ~args
    | other ->
      Yojson.Safe.to_string
        (`Assoc [ "error", `String "unknown_tool"; "tool", `String other ]))
;;

(* keeper_tool_loop_system_prompt and keeper_tool_followup_prompt removed:
   Agent.run() handles tool dispatch and follow-up natively. *)
