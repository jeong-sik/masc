(** Development tools for autonomous agent coding.

    Provides file_read, file_write, shell_exec so Fleet agents
    can perform local development tasks (code generation, test runs,
    file modifications).

    file_read/file_write use OCaml stdlib (no Eio filesystem capability needed).
    shell_exec validates commands locally with the Shell IR gate and routes
    supported commands through Shell IR dispatch.

    Safety classification helpers are defined in [Shell_safety_types]
    and re-exported here for backward compat. *)

include Shell_safety_types
module Paths = Exec_policy_paths
module Exec_shell_gate = Masc_exec_command_gate.Shell_command_gate

(* --- Safety validation --- *)

let normalize_path = Paths.normalize_path
let resolve_path = Paths.resolve_path
let validate_path = Paths.validate_path

let tool_error ?(recoverable = false) message : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class = None }
;;

(** Shared execution policy lives in [Exec_policy].  [Worker_dev_tools]
    remains the Agent SDK file/shell tool bundle and re-exports this surface for
    compatibility with older call sites and tests. *)
let dev_allowed_commands = Exec_policy.dev_allowed_commands
let readonly_allowed_commands = Dev_exec_allowlist.readonly

type block_reason = Exec_policy.block_reason =
  | Empty_command
  | Chain_or_redirect
  | Injection
  | Process_substitution
  | Unsafe_redirect
  | Pipes_not_allowed
  | Direct_dune_invocation
  | Command_not_allowed of string

let block_reason_to_string = Exec_policy.block_reason_to_string
let block_reason_to_string_with_allowlist = Exec_policy.block_reason_to_string_with_allowlist
let command_context_with_allowlist = Exec_policy.command_context_with_allowlist
let validate_command_with_allowlist = Exec_policy.validate_command_with_allowlist
let validate_command = Exec_policy.validate_command
let command_context_coding_with_allowlist = Exec_policy.command_context_coding_with_allowlist
let validate_command_coding_with_allowlist = Exec_policy.validate_command_coding_with_allowlist
let validate_command_coding = Exec_policy.validate_command_coding
let simple_literal_args = Exec_policy.simple_literal_args
let existing_dir_path_values_of_shell_ir = Exec_policy.existing_dir_path_values_of_shell_ir
let validate_shell_ir_paths = Exec_policy.validate_shell_ir_paths

(* Pre-#18026 string-based validate_command_paths wrapper: parse [cmd]
   once via the Bash parser and delegate to [validate_shell_ir_paths].
   Live test caller: test/test_keeper_bash_safety.ml. *)
let validate_command_paths ?keeper_id ?base_path ?workdir cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir ->
    Exec_policy.validate_shell_ir_paths ?keeper_id ?base_path ?workdir ir
  | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _
  | Masc_exec.Parsed.Too_complex _ -> Ok ()
let is_write_operation = Exec_policy.is_write_operation
let is_git_branch_switch = Exec_policy.is_git_branch_switch
let is_destructive_bash_operation = Exec_policy.is_destructive_bash_operation
let flat_stage_words = Exec_policy.flat_stage_words
let sanitize_command_for_log = Exec_policy.sanitize_command_for_log
let truncate_for_log = Exec_policy.truncate_for_log
let block_reason_tag = Exec_policy.block_reason_tag
let attribution_of_validation = Exec_policy.attribution_of_validation
let block_reason_tag = Exec_policy.block_reason_tag
let attribution_of_validation = Exec_policy.attribution_of_validation

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

let simple_literal_argv (simple : Masc_exec.Shell_ir.simple) =
  match simple_literal_args simple with
  | None -> None
  | Some args -> Some (Masc_exec.Bin.to_string simple.Masc_exec.Shell_ir.bin :: args)
;;

let has_flag_prefix ~prefix args =
  List.exists (fun arg -> String.length arg >= String.length prefix
                          && String.sub arg 0 (String.length prefix) = prefix)
    args
;;

let is_recursive_scan_command bin args =
  match bin with
  | "find" -> true
  | "rg" -> true
  | "grep" ->
    List.exists
      (fun arg ->
         String.length arg >= 2
         && arg.[0] = '-'
         && (String.contains arg 'r' || String.contains arg 'R'))
      args
  | _ -> false
;;

let shell_exec_simple_timeout_floor (simple : Masc_exec.Shell_ir.simple) =
  let bin = Masc_exec.Bin.to_string simple.Masc_exec.Shell_ir.bin in
  match simple_literal_argv simple with
  | None -> None
  | Some (_ :: args) ->
    if String.equal bin "git"
       || String.equal bin "dune-local.sh"
       || has_flag_prefix ~prefix:"scripts/dune-local.sh" (bin :: args)
       || is_recursive_scan_command bin args
    then Some Timeout_floor.Tool_dispatch
    else None
  | Some [] -> None
