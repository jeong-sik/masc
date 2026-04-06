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

(** Ephemeral per-turn observers for tool call events.
    Each keeper registers its own observer via [add_tool_call_observer]
    and removes it via [remove_tool_call_observer].  Unlike wrapping
    [on_keeper_tool_call], observers are independent — concurrent keepers
    do not interfere with each other's save/restore lifecycle. *)
let tool_call_observers
  : (tool_name:string -> success:bool -> unit) list ref
  = ref []

let add_tool_call_observer fn =
  tool_call_observers := fn :: !tool_call_observers

let remove_tool_call_observer fn =
  tool_call_observers := List.filter (fun f -> f != fn) !tool_call_observers

let notify_tool_call_observers ~tool_name ~success =
  List.iter (fun f -> f ~tool_name ~success) !tool_call_observers
;;

(** Callback for keeper_tool_search.  Process-global fallback; prefer
    passing [~search_fn] directly to [execute_keeper_tool_call] for
    session-scoped, race-free search.  Default: returns empty results. *)
let tool_search_fn
  : (query:string -> max_results:int -> Yojson.Safe.t) ref
  =
  ref (fun ~query:_ ~max_results:_ ->
    `Assoc [ ("results", `List []) ])
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

(** Delegate to [Keeper_exec_context.token_count] for consistent 15% safety
    buffer (#5053).  Previous inline version lacked the buffer, causing
    context_ratio in masc_status to be ~13% lower than the authoritative value. *)
let count_context_tokens (ctx : working_context) =
  Keeper_exec_context.token_count ctx
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

let max_suggested_entries = 12

let missing_file_error_json ~(config : Room.config) ~(target : string)
      ~(error : string) =
  let project_root = Keeper_alerting_path.project_root_of_config config in
  let parent = Filename.dirname target in
  let suggestion_dir =
    if Sys.file_exists parent && Sys.is_directory parent then parent else project_root
  in
  let suggested_entries =
    match Safe_ops.list_dir_safe suggestion_dir with
    | Ok entries -> entries |> List.sort String.compare |> take max_suggested_entries
    | Error _ -> []
  in
  let message =
    match suggested_entries with
    | [] -> error
    | entries ->
      Printf.sprintf "%s\nAvailable entries in %s: %s"
        error suggestion_dir (String.concat ", " entries)
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "error", `String message
        ; "path", `String target
        ; "suggestion_dir", `String suggestion_dir
        ; ( "suggested_entries"
          , `List (List.map (fun entry -> `String entry) suggested_entries) )
        ])
;;

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
    Log.Keeper.debug
      "keeper_board_post called by %s, raw args: %s"
      author
      (Yojson.Safe.to_string args);
    let board_args =
      ensure_keeper_board_post_args
        ~author
        ~source:"keeper_board_post"
        (assoc_override_string "author" author args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.to_string board_args);
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
     | Error e when String.starts_with ~prefix:"File not found:" e ->
       missing_file_error_json ~config ~target ~error:e
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
       Log.Keeper.info "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
         meta.name target (if mode = "" then "overwrite" else mode)
         (String.length content);
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
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec =
    Safe_ops.json_float ~default:30.0 "timeout_sec" args |> fun n -> max 1.0 (min 180.0 n)
  in
  (* Coding/Full presets allow write operations and relaxed metachar rules *)
  let write_enabled =
    match meta.tool_access with
    | Preset { preset = Coding; _ } | Preset { preset = Full; _ } -> true
    | _ -> false
  in
  if cmd = ""
  then error_json "cmd_required"
  else
    let validate =
      if write_enabled then Worker_dev_tools.validate_command_coding
      else Worker_dev_tools.validate_command
    in
    match validate cmd with
    | Error reason ->
      Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason cmd_for_log;
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "command_blocked"
            ; "reason", `String reason
            ])
    | Ok () ->
      (* Destructive guard: always active regardless of preset *)
      if Worker_dev_tools.is_destructive_bash_operation cmd
      then (
        Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "destructive_operation_blocked"
              ; ( "reason"
                , `String
                    "This command is destructive (force push, push to main, rm -rf, \
                     etc.) and is blocked for all presets." )
              ; "cmd", `String cmd_for_log
              ]))
      (* Write gate: only for non-coding presets *)
      else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
      then (
        Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s)" cmd_for_log meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "write_operation_gated"
              ; ( "reason"
                , `String
                    "This command modifies state (git push/commit, make deploy, etc.). \
                     Use a Coding preset keeper for write access." )
              ; "cmd", `String cmd_for_log
              ]))
      else (
        if write_enabled && Worker_dev_tools.is_write_operation cmd then
          Log.Keeper.info "WRITE_AUDIT: keeper=%s cmd=%s" meta.name cmd_for_log;
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
              ]))
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
    let st, out = Process_eio.run_argv_with_status ~timeout_sec:30.0 argv in
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
      ~cmd:"git -C <root> --no-optional-locks status --short --branch"
      [ "git"; "-C"; root; "--no-optional-locks"; "status"; "--short"; "--branch" ]
  | "ls" ->
    (match read_target () with
     | Error e -> error_json ~fields:[ "op", `String op ] e
     | Ok target ->
       let st, out =
         Process_eio.run_argv_with_status ~timeout_sec:30.0 [ "/bin/ls"; "-la"; target ]
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
      let preset_allows_workflow =
        match Keeper_types.tool_access_preset meta.tool_access with
        | Some (Coding | Full) -> true
        | _ -> false
      in
      if Worker_dev_tools.is_gh_dangerous_operation gh_raw
      then (
        Log.Keeper.info "keeper_github dangerous-gate: %s (keeper=%s)" gh_raw meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "dangerous_operation_gated"
              ; ( "reason"
                , `String
                    "This gh command performs an irreversible operation \
                     (delete/archive/transfer). Request operator approval." )
              ; "cmd", `String ("gh " ^ gh_raw)
              ]))
      else if (not preset_allows_workflow)
              && Worker_dev_tools.is_gh_workflow_operation gh_raw
      then (
        Log.Keeper.info "keeper_github workflow-gate: %s (keeper=%s, preset not coding/full)"
          gh_raw meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "workflow_operation_gated"
              ; ( "reason"
                , `String
                    "This gh command performs a workflow mutation \
                     (merge/close). Upgrade to coding or full preset, \
                     or request operator approval." )
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

