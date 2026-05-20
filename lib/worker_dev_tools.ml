(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec uses Eio.Process with fiber-based timeout.

    Safety classification types (destructive_class, gate_diff, etc.) are
    defined in [Gate_diff_types] and re-exported here for backward compat. *)

include Gate_diff_types
module Paths = Worker_dev_tools_paths
module Log_sanitize = Worker_dev_tools_log_sanitize
module Command_syntax = Worker_dev_tools_command_syntax
module Mutation_classifier = Worker_dev_tools_mutation_classifier
module Path_validation = Worker_dev_tools_path_validation

open Command_syntax

(* --- Safety validation --- *)

let normalize_path = Paths.normalize_path
let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

let tool_error ?(recoverable = false) message : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class = None }
;;

(** shell_exec intentionally supports only a narrow allowlist of dev/test
    commands and rejects shell control syntax to keep execution predictable.

    RFC-0091 PR-1: allowlist tables moved to {!Dev_exec_allowlist}.  These
    bindings remain as in-module aliases until PR-2 deletes the legacy
    string-cmd lexer entirely and all callers reference the typed schema. *)
let dev_allowed_commands = Dev_exec_allowlist.dev
let readonly_allowed_commands = Dev_exec_allowlist.readonly

(** Error hint for a blocked command.

    A terse "'foo' is not allowed, allowed: git, rg..." drives the LLM
    to retry variants of foo, including OCaml/Python syntax fragments
    ('let', 'sort', 'Keeper_agent_run.build_ctx_composition', etc.) —
    live log 2026-04-16 shows 12+ retries per ~3MB.

    Give the LLM an actionable nudge based on what it probably tried:
      - OCaml/Python identifier → redirect to code tools
      - common shell command we don't allow (sort, awk) → name the
        supported alternative (rg/jq)
      - everything else → plain allowlist

    The helper is a pure function of the tried command name and the
    optional caller-specific allowlist. *)
let default_common_allowed_commands_hint =
  "scripts/dune-local.sh, git, rg, ls, cat, head, tail, grep, find, make, node, npm, \
   python3, pytest, cargo, go"
;;

let allowed_commands_hint = function
  | [] -> "(none)"
  | commands -> String.concat ", " commands
;;

let command_blocked_hint ?allowed_commands name =
  let looks_like_source_code s =
    (* Contains '.' at a non-boundary position (A.B), or starts with a
       reserved OCaml keyword that no shell command uses. *)
    (match String.index_opt s '.' with
     | Some i -> i > 0 && i < String.length s - 1
     | None -> false)
    || List.mem
         s
         [ "let"
         ; "match"
         ; "if"
         ; "then"
         ; "else"
         ; "fun"
         ; "rec"
         ; "in"
         ; "module"
         ; "open"
         ; "type"
         ; "def"
         ; "class"
         ; "import"
         ; "from"
         ]
  in
  let alt =
    match name with
    | "sort" | "uniq" -> " Use rg or jq for filtering."
    | "sed" | "awk" -> " Use keeper_fs_edit for in-place edits."
    | "find" -> " Use rg --files or masc_code_search."
    | "curl" | "wget" ->
      " Use masc_web_fetch to fetch page content, or masc_web_search to find sources."
    | "gh" ->
      " 'gh' is NOT available in the keeper sandbox. For pull-request work use \
       keeper_pr_list / keeper_pr_status / keeper_pr_create / keeper_pr_review_read / \
       keeper_pr_review_comment. For issues use masc_board_list / masc_board_post / \
       masc_board_comment. For commits or branches just use 'git' directly — it is on \
       the allowlist."
    | "docker"
    | "podman"
    | "kubectl"
    | "systemctl"
    | "brew"
    | "apt"
    | "apt-get"
    | "yum"
    | "dnf" ->
      Printf.sprintf
        " '%s' operates on host / cluster state and is deliberately excluded from the \
         keeper sandbox. If you need this operation, escalate to an operator via \
         masc_board_post instead of retrying."
        name
    | "ssh" | "scp" | "rsync" | "ftp" | "sftp" | "nc" ->
      Printf.sprintf
        " '%s' is a network primitive and is not permitted. Keeper network access goes \
         through masc_web_search, masc_web_fetch, or masc_autoresearch_* tools."
        name
    | _ when looks_like_source_code name ->
      " This looks like source code, not a shell command — use masc_code_edit / \
       masc_code_write / masc_code_read instead."
    | _ -> ""
  in
  let list_label, commands =
    match allowed_commands with
    | None -> "Common allowed commands", default_common_allowed_commands_hint
    | Some commands -> "Allowed commands for this tool", allowed_commands_hint commands
  in
  Printf.sprintf
    "Command blocked: '%s' is not allowed. %s: %s.%s See \
     keeper_tools_list for the exhaustive tool surface, and keeper_fs_read / \
     keeper_fs_edit for file operations."
    name
    list_label
    commands
    alt