;;

let rec shell_exec_timeout_floor = function
  | Masc_exec.Shell_ir.Simple simple -> shell_exec_simple_timeout_floor simple
  | Masc_exec.Shell_ir.Pipeline stages ->
    List.find_map shell_exec_timeout_floor stages
;;

let effective_shell_exec_timeout_sec_for_context ~requested context =
  match shell_exec_timeout_floor context.Exec_shell_gate.ast with
  | None -> requested
  | Some floor -> Timeout_floor.clamp floor requested
;;

let effective_shell_exec_timeout_sec ~command ~requested =
  let requested = Float.min 120.0 requested in
  match command_context_with_allowlist ~allowed_commands:dev_allowed_commands command with
  | Error _ -> requested
  | Ok context -> effective_shell_exec_timeout_sec_for_context ~requested context
;;

let make_shell_exec_with_allowlist
      ~workdir
      ~on_exec
      ~proc_mgr:_
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
         let command_context =
           command_context_with_allowlist ~allowed_commands command
         in
         let validation = Result.map (fun _ -> ()) command_context in
         Dashboard_attribution.record (Exec_policy.attribution_of_validation ~cmd:command validation);
         (match command_context with
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
          | Ok context ->
            let path_workdir =
              match workdir with
              | Some dir when String.trim dir <> "" -> dir
              | Some _ | None -> Sys.getcwd ()
            in
            (match
               validate_shell_ir_paths
                 ~workdir:path_workdir
                 context.Exec_shell_gate.ast
             with
             | Error message ->
               Option.iter
                 (fun (f : tool_exec_observer) ->
                    f
                      ~tool_name:"shell_exec"
                      ~success:false
                      ~duration_ms:0
                      ~error_kind:Path_blocked
                      ~error_message:message
                      ())
                 on_exec;
               tool_error message
             | Ok () ->
               let timeout =
                 Worker_tool_input.extract_float "timeout_s" input
                 |> Option.value ~default:30.0
                    (* DET-OK: fixed policy default for absent shell timeout. *)
                 |> Float.min 120.0
                 |> fun requested ->
                 effective_shell_exec_timeout_sec_for_context ~requested context
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
                       let cwd =
                         match workdir with
                         | Some dir when String.trim dir <> "" -> Some dir
                         | Some _ | None -> None
                       in
                       let result =
                         try
                           let dispatch_result =
                             Fd_accountant.with_slot ~kind:Sandbox_exec (fun () ->
                               let dispatch_ir =
                                 Exec_shell_adapter.shell_ir_with_default_cwd
                                   cwd
                                   context.Exec_shell_gate.ast
                               in
                               let dispatch_envelope =
                                 Masc_exec.Shell_ir_risk.classify
                                   (Masc_exec.Shell_ir_risk.undecided dispatch_ir)
                               in
                               Masc_exec.Exec_dispatch.dispatch_decided
                                 ~timeout_sec:timeout
                                 dispatch_envelope)
                           in
                           let output =
                             Exec_shell_adapter.output_for_dispatch_status
                               ~status:dispatch_result.status
                               ~stdout:dispatch_result.stdout
                               ~stderr:dispatch_result.stderr
                           in
                           match dispatch_result.status with
                           | Unix.WEXITED 0 -> Ok { Agent_sdk.Types.content = output }
                           | Unix.WEXITED 124 ->
                             tool_error
                               ~recoverable:true
                               (Printf.sprintf
                                  "Timeout after %.0fs: %s\n%s"
                                  timeout
                                  command
                                  output)
                           | Unix.WEXITED code ->
                             tool_error (Printf.sprintf "Exit code %d:\n%s" code output)
                           | Unix.WSIGNALED sig_num ->
                             tool_error
                               ~recoverable:(sig_num = Sys.sigterm)
                               (Printf.sprintf
                                  "Killed by signal %d:\n%s"
                                  sig_num
                                  output)
                           | Unix.WSTOPPED sig_num ->
                             tool_error
                               ~recoverable:true
                               (Printf.sprintf
                                  "Stopped by signal %d:\n%s"
                                  sig_num
                                  output)
                         with
                         | Eio.Time.Timeout ->
                           tool_error
                             ~recoverable:true
                             (Printf.sprintf "Timeout after %.0fs: %s\n%s" timeout command "")
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
                  tool_error (Printf.sprintf "Command failed: %s" exn_msg)))))
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
       file_read (single file), this handles approved CLI operations. Supported commands \
       run through Shell IR native dispatch; shell control syntax is rejected."
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