(** keeper_pr_workflow — deterministic pipeline: worktree → write → git → PR.
    Reduces 4-step tool chain to a single call for 9B models that cannot
    reliably chain multi-step tool sequences. *)
let handle_keeper_pr_workflow
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args |> String.trim in
  let file_content = Safe_ops.json_string ~default:"" "file_content" args in
  let commit_message = Safe_ops.json_string ~default:"" "commit_message" args |> String.trim in
  let pr_title = Safe_ops.json_string ~default:"" "pr_title" args |> String.trim in
  let pr_body = Safe_ops.json_string ~default:"" "pr_body" args |> String.trim in
  let base_branch = Safe_ops.json_string ~default:"main" "base_branch" args |> String.trim in
  (* Validate required fields *)
  if branch = "" then error_json "branch_required"
  else if file_path = "" then error_json "file_path_required"
  else if commit_message = "" then error_json "commit_message_required"
  else if pr_title = "" then error_json "pr_title_required"
  else
    (* Check preset: requires delivery or coding *)
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_workflow requires delivery, coding, or full preset"
          ])
    else
      (* Sanitize branch/task_id: reject path traversal chars *)
      let safe_name s =
        String.to_seq s
        |> Seq.filter (fun c ->
          (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '/')
        |> String.of_seq
      in
      let branch_safe = safe_name branch in
      if branch_safe <> branch then
        error_json "branch_contains_invalid_chars"
      else
      let root = project_root_of_config config in
      let task_id = Printf.sprintf "pr-%s"
        (safe_name (String.sub branch 0 (min 20 (String.length branch)))) in
      let agent_name = Printf.sprintf "keeper-%s"
        (safe_name (strip_keeper_prefix meta.name)) in
      let steps = Buffer.create 512 in
      let step_ok = ref true in
      let step_error = ref "" in
      let run_step name f =
        if !step_ok then begin
          match f () with
          | Ok msg ->
            Buffer.add_string steps (Printf.sprintf "  %s: ok\n" name);
            Log.Keeper.info "pr_workflow step %s ok (keeper=%s)" name meta.name;
            Some msg
          | Error msg ->
            step_ok := false;
            step_error := Printf.sprintf "%s failed: %s" name msg;
            Buffer.add_string steps (Printf.sprintf "  %s: FAILED — %s\n" name msg);
            Log.Keeper.warn "pr_workflow step %s failed: %s (keeper=%s)" name msg meta.name;
            None
        end else None
      in
      (* Step 1: Create worktree *)
      let worktree_path = ref "" in
      let _s1 = run_step "worktree_create" (fun () ->
        match Room.worktree_create_r config ~agent_name ~task_id ~base_branch with
        | Ok msg ->
          (* Derive worktree path from known naming convention, then verify it exists *)
          let wt_dir = Filename.concat root
            (Printf.sprintf ".worktrees/%s-%s" agent_name task_id) in
          if Sys.file_exists wt_dir && Sys.is_directory wt_dir then begin
            worktree_path := wt_dir;
            Ok msg
          end else
            Error (Printf.sprintf "worktree created but path not found: %s" wt_dir)
        | Error e -> Error (Types.masc_error_to_string e)
      ) in
      (* Step 2: Write file — with path traversal guard *)
      let _s2 = run_step "file_write" (fun () ->
        if !worktree_path = "" then Error "no worktree path"
        else begin
          let abs_path = Filename.concat !worktree_path file_path in
          (* Resolve symlinks and normalize to catch ../.. traversal *)
          let canonical =
            try Some (Unix.realpath abs_path)
            with Unix.Unix_error _ ->
              (* File doesn't exist yet: check parent dir *)
              try
                let parent = Unix.realpath (Filename.dirname abs_path) in
                Some (Filename.concat parent (Filename.basename abs_path))
              with Unix.Unix_error _ -> None
          in
          match canonical with
          | None -> Error (Printf.sprintf "cannot resolve path: %s" file_path)
          | Some resolved ->
            if not (String.starts_with ~prefix:(!worktree_path ^ "/") resolved) then
              Error (Printf.sprintf "path escapes worktree boundary: %s" file_path)
            else begin
              try
                let dir = Filename.dirname resolved in
                Fs_compat.mkdir_p dir;
                Fs_compat.save_file resolved file_content;
                Ok (Printf.sprintf "wrote %d bytes to %s" (String.length file_content) file_path)
              with exn -> Error (Printexc.to_string exn)
            end
        end
      ) in
      (* Step 3: Git add + commit + push *)
      let _s3 = run_step "git_commit_push" (fun () ->
        if !worktree_path = "" then Error "no worktree path"
        else begin
          let run_git cmd =
            let shell = Printf.sprintf "cd %s && git %s 2>&1"
              (Filename.quote !worktree_path) cmd in
            Process_eio.run_argv_with_status ~timeout_sec:30.0
              [ "/bin/zsh"; "-lc"; shell ]
          in
          let st_add, out_add = run_git (Printf.sprintf "add %s" (Filename.quote file_path)) in
          if st_add <> Unix.WEXITED 0 then
            Error (Printf.sprintf "git add: %s" out_add)
          else begin
            let st_commit, out_commit = run_git
              (Printf.sprintf "commit -m %s" (Filename.quote commit_message)) in
            if st_commit <> Unix.WEXITED 0 then
              Error (Printf.sprintf "git commit: %s" out_commit)
            else begin
              let st_push, out_push = run_git
                (Printf.sprintf "push -u origin %s" (Filename.quote branch)) in
              if st_push <> Unix.WEXITED 0 then
                Error (Printf.sprintf "git push: %s" out_push)
              else
                Ok "committed and pushed"
            end
          end
        end
      ) in
      (* Step 4: Create draft PR — run from worktree for correct branch context *)
      let pr_url = ref "" in
      let _s4 = run_step "gh_pr_create" (fun () ->
        let body = if pr_body = "" then pr_title else pr_body in
        let gh_cmd = Printf.sprintf
          "cd %s && gh pr create --draft --title %s --body %s --base %s 2>&1"
          (Filename.quote !worktree_path) (Filename.quote pr_title) (Filename.quote body)
          (Filename.quote base_branch) in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:30.0
            [ "/bin/zsh"; "-lc"; gh_cmd ] in
        if st <> Unix.WEXITED 0 then
          Error (Printf.sprintf "gh pr create: %s" out)
        else begin
          pr_url := String.trim out;
          Ok (Printf.sprintf "PR created: %s" (String.trim out))
        end
      ) in
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool !step_ok
          ; "steps", `String (Buffer.contents steps)
          ; "pr_url", `String !pr_url
          ; "error", `String !step_error
          ; "keeper", `String meta.name
          ])