;;

type block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation
  | Command_not_allowed of string

let block_reason_to_string = function
  | Empty_command -> "command must not be empty"
  | Chain_or_redirect ->
    "Blocked: chaining (&&/||/;) and redirects (|/>) are not allowed. Run ONE command \
     per call. To change directory, use the `cwd` argument instead of `cd` — Good: \
     cwd='repos/masc-mcp', cmd='scripts/dune-local.sh build'. Bad:  cmd='cd repos/masc-mcp && dune \
     build'. For pipelines like `rg foo | wc -l`, run the primary command and process \
     output at the LLM layer. To write files, use keeper_fs_edit."
  | Injection ->
    "Shell injection syntax (;, &&, standalone &, `, $) not allowed. Run ONE command per \
     call. To change directory, use the `cwd` argument — Good: cwd='repos/masc-mcp', \
     cmd='scripts/dune-local.sh build'. Bad:  cmd='cd repos/masc-mcp && dune build' or cmd='cmd1 ; cmd2'. \
     Relative paths resolve from `cwd` (defaults to playground root). For file writes, \
     use keeper_fs_edit."
  | Process_substitution -> "Process substitution (<(...) or >(...)) is not allowed."
  | Unsafe_redirect ->
    "File redirects are not allowed. Only fd redirects like 2>&1 and \
     /dev/null sinks like 2>/dev/null are permitted."
  | Pipes_not_allowed -> "Pipes are not allowed. Run one command per call."
  | Direct_dune_invocation ->
    "Direct `dune` is blocked in local agent shells because it bypasses \
     scripts/dune-local.sh's machine-wide build lock and can trigger \
     host-wide ENFILE/EMFILE pressure. Use `scripts/dune-local.sh build ...` \
     from the repo root instead."
  | Command_not_allowed name -> command_blocked_hint name
;;

let block_reason_to_string_with_allowlist ~allowed_commands = function
  | Direct_dune_invocation -> block_reason_to_string Direct_dune_invocation
  | Command_not_allowed name -> command_blocked_hint ~allowed_commands name
  | reason -> block_reason_to_string reason
;;

let validate_command_with_allowlist ~allowed_commands cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else if Gh_command_validation.has_strict_shell_metachar trimmed
  then Error Chain_or_redirect
  else if invokes_direct_dune trimmed
  then Error Direct_dune_invocation
  else (
    match extract_command_name trimmed with
    | None -> Error Empty_command
    | Some name when List.mem name allowed_commands -> Ok ()
    | Some name -> Error (Command_not_allowed name))
;;

let validate_command ?caller:_ cmd =
  validate_command_with_allowlist ~allowed_commands:dev_allowed_commands cmd
;;

let first_disallowed_stage_bin ~allowed_commands stage_bins =
  List.find_opt
    (fun name -> not (List.exists (String.equal name) allowed_commands))
    stage_bins
;;