;;

let keeper_agent_sender ~(meta : keeper_meta) =
  Printf.sprintf "keeper-%s" (strip_keeper_prefix meta.name)

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

(* --- Memory bank search (structured notes from [STATE] blocks) --- *)

type memory_match = {
  kind: string;
  text: string;
  priority: int;
  generation: int;
  turn: int;
  ts: string;
  score: float;
}

let search_memory_bank
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(kind_filter : string)
      ~(limit : int) : memory_match list * int =
  let path = keeper_memory_bank_path config meta.name in
  let lines = read_file_tail_lines path ~max_bytes:(256 * 1024) ~max_lines:500 in
  let now_ts = Time_compat.now () in
  let parsed =
    lines
    |> List.filter_map (fun line ->
         try
           let j = Yojson.Safe.from_string line in
           let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
           let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let generation = Safe_ops.json_int ~default:0 "generation" j in
           let turn = Safe_ops.json_int ~default:0 "turn" j in
           let ts = Safe_ops.json_string ~default:"" "ts" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           if kind = "" || text = "" then None
           else Some { kind; text; priority; generation; turn; ts; score = ts_unix }
         with Yojson.Json_error _ -> None)
  in
  let total_candidates = List.length parsed in
  (* Structured filter: kind (deterministic) *)
  let filtered =
    if kind_filter = "" then parsed
    else List.filter (fun m -> String.lowercase_ascii m.kind = String.lowercase_ascii kind_filter) parsed
  in
  (* Text match: query against text field (non-deterministic data) *)
  let matched =
    if query = "" then filtered
    else List.filter (fun m -> contains_ci m.text query) filtered
  in
  (* Scoring: priority * recency_weight.
     recency_weight normalizes age relative to the oldest note in the result set.
     No hardcoded decay constant — uses min/max normalization. *)
  let ts_values = List.map (fun m -> m.score) matched in
  let min_ts =
    match ts_values with
    | [] -> now_ts
    | ts :: rest -> List.fold_left min ts rest
  in
  let max_age = max 1.0 (now_ts -. min_ts) in
  let scored =
    matched
    |> List.map (fun m ->
         let age = max 0.0 (now_ts -. m.score) in
         let recency_weight =
           max 0.0 (min 1.0 (1.0 -. (0.3 *. (age /. max_age))))
         in
         let synthetic_penalty =
           if contains_ci m.text "[SYNTHETIC]" then -0.1 else 0.0
         in
         let score =
           (float_of_int m.priority /. 100.0) *. recency_weight +. synthetic_penalty
         in
         let rounded = Float.round (score *. 1000.0) /. 1000.0 in
         { m with score = rounded })
  in
  let sorted =
    scored
    |> List.sort (fun a b -> Float.compare b.score a.score)
    |> take limit
  in
  (sorted, total_candidates)