let validate_command_coding_parsed ~allow_pipes ~allowed_commands context =
  let stage_bins = context.Shell_command_gate.stage_bins in
  if (not allow_pipes) && Shell_command_gate.stage_count context > 1
  then Error Pipes_not_allowed
  else if List.exists (String.equal "dune") stage_bins
  then Error Direct_dune_invocation
  else (
    match first_disallowed_stage_bin ~allowed_commands stage_bins with
    | None -> Ok ()
    | Some name -> Error (Command_not_allowed name))
;;

(* RFC-0131 PR-5 — facade reject_reason → block_reason wire-shape
   mapping for the authority-flip path.  Exhaustive over the closed
   sum {!Shell_command_gate.reject_reason}; a new variant on the
   facade side forces an arm here at compile time.  Two arms collapse
   onto [Command_not_allowed]: facade carries stage-index detail the
   legacy [block_reason] did not expose, and the wire-shape contract
   (RFC-0131 §4.3 "preserving wire shape") forbids widening
   [block_reason] just for the flip path — PR-6 (legacy purge) is the
   correct place to revisit the surface. *)
let block_reason_of_reject : Shell_command_gate.reject_reason -> block_reason
  = function
  | Command_not_in_allowlist { bin } -> Command_not_allowed bin
  | Pipeline_segment_disallowed { bin; _ } -> Command_not_allowed bin
  | Pipes_not_allowed _ -> Pipes_not_allowed
  | Redirect_disallowed_in_caller _ -> Unsafe_redirect
;;