let memory_match_to_json (m : memory_match) : Yojson.Safe.t =
  `Assoc [
    "kind", `String m.kind;
    "text", `String m.text;
    "priority", `Int m.priority;
    "generation", `Int m.generation;
    "turn", `Int m.turn;
    "ts", `String m.ts;
    "score", `Float m.score;
  ]

(* --- History search (cross-generation, retained for backward compat) --- *)

let search_history
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(query : string)
      ~(limit : int) : string list =
  let current_history =
    load_history_user_messages
      ~path:(keeper_history_path config meta.runtime.trace_id)
      ~max_n:50
  in
  let prev_history =
    meta.runtime.trace_history
    |> List.concat_map (fun old_trace_id ->
         load_history_user_messages
           ~path:(keeper_history_path config old_trace_id)
           ~max_n:20)
  in
  let checkpoint_user_msgs =
    recent_user_messages ctx_work.messages ~max_n:100
  in
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  List.iter (fun s -> Hashtbl.replace seen (key_of s) ()) checkpoint_user_msgs;
  let dedup lst =
    List.filter (fun s ->
      let k = key_of s in
      if Hashtbl.mem seen k then false
      else (Hashtbl.replace seen k (); true)) lst
  in
  let all_candidates =
    checkpoint_user_msgs
    @ dedup current_history
    @ dedup prev_history
  in
  all_candidates
  |> List.filter (fun msg -> query <> "" && contains_ci msg query)
  |> List.rev
  |> take limit

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_json
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t) =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  let source = Safe_ops.json_string ~default:"memory" "source" args |> String.trim in
  let kind_filter = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
  let result =
    match source with
    | "history" ->
      let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map (fun msg -> `String msg) matches in
      `Assoc ([
        "query", `String query;
        "source", `String "history";
        "match_count", `Int (List.length matches);
        "matches", `List match_jsons;
      ] @ (if no_match then [ "no_match", `Bool true ] else []))
    | "all" ->
      let (bank_matches, bank_total) =
        search_memory_bank ~config ~meta ~query ~kind_filter ~limit
      in
      let history_limit = max 0 (limit - List.length bank_matches) in
      let history_matches =
        if history_limit > 0
        then search_history ~config ~meta ~ctx_work ~query ~limit:history_limit
        else []
      in
      let total_matches = List.length bank_matches + List.length history_matches in
      let no_match = total_matches = 0 in
      let bank_jsons = List.map memory_match_to_json bank_matches in
      let history_jsons = List.map (fun msg ->
        `Assoc [ "source", `String "history"; "text", `String msg ]
      ) history_matches in
      `Assoc ([
        "query", `String query;
        "source", `String "all";
        "total_candidates", `Int bank_total;
        "match_count", `Int total_matches;
        "matches", `List (bank_jsons @ history_jsons);
      ] @ (if no_match then [ "no_match", `Bool true ] else []))
    | _ (* "memory" *) ->
      let (matches, total_candidates) =
        search_memory_bank ~config ~meta ~query ~kind_filter ~limit
      in
      let no_match = matches = [] in
      let match_jsons = List.map memory_match_to_json matches in
      `Assoc ([
        "query", `String query;
        "source", `String "memory";
        "total_candidates", `Int total_candidates;
        "match_count", `Int (List.length matches);
        "matches", `List match_jsons;
      ] @ (if no_match then [ "no_match", `Bool true ] else [])
      @ (if kind_filter <> "" then [ "kind_filter", `String kind_filter ] else []))
  in
  (* Day-1 search logging: append search event to decisions log.
     Extract match_count and top_score from the already-computed result. *)
  let log_match_count =
    match result with
    | `Assoc fields -> (match List.assoc_opt "match_count" fields with
      | Some (`Int n) -> n | _ -> 0)
    | _ -> 0
  in
  let log_top_score =
    match result with
    | `Assoc fields -> (match List.assoc_opt "matches" fields with
      | Some (`List (first :: _)) ->
        (match first with
         | `Assoc mfields -> (match List.assoc_opt "score" mfields with
           | Some (`Float s) -> Some s | _ -> None)
         | _ -> None)
      | _ -> None)
    | _ -> None
  in
  (try
    let log_entry = `Assoc ([
      "ts_unix", `Float (Time_compat.now ());
      "event", `String "memory_search";
      "query", `String query;
      "source", `String source;
      "kind_filter", `String kind_filter;
      "match_count", `Int log_match_count;
    ] @ (match log_top_score with
         | Some s -> [ "top_score", `Float s ]
         | None -> [])) in
    append_jsonl_line (keeper_decision_log_path config meta.name) log_entry
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
  Yojson.Safe.to_string result
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
    let action_hint =
      if orphans = [] then
        "ACTION: STOP calling keeper_tasks_audit — no orphans found. Move on to other work or end your turn."
      else
        Printf.sprintf "ACTION: %d orphan(s) found. Use keeper_task_force_release or keeper_task_force_done to resolve, then STOP re-auditing."
          (List.length orphans)
    in
    Yojson.Safe.to_string
      (`Assoc [ "orphan_count", `Int (List.length orphans); "orphans", `List items;
                "action", `String action_hint ])
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
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let args = input in
  let now_ts = Time_compat.now () in
  let lookup = tool_access_lookup_of_meta meta in
  if not (can_execute ~lookup name)
  then
    (* Samchon verification loop: structured rejection with actionable
       guidance so the LLM can self-correct on the next attempt. *)
    let reason =
      if not (Hashtbl.mem lookup.candidate_set name)
      then "not_in_candidate_set"
      else if Hashtbl.mem lookup.deny_set name
      then "denied_by_policy"
      else "not_in_allow_set"
    in
    Yojson.Safe.to_string
      (`Assoc [
        ("error", `String "tool_not_allowed");
        ("tool", `String name);
        ("reason", `String reason);
        ("hint", `String "Use keeper_tool_search to find allowed alternatives.");
      ])
  else (
    match name with
    | "keeper_tool_search" ->
      let query =
        Safe_ops.json_string ~default:"" "query" args |> String.trim
      in
      let max_results =
        min 10 (max 1 (Safe_ops.json_int ~default:5 "max_results" args))
      in
      if query = "" then
        error_json "query is required"
      else
        let fn = match search_fn with
          | Some f -> f
          | None -> !tool_search_fn
        in
        Yojson.Safe.to_string (fn ~query ~max_results)
    | "keeper_tools_list" -> keeper_tools_list_json ~meta
    | "keeper_time_now" ->
      Yojson.Safe.to_string
        (`Assoc [ "now_iso", `String (now_iso ()); "now_unix", `Float now_ts ])
    | "keeper_context_status" -> keeper_context_status_json ~meta ~ctx_work
    | "keeper_memory_search" -> keeper_memory_search_json ~config ~meta ~ctx_work ~args
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
    | "keeper_pr_workflow" -> handle_keeper_pr_workflow ~config ~meta ~args
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
      (* Hallucination recovery: suggest similar tools via fuzzy match *)
      let suggestion =
        let candidates = keeper_allowed_tool_names meta in
        let scored =
          candidates
          |> List.filter_map (fun c ->
            if String.length c > 2 && String.length other > 2 then
              (* Simple substring containment as fast heuristic *)
              let other_lower = String.lowercase_ascii other in
              let c_lower = String.lowercase_ascii c in
              let contains haystack needle =
                let nlen = String.length needle in
                let hlen = String.length haystack in
                if nlen = 0 then true
                else if nlen > hlen then false
                else
                  let found = ref false in
                  for i = 0 to hlen - nlen do
                    if not !found
                       && String.sub haystack i nlen = needle
                    then found := true
                  done;
                  !found
              in
              if contains c_lower other_lower
                 || contains other_lower c_lower
              then Some c
              else None
            else None)
          |> List.filteri (fun i _ -> i < 3)
        in
        scored
      in
      (* Samchon verification loop: include schema for suggested tools
         so the LLM can self-correct in one step, not two. *)
      let masc_schemas = !masc_schemas_ref in
      let enrich_suggestion name =
        let schema_opt =
          List.find_opt (fun (s : Types.tool_schema) -> s.name = name) masc_schemas
        in
        match schema_opt with
        | Some s ->
          `Assoc [
            ("name", `String name);
            ("description", `String s.description);
            ("input_schema", s.input_schema);
          ]
        | None -> `String name
      in
      let fields =
        [ ("error", `String "unknown_tool"); ("tool", `String other) ]
        @ (match suggestion with
           | [] -> [("hint", `String "Use keeper_tool_search to find available tools.")]
           | names ->
             [ ("did_you_mean", `List (List.map enrich_suggestion names));
               ("hint", `String "Call one of these tools with the correct parameters.") ])
      in
      Yojson.Safe.to_string (`Assoc fields))
;;

(* keeper_tool_loop_system_prompt and keeper_tool_followup_prompt removed:
   Agent.run() handles tool dispatch and follow-up natively. *)