let validate_command_coding_with_allowlist
      ?caller
      ?(allow_pipes = true)
      ~(allowed_commands : string list)
      cmd
  =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then Error Empty_command
  else if has_coding_shell_injection_metachar trimmed
  then Error Injection
  else if has_process_substitution trimmed
  then Error Process_substitution
  else if has_unsafe_redirection trimmed
  then Error Unsafe_redirect
  else (
    (* Legacy verdict — direct [Result] now that the legacy_segments
       fallback has been removed (env/opam are already in
       [dev_allowed_commands]; the redundant [`Use_legacy_segments]
       branch and the regex segment validator were dropped — this PR).
       Parse failures conservatively map to [Error Injection] —
       unparseable input is treated as potentially unsafe. *)
    let legacy_result =
      match Shell_command_gate.parse ?caller trimmed with
      | Ok context ->
        validate_command_coding_parsed ~allow_pipes ~allowed_commands context
      | Error _ -> Error Injection
    in
    match caller with
    | None -> legacy_result
    | Some c ->
      (* RFC-0131 PR-5 — parallel facade call.  Emit is automatic via
         [Legendary_counters.incr_shell_gate] inside
         [Shell_command_gate.validate_allowlist] (RFC-0131 PR-3). *)
      let facade_verdict =
        Shell_command_gate.validate_allowlist
          ~caller:c
          ~allow_pipes
          ~allowed_commands
          trimmed
      in
      if Shell_gate_authority.authority_enabled c
      then (
        (* RFC-0131 §4.4 — facade verdict authoritative; legacy
           fallback only on [Cannot_parse] (parser coverage gap, which
           now itself yields [Error Injection]). *)
        match facade_verdict with
        | Allow _ -> Ok ()
        | Reject { reason; _ } -> Error (block_reason_of_reject reason)
        | Cannot_parse { kind = _ } -> legacy_result)
      else legacy_result)
;;

(** Relaxed command validation for Coding/Full preset keepers.
    Allows pipes and redirects; validates every command in the pipeline
    against [dev_allowed_commands]. *)
let validate_command_coding ?caller cmd =
  validate_command_coding_with_allowlist
    ?caller
    ~allow_pipes:true
    ~allowed_commands:dev_allowed_commands
    cmd
;;

let looks_like_url = Path_validation.looks_like_url
let is_path_flag = Path_validation.is_path_flag
let path_flag_requires_existing_dir = Path_validation.path_flag_requires_existing_dir
let path_value_of_flagged_token = Path_validation.path_value_of_flagged_token
let inline_path_flag_requires_existing_dir = Path_validation.inline_path_flag_requires_existing_dir
let command_materializes_path_arg = Path_validation.command_materializes_path_arg
let path_is_existing_dir = Path_validation.path_is_existing_dir
let looks_like_path_token = Path_validation.looks_like_path_token
let token_value_is_explicit_path = Path_validation.token_value_is_explicit_path
let token_has_parent_dir_segment = Path_validation.token_has_parent_dir_segment
let git_revisionish_token = Path_validation.git_revisionish_token
let token_has_unsafe_rewrite_syntax = Path_validation.token_has_unsafe_rewrite_syntax
let command_allows_safe_globbed_path = Path_validation.command_allows_safe_globbed_path
let token_glob_is_limited_to_basename = Path_validation.token_glob_is_limited_to_basename
let path_token_error_hint = Path_validation.path_token_error_hint
let path_syntax_blocked_message = Path_validation.path_syntax_blocked_message
let token_value_is_redirect_to_dev_null = Path_validation.token_value_is_redirect_to_dev_null
let token_value_is_redirect_op = Path_validation.token_value_is_redirect_op
let command_pattern_arg_flags = Path_validation.command_pattern_arg_flags
let token_is_inline_pattern_flag = Path_validation.token_is_inline_pattern_flag
let command_flag_pattern_arity = Path_validation.command_flag_pattern_arity
let rg_token_is_option_value = Path_validation.rg_token_is_option_value
let command_treats_plain_args_as_content = Path_validation.command_treats_plain_args_as_content
let path_argument_tokens = Path_validation.path_argument_tokens
let existing_dir_path_values = Path_validation.existing_dir_path_values
let validate_command_paths = Path_validation.validate_command_paths


(** Check if a command performs write/mutating operations.
    Returns [true] for commands like [git push], [git commit],
    [make deploy], [npm publish], [mv], [cp], etc.
    Read-only commands (git status, rg) return [false]. *)
let is_write_operation = Mutation_classifier.is_write_operation
let is_git_branch_switch = Mutation_classifier.is_git_branch_switch
let is_destructive_bash_operation = Mutation_classifier.is_destructive_bash_operation

let sanitize_command_for_log = Log_sanitize.sanitize_command_for_log
let truncate_for_log = Log_sanitize.truncate_for_log

(* --- gh CLI validation (extracted to Gh_command_validation) --- *)

include Gh_command_validation

(* --- Recursive mkdir --- *)

let mkdir_p path _perm = Fs_compat.mkdir_p path

(* Closed sum: five producer-emitted error categories. The closed type
   replaces the previous [Tool_exec_error_kind of string] wrapper —
   string values are only re-introduced at the telemetry wire via
   [tool_exec_error_kind_to_string].  Adding a new variant is a compile
   obligation at every observer call site below. *)
type tool_exec_error_kind =
  | Path_blocked
  | File_read_error
  | File_write_error
  | Command_blocked
  | Shell_error

let tool_exec_error_kind_to_string = function
  | Path_blocked -> "path_blocked"
  | File_read_error -> "file_read_error"
  | File_write_error -> "file_write_error"
  | Command_blocked -> "command_blocked"
  | Shell_error -> "shell_error"
;;

type tool_exec_observer =
  tool_name:string
  -> success:bool
  -> duration_ms:int
  -> ?error_kind:tool_exec_error_kind
  -> ?error_message:string
  -> unit
  -> unit

(* --- Tool implementations --- *)

(** [file_read] byte cap. Reads longer than this are truncated to prevent
    context overflow. SSOT for the limit, its display label, and the
    tool description shown to agents. *)
let file_read_max_bytes = 100_000

let file_read_max_label = "100KB"

let file_read_description =
  Printf.sprintf
    "Read file contents by absolute path. Returns file text. Use shell_exec with 'ls' \
     instead if you need directory listing. Maximum %s per read to prevent context \
     overflow."
    file_read_max_label
;;

let make_file_read ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_read"
    ~description:file_read_description
    ~parameters:
      [ { name = "path"
        ; description = "Absolute file path to read"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ]
    (fun input ->
       match Worker_tool_input.extract_string "path" input with
       | Error e -> tool_error e
       | Ok path ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path)
         then (
           let err =
             Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path; for_keeper_command = false }))
           in
           let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
           Option.iter
             (fun (f : tool_exec_observer) ->
                f
                  ~tool_name:"file_read"
                  ~success:false
                  ~duration_ms
                  ~error_kind:Path_blocked
                  ~error_message:err
                  ())
             on_exec;
           tool_error err)
         else (
           try
             let content = In_channel.with_open_text resolved_path In_channel.input_all in
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f ~tool_name:"file_read" ~success:true ~duration_ms ())
               on_exec;
             if String.length content > file_read_max_bytes
             then
               Ok
                 { Agent_sdk.Types.content =
                     String.sub content 0 file_read_max_bytes
                     ^ Printf.sprintf "\n[TRUNCATED at %s]" file_read_max_label
                 }
             else Ok { Agent_sdk.Types.content }
           with
           | Sys_error msg ->
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f
                    ~tool_name:"file_read"
                    ~success:false
                    ~duration_ms
                    ~error_kind:File_read_error
                    ~error_message:msg
                    ())
               on_exec;
             tool_error (Printf.sprintf "Cannot read: %s" msg)))
;;

let make_file_write ?workdir ?on_exec () =
  Agent_sdk.Tool.create
    ~name:"file_write"
    ~description:
      "Write content to a file by absolute path. Creates the file if it doesn't exist, \
       overwrites if it does. Creates parent directories. Use file_read first to check \
       existing content before overwriting."
    ~parameters:
      [ { name = "path"
        ; description = "Absolute file path to write"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ; { name = "content"
        ; description = "Content to write to the file"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ]
    (fun input ->
       match
         ( Worker_tool_input.extract_string "path" input
         , Worker_tool_input.extract_string "content" input )
       with
       | Error e, _ | _, Error e -> tool_error e
       | Ok path, Ok content ->
         let started = Time_compat.now () in
         let resolved_path = resolve_path ?base_dir:workdir path in
         if not (validate_path ?workdir path)
         then (
           let err =
             Keeper_path_check_error.(
               to_message
                 (Path_outside_whitelist
                    { path; for_keeper_command = false }))
           in
           let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
           Option.iter
             (fun (f : tool_exec_observer) ->
                f
                  ~tool_name:"file_write"
                  ~success:false
                  ~duration_ms
                  ~error_kind:Path_blocked
                  ~error_message:err
                  ())
             on_exec;
           tool_error err)
         else (
           try
             mkdir_p (Filename.dirname resolved_path) 0o755;
             Out_channel.with_open_text resolved_path (fun oc ->
               Out_channel.output_string oc content);
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f ~tool_name:"file_write" ~success:true ~duration_ms ())
               on_exec;
             Ok
               { Agent_sdk.Types.content =
                   Printf.sprintf
                     "Written %d bytes to %s"
                     (String.length content)
                     resolved_path
               }
           with
           | Sys_error msg ->
             let duration_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
             Option.iter
               (fun (f : tool_exec_observer) ->
                  f
                    ~tool_name:"file_write"
                    ~success:false
                    ~duration_ms
                    ~error_kind:File_write_error
                    ~error_message:msg
                    ())
               on_exec;
             tool_error (Printf.sprintf "Cannot write: %s" msg)))
;;

(* --- Attribution envelope conversion (Layer 1) ---
   Shell command validation is a Det policy gate. The 8 block_reason
   variants map uniformly to Policy_failed (no transition involved —
   this is a pre-execution allow/deny check).

   Defined before [make_shell_exec_with_allowlist] so the tool's
   validation callsite can record the attribution without forward
   referencing. *)

let block_reason_tag = function
  | Empty_command -> "empty_command"
  | Chain_or_redirect -> "chain_or_redirect"
  | Injection -> "injection"
  | Process_substitution -> "process_substitution"
  | Unsafe_redirect -> "unsafe_redirect"
  | Pipes_not_allowed -> "pipes_not_allowed"
  | Direct_dune_invocation -> "direct_dune_invocation"
  | Command_not_allowed _ -> "command_not_allowed"
;;

let attribution_of_validation ~cmd (result : (unit, block_reason) result) : Attribution.t =
  match result with
  | Ok () ->
    let evidence : Yojson.Safe.t = `Assoc [ "cmd", `String cmd ] in
    Attribution.passed ~origin:Det ~gate:"worker_dev_tools" ~evidence
  | Error br ->
    let command_name =
      match br with
      | Command_not_allowed name -> Some name
      | Direct_dune_invocation -> Some "dune"
      | _ -> None
    in
    let evidence : Yojson.Safe.t =
      `Assoc
        ([ "cmd", `String cmd; "block_reason", `String (block_reason_tag br) ]
         @
         match command_name with
         | Some n -> [ "command_name", `String n ]
         | None -> [])
    in
    Attribution.policy_failed
      ~origin:Det
      ~gate:"worker_dev_tools"
      ~evidence
      ~reason:(block_reason_to_string br)
;;

let make_shell_exec_with_allowlist
      ~workdir
      ~on_exec
      ~proc_mgr
      ~clock
      ~allowed_commands
      ~description
      ()
  =
  Agent_sdk.Tool.create
    ~name:"shell_exec"
    ~description
    ~parameters:
      [ { name = "command"
        ; description = "Shell command to execute"
        ; param_type = Agent_sdk.Types.String
        ; required = true
        }
      ; { name = "timeout_s"
        ; description = "Timeout in seconds (default 30, max 120)"
        ; param_type = Agent_sdk.Types.Number
        ; required = false
        }
      ]
    (fun input ->
       match Worker_tool_input.extract_string "command" input with
       | Error e -> tool_error e
       | Ok command ->
         let validation = validate_command_with_allowlist ~allowed_commands command in
         Dashboard_attribution.record (attribution_of_validation ~cmd:command validation);
         (match validation with
          | Error reason ->
            (* #13078: emit [command_blocked] telemetry so observers
               see validation failures.  Without this, the .mli's
               documented [command_blocked] error_kind never appears
               on the wire — operators can't distinguish "policy
               denied" from "no shell_exec attempt".  duration_ms = 0
               because no subprocess was spawned. *)
            Option.iter
              (fun (f : tool_exec_observer) ->
                 f
                   ~tool_name:"shell_exec"
                   ~success:false
                   ~duration_ms:0
                   ~error_kind:Command_blocked
                   ~error_message:(block_reason_to_string reason)
                   ())
              on_exec;
            tool_error (block_reason_to_string reason)
          | Ok () ->
            let timeout =
              Worker_tool_input.extract_float "timeout_s" input
              |> Option.value ~default:30.0
              |> Float.min 120.0
            in
            (try
               let started = Time_compat.now () in
               let record_result ?error_message result =
                 let duration_ms =
                   int_of_float ((Time_compat.now () -. started) *. 1000.0)
                 in
                 Option.iter
                   (fun (f : tool_exec_observer) ->
                      let success = Result.is_ok result in
                      if success
                      then f ~tool_name:"shell_exec" ~success:true ~duration_ms ()
                      else
                        f
                          ~tool_name:"shell_exec"
                          ~success:false
                          ~duration_ms
                          ~error_kind:Shell_error
                          ?error_message
                          ())
                   on_exec;
                 result
               in
               Tool_resource_gate.with_permit_raw
                 ~clock
                 ~tool_name:"shell_exec"
                 ~arguments:input
                 ~is_read_only:false
                 ~on_reject:(fun message ->
                   let message = "tool_resource_gate_saturated: " ^ message in
                   record_result
                     ~error_message:message
                     (tool_error ~recoverable:true message))
                 (fun () ->
                    let buf = Buffer.create 1024 in
                    let wrapped_command =
                      match workdir with
                      | Some dir when String.trim dir <> "" ->
                        Printf.sprintf "cd %s && %s" (Filename.quote dir) command
                      | _ -> command
                    in
                    let result =
                      try
                        let status, output =
                          Fd_accountant.with_slot ~kind:Sandbox_exec (fun () ->
                            Eio.Time.with_timeout_exn clock timeout (fun () ->
                              Eio.Switch.run
                              @@ fun sw ->
                              let stdout_r, stdout_w =
                                Eio.Process.pipe ~sw proc_mgr
                              in
                              let proc =
                                Eio.Process.spawn
                                  ~sw
                                  proc_mgr
                                  ~stdout:stdout_w
                                  [ "sh"; "-c"; wrapped_command ^ " 2>&1" ]
                              in
                              Eio.Flow.close stdout_w;
                              (try
                                 Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink buf);
                                 Eio.Flow.close stdout_r
                               with
                               | Eio.Cancel.Cancelled _ as e ->
                                 (try Eio.Flow.close stdout_r with
                                  | Eio.Cancel.Cancelled _ as ce -> raise ce
                                  | _ -> ());
                                 raise e);
                              let status = Eio.Process.await proc in
                              status, Buffer.contents buf))
                        in
                        match status with
                        | `Exited 0 -> Ok { Agent_sdk.Types.content = output }
                        | `Exited code ->
                          tool_error (Printf.sprintf "Exit code %d:\n%s" code output)
                        | `Signaled sig_num ->
                          tool_error
                            ~recoverable:(sig_num = Sys.sigterm)
                            (Printf.sprintf "Killed by signal %d:\n%s" sig_num output)
                      with
                      | Eio.Time.Timeout ->
                        let output = Buffer.contents buf in
                        tool_error
                          ~recoverable:true
                          (Printf.sprintf
                             "Timeout after %.0fs: %s\n%s"
                             timeout
                             command
                             output)
                    in
                    record_result result)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               let duration_ms = 0 in
               let exn_msg = Printexc.to_string exn in
               Option.iter
                 (fun (f : tool_exec_observer) ->
                    f
                      ~tool_name:"shell_exec"
                      ~success:false
                      ~duration_ms
                      ~error_kind:Shell_error
                      ~error_message:exn_msg
                      ())
                 on_exec;
               tool_error (Printf.sprintf "Command failed: %s" exn_msg))))
;;

let make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist
    ~workdir
    ~on_exec
    ~proc_mgr
    ~clock
    ~allowed_commands:dev_allowed_commands
    ~description:
      "Execute a shell command and return stdout+stderr. Timeout: 30s default, max 120s. \
       Use for: running tests, git commands, build tools, directory listing. Unlike \
       file_read (single file), this handles approved CLI operations. Commands run in \
       /bin/sh but shell control syntax is rejected."
    ()
;;

let make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock =
  make_shell_exec_with_allowlist
    ~workdir
    ~on_exec
    ~proc_mgr
    ~clock
    ~allowed_commands:readonly_allowed_commands
    ~description:
      "Execute a read-only shell command and return stdout+stderr. Timeout: 30s default, \
       max 120s. Use for search, inspection, and verification only. Write-oriented \
       commands are intentionally excluded."
    ()
;;

(** Create dev tools that close over Eio capabilities.
    Returns [file_read; file_write; shell_exec]. *)
let make_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ()
  ; make_file_write ?workdir ?on_exec ()
  ; make_shell_exec ~workdir ~on_exec ~proc_mgr ~clock
  ]
;;

let make_readonly_tools ~proc_mgr ~clock ?workdir ?on_exec () : Agent_sdk.Tool.t list =
  [ make_file_read ?workdir ?on_exec ()
  ; make_shell_exec_readonly ~workdir ~on_exec ~proc_mgr ~clock
  ]
;;

(* ================================================================ *)
(* Tick 12 (P5, reduced scope) — shadow AST parse observation.      *)
(*                                                                  *)
(* The existing regex allowlist ([validate_command] above) remains  *)
(* the authoritative gate.  This helper runs the typed bash parser  *)
(* (Masc_exec.Parser.Bash.parse_string) in parallel and maps the    *)
(* outcome to a coarse, stable tag string.  Callers that want to    *)
(* build prod observability can log the tag alongside the regex     *)
(* verdict; when the tag distribution has baked in (plan decision   *)
(* point 2: "N=1000 prod 호출 무결 후 flag 전환"), the gate can    *)
(* migrate in a follow-up without touching the regex layer.         *)
(*                                                                  *)
(* The helper never panics — the parser catches every Menhir/Lex    *)
(* exception internally and surfaces them via Parsed.t.             *)
(* ================================================================ *)

(* Typed parser outcome — primary classification surface.  String
   renderings exist only at log-emission boundaries via
   [Gate_diff_types.parse_outcome_kind_to_tag].  Downstream histogram
   dispatch (Legendary_counters) consumes the typed variant exhaustively
   so a new [Parsed.reason_too_complex] arm is a compile-time forcing
   function, not a silent "other"-bucket landing. *)
let shadow_parse_outcome_kind (cmd : string) : parse_outcome_kind =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed _ -> Parsed_simple
  | Masc_exec.Parsed.Parse_error _ -> Parse_error
  | Masc_exec.Parsed.Parse_aborted r -> Parse_aborted r
  | Masc_exec.Parsed.Too_complex r -> Too_complex r
;;

(* Stable string rendering of the parse outcome — retained for log
   emission and telemetry tags that already exist in operator
   dashboards. Computes via the typed kind so the wording cannot
   drift between this function and [Legendary_counters]. *)
let shadow_parse_outcome (cmd : string) : string =
  parse_outcome_kind_to_tag (shadow_parse_outcome_kind cmd)
;;

(* Legacy verdict ↔ shadow verdict cross-check.  Returns a tuple of
   legacy allow/deny + shadow kind, so telemetry can spot "legacy
   allows but shadow cannot parse" drift without needing two
   separate call sites.  Intentionally side-effect free. *)
let cross_check_command ~legacy cmd = legacy, shadow_parse_outcome_kind cmd

(* Classification functions that depend on worker_dev_tools internals
   (validate_command, shadow_parse_outcome_kind). Types come from
   Gate_diff_types via [include Gate_diff_types] at the top. *)

let classify_legacy cmd : legacy_verdict =
  match validate_command cmd with
  | Ok () ->
    (match Eval_gate.detect_destructive cmd with
     | Some (substring, _desc) -> Legacy_reject_destructive substring
     | None -> Legacy_allow)
  | Error _ -> Legacy_reject_by_allowlist
;;

let classify_shadow cmd : shadow_verdict =
  (* Destructive classifier runs on the raw string regardless of
     parser success — the substring catalogue does not need AST
     structure. This keeps the shadow path meaningful on commands
     the grammar has not yet upgraded to support. *)
  match classify_destructive cmd with
  | Some (cls, sub) -> Shadow_deny_destructive (cls, sub)
  | None ->
    (match shadow_parse_outcome_kind cmd with
     | Parsed_simple -> Shadow_allow
     | (Parse_error | Parse_aborted _ | Too_complex _) as kind ->
       Shadow_parse_unsupported { kind })
;;

let diff_command cmd : gate_diff * legacy_verdict * shadow_verdict =
  let legacy = classify_legacy cmd in
  let shadow = classify_shadow cmd in
  diff_of_verdicts ~legacy ~shadow, legacy, shadow
;;
