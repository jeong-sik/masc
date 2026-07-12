open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

(* Typed declaration for pre-dispatch rejections (input parse/validation,
   Shell IR gate, path policy, approvals): caller-input and policy denials
   are Policy_rejection in the shared taxonomy (RFC-0062 §3.2). The OAS
   failure boundary reads this field; leaving it undeclared collapses these
   deterministic rejections into Runtime_failure -> error_class Unknown. *)
let policy_rejection_failure_class_fields =
  [ ( "failure_class"
    , `String (Tool_result.tool_failure_class_to_string Tool_result.Policy_rejection) )
  ]

type path_probe =
  { path_argument : string
  ; resolved_path : string
  ; parent_argument : string
  ; resolved_parent : string
  ; parent_exists : bool
  ; parent_is_directory : bool
  ; parent_within_cwd : bool
  ; wildcard_like : bool
  ; parent_entries : string list
  }

let path_probe_parent_entries_limit = 40

let path_components path =
  path
  |> String.split_on_char '/'
  |> List.filter (fun component -> String.trim component <> "")

(* The repos/ checkout root is part of the playground layout documented in
   [Config_dir_resolver] / [Keeper_tool_execute_path]. Keep the components
   here in sync with that SSOT: a cwd either at the repo clone
   (repos/<repo>) or inside a repo worktree (repos/<repo>/.worktrees/<task>)
   both resolve to the same prefix for path-argument rewriting. *)
let repo_root_public_prefix_from_cwd cwd =
  let rec loop = function
    | [ "repos"; repo ] -> Some ("repos/" ^ repo ^ "/")
    | [ "repos"; repo; ".worktrees"; _ ] -> Some ("repos/" ^ repo ^ "/")
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (path_components cwd)

let path_contains_glob_meta s =
  String.exists
    (function
      | '*' | '?' | '[' | ']' | '{' | '}' -> true
      | _ -> false)
    s

let resolve_against_cwd ~cwd path =
  if Filename.is_relative path then Filename.concat cwd path else path

let strip_trailing_slash s =
  let len = String.length s in
  if len > 0 && Char.equal s.[len - 1] '/' then String.sub s 0 (len - 1) else s

let path_contains_parent_component path =
  path_components path |> List.exists (String.equal "..")

let repo_cwd_relative_rewrite ~cwd path_argument =
  let cwd = String.trim cwd in
  let path_argument = String.trim path_argument in
  match repo_root_public_prefix_from_cwd cwd with
  | Some prefix when Filename.is_relative path_argument ->
    let repo_root = strip_trailing_slash prefix in
    let relative_path =
      if String.equal path_argument repo_root || String.equal path_argument prefix
      then Some "."
      else if String.starts_with ~prefix path_argument
      then
        let suffix =
          String.sub path_argument (String.length prefix)
            (String.length path_argument - String.length prefix)
        in
        let suffix =
          if String.starts_with ~prefix:"/" suffix
          then String.sub suffix 1 (String.length suffix - 1)
          else suffix
        in
        Some (if String.equal suffix "" then "." else suffix)
      else None
    in
    (match relative_path with
     | Some path when path_contains_parent_component path -> None
     | other -> other)
  | Some _ | None -> None

let path_mentions_masc_state path_argument =
  path_components path_argument |> List.exists (String.equal Common.masc_dirname)

let path_probe_recovery ~cwd path_argument =
  match repo_cwd_relative_rewrite ~cwd path_argument with
  | Some relative_path ->
    `Assoc
      [ "kind", `String "repo_cwd_duplicate_prefix"
      ; ( "hint"
        , `String
            "cwd already points at the repo checkout; retry with the path relative \
             to that cwd instead of repeating repos/<repo>." )
      ; "retry_path", `String relative_path
      ; ( "alternatives"
        , `List
            [ `String
                (Printf.sprintf "Use argv path %S with the current cwd." relative_path)
            ; `String
                (Printf.sprintf
                   "Or omit cwd and use the sandbox-relative path %S."
                   path_argument)
            ] )
      ]
  | None when path_mentions_masc_state path_argument ->
    `Assoc
      [ "kind", `String "masc_state_not_filesystem"
      ; ( "hint"
        , `String
            ".masc runtime state is not available as a repo/sandbox file path in \
             keeper tools; use keeper task/context tools instead." )
      ; "retry_path", `Null
      ; ( "alternatives"
        , `List
            [ `String "Use keeper_context_status for sandbox paths."
            ; `String "Use keeper task/context tools for .masc task or runtime state."
            ] )
      ]
  | None ->
    `Assoc
      [ "kind", `String "probe_parent"
      ; ( "hint"
        , `String
            "Probe the parent directory first and retry with an existing child path; \
             do not infer module names as directory paths." )
      ; "retry_path", `Null
      ; ( "alternatives"
        , `List
            [ `String "Read path_probe.parent_entries before retrying."
            ; `String "Use a visible read/listing tool to confirm the exact path."
            ] )
      ]

let take n xs =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs

let path_probe ~cwd path_argument =
  let resolved_path = resolve_against_cwd ~cwd path_argument in
  let parent_argument = Filename.dirname path_argument in
  let resolved_parent = resolve_against_cwd ~cwd parent_argument in
  let cwd_norm = Keeper_alerting_path.normalize_path_for_check_stripped cwd in
  let parent_within_cwd =
    Keeper_alerting_path.is_within_root_norm ~root_norm:cwd_norm resolved_parent
  in
  let parent_exists =
    parent_within_cwd
    &&
    try Sys.file_exists resolved_parent with
    | Sys_error _ -> false
  in
  let parent_is_directory =
    parent_exists
    &&
    try Sys.is_directory resolved_parent with
    | Sys_error _ -> false
  in
  let parent_entries =
    if parent_is_directory
    then
      try
        Sys.readdir resolved_parent
        |> Array.to_list
        |> List.sort String.compare
        |> take path_probe_parent_entries_limit
      with
      | Sys_error _ | Unix.Unix_error _ -> []
    else []
  in
  { path_argument
  ; resolved_path
  ; parent_argument
  ; resolved_parent
  ; parent_exists
  ; parent_is_directory
  ; parent_within_cwd
  ; wildcard_like = path_contains_glob_meta path_argument
  ; parent_entries
  }

let path_probe_json ~cwd probe =
  `Assoc
    [ "path_argument", `String probe.path_argument
    ; "resolved_path", `String probe.resolved_path
    ; "parent_argument", `String probe.parent_argument
    ; "resolved_parent", `String probe.resolved_parent
    ; "parent_exists", `Bool probe.parent_exists
    ; "parent_is_directory", `Bool probe.parent_is_directory
    ; "parent_within_cwd", `Bool probe.parent_within_cwd
    ; "wildcard_like", `Bool probe.wildcard_like
    ; ( "parent_entries"
      , `List (List.map (fun name -> `String name) probe.parent_entries) )
    ; ( "hint"
      , `String
          (if probe.wildcard_like
           then
             "The missing path looks like a glob pattern. Probe the parent \
              directory first, then use Grep glob/pattern fields or find -name; \
              do not pass wildcard literals as path arguments."
           else
             "Probe the parent directory first and retry with an existing child \
              path; do not infer module names as directory paths.") )
    ; "recovery", path_probe_recovery ~cwd probe.path_argument
    ]

let path_probe_fields ~cwd path_argument =
  [ "path_probe", path_probe_json ~cwd (path_probe ~cwd path_argument) ]

(* Pre-dispatch path existence validation for typed commands.
   Uses Shell_ir_typed GADT path annotations (exhaustive, no
   string heuristics). Only validates Safe (read-only) Simple
   commands where path non-existence is a predictable pre-condition
   failure. Pipeline path validation is deferred. *)
let pre_dispatch_path_missing ~cwd ir =
  match ir with
  | Masc_exec.Shell_ir.Simple s ->
    let typed = Masc_exec.Shell_ir_typed.of_simple s in
    (match Masc_exec.Shell_ir_typed.risk typed with
     | `Safe ->
       let args = Masc_exec.Shell_ir_typed.path_args typed in
       List.find_opt (fun p ->
         let resolved =
           if Filename.is_relative p then Filename.concat cwd p else p
         in
         try not (Sys.file_exists resolved) with _ -> true
       ) args
     | `Audited | `Privileged -> None)
  | Masc_exec.Shell_ir.Pipeline _ -> None
;;

let sandbox_extra_uses_docker sandbox_extra_fields =
  List.exists
    (function
      | "via", `String "docker" -> true
      | _ -> false)
    sandbox_extra_fields

let typed_execute_response_cwd_json
      ~turn_sandbox_factory
      ~cwd
      ~sandbox_extra_fields
  =
  if sandbox_extra_uses_docker sandbox_extra_fields then
    match
      Keeper_sandbox_factory.container_cwd_of_host_opt
        turn_sandbox_factory
        ~host_cwd:cwd
    with
    | Some container_cwd ->
      Keeper_cwd_response.docker ~host_cwd:cwd ~container_cwd
      |> Keeper_cwd_response.to_yojson_response
    | None -> `String cwd
  else `String cwd

let path_reject_deterministic_reason msg =
  match Keeper_path_check_error.parse_prefix msg with
  | Some (Keeper_path_check_error.Path_outside_whitelist _) ->
    Some Keeper_tool_deterministic_error.Path_outside_sandbox
  | Some (Keeper_path_check_error.Cwd_not_directory _) ->
    Some Keeper_tool_deterministic_error.Cwd_not_directory
  | None ->
    (match Keeper_path_rejection.parse_rejection_prefix msg with
     | Some Keeper_path_rejection.Path_required ->
       Some Keeper_tool_deterministic_error.Command_shape_blocked
     | Some (Keeper_path_rejection.Not_found_relative _) ->
       Some Keeper_tool_deterministic_error.Path_not_found
     | Some (Keeper_path_rejection.Task_state_file_path_blocked _) ->
       Some Keeper_tool_deterministic_error.Task_state_probe_blocked
     | Some
         (Keeper_path_rejection.Absolute_path_rejected _
         | Keeper_path_rejection.Outside_project_root _
         | Keeper_path_rejection.Allowed_paths_normalized_empty _
         | Keeper_path_rejection.Outside_sandbox _
         | Keeper_path_rejection.Ambiguous_relative_read_path _) ->
       Some Keeper_tool_deterministic_error.Path_outside_sandbox
     | None -> None)

let dispatch_error_deterministic_reason = function
  | Keeper_tool_execute_shell_ir.Gate_reject _
  | Keeper_tool_execute_shell_ir.Cannot_parse
  | Keeper_tool_execute_shell_ir.Too_complex ->
    Some Keeper_tool_deterministic_error.Command_shape_blocked
  | Keeper_tool_execute_shell_ir.Path_reject msg ->
    path_reject_deterministic_reason msg
  | Keeper_tool_execute_shell_ir.Approval_required _
  | Keeper_tool_execute_shell_ir.Policy_denied _ ->
    Some Keeper_tool_deterministic_error.Policy_blocked

let dispatch_error_deterministic_retry_fields error =
  match dispatch_error_deterministic_reason error with
  | Some reason -> Keeper_tool_deterministic_error.deterministic_retry_fields reason
  | None -> []

let shell_ir_approval_overlay () =
  let resolution =
    Env_config_runtime.Shell_ir_approval.raw_overlay ()
    |> Masc_exec.Approval_config.resolve_shell_ir_approval_overlay
  in
  (match resolution.source with
   | Masc_exec.Approval_config.Invalid_overlay_fail_closed raw ->
     Log.Dashboard.warn
       "invalid MASC_SHELL_IR_APPROVAL value %S; using fail-closed enforced overlay"
       raw
   | Masc_exec.Approval_config.Default_autonomous
   | Masc_exec.Approval_config.Configured_overlay _ ->
     ());
  resolution.effective

let pr_action_status_label = function
  | Unix.WEXITED 0 -> "success"
  | Unix.WEXITED _ -> "exit_nonzero"
  | Unix.WSIGNALED _ -> "signaled"
  | Unix.WSTOPPED _ -> "stopped"
;;

let record_pr_action_metric ~keeper_name ~risk_class ~status ir =
  Command_descriptor.pr_action_events_of_ir ir
  |> List.iter (fun (event : Command_descriptor.pr_action_event) ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ToolExecutePrActionTotal)
      ~labels:
        [ "keeper", keeper_name
        ; "surface", Command_descriptor.pr_action_surface_to_string event.surface
        ; "action", Command_descriptor.pr_action_to_string event.action
        ; "status", pr_action_status_label status
        ; "risk_class", Masc_exec.Shell_ir_risk.string_of_risk_class risk_class
        ]
      ())
;;

let bool_label b = if b then "true" else "false"

let gh_verb_label (verb : Masc_exec.Gh_verb.t) =
  let family = Masc_exec.Gh_verb.string_of_family verb.family in
  match verb.action with
  | Some action -> family ^ ":" ^ action
  | None -> family
;;

let gh_verb_of_simple (simple : Masc_exec.Shell_ir.simple) :
    Masc_exec.Gh_verb.t option
  =
  match Masc_exec.Exec_program.known simple.bin with
  | Some Masc_exec.Exec_program.Gh ->
    (match Masc_exec.Shell_ir_typed.of_simple simple with
     | Masc_exec.Shell_ir_typed.W
         (Masc_exec.Shell_ir_typed_types.Gh { subcommand; action; _ }) ->
       Some (Masc_exec.Gh_verb.of_fields ~subcommand ~action)
     | Masc_exec.Shell_ir_typed.W _ ->
       (match Masc_exec.Shell_ir_risk.literal_words_of_simple simple with
        | Some words -> Some (Masc_exec.Gh_verb.classify words)
        | None ->
          let open Masc_exec.Gh_verb in
          Some { family = Other "opaque"; action = None }))
  | Some _ | None -> None
;;

let record_gh_classification_metric ~keeper_name ~risk_class ~typed_hit ir =
  let risk_class = Masc_exec.Shell_ir_risk.string_of_risk_class risk_class in
  let typed_hit = bool_label typed_hit in
  let rec visit = function
    | Masc_exec.Shell_ir.Simple simple ->
      (match gh_verb_of_simple simple with
       | None -> ()
       | Some verb ->
         let disposition =
           match Masc_exec.Gh_capability_policy.disposition_of_simple simple with
           | Some d -> Masc_exec.Gh_capability_policy.string_of_disposition d
           | None -> "none"
         in
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string GhClassificationTotal)
           ~labels:
             [ "keeper", keeper_name
             ; "verb", gh_verb_label verb
             ; "family", Masc_exec.Gh_verb.string_of_family verb.family
             ; "action", (match verb.action with Some action -> action | None -> "")
             ; "risk_class", risk_class
             ; "typed_hit", typed_hit
             ; "disposition", disposition
             ]
           ())
    | Masc_exec.Shell_ir.Pipeline stages -> List.iter visit stages
  in
  visit ir
;;

let record_gated_gh_lifecycle ~keeper_name ~event ~risk_class ~typed_hit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string GatedGhLifecycleTotal)
    ~labels:
      [ "keeper", keeper_name
      ; "event", event
      ; "risk_class", Masc_exec.Shell_ir_risk.string_of_risk_class risk_class
      ; "typed_hit", bool_label typed_hit
      ]
    ()
;;

let record_gated_gh_block_time ~keeper_name ~risk_class ~typed_hit ~seconds =
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string GatedGhBlockTimeSeconds)
    ~labels:
      [ "keeper", keeper_name
      ; "risk_class", Masc_exec.Shell_ir_risk.string_of_risk_class risk_class
      ; "typed_hit", bool_label typed_hit
      ]
    seconds
;;

let sandbox_target_label = function
  | Masc_exec.Sandbox_target.Host -> "host"
  | Masc_exec.Sandbox_target.Docker { image; _ } -> "docker:" ^ image
;;

let json_opt_string name = function
  | Some value -> [ name, `String value ]
  | None -> []
;;

let repo_create_visibility_label = function
  | Masc_exec.Gh_capability_policy.Public -> "public"
  | Masc_exec.Gh_capability_policy.Private -> "private"
  | Masc_exec.Gh_capability_policy.Internal -> "internal"
;;

let repo_create_contract_json
      (contract : Masc_exec.Gh_capability_policy.repo_create_contract)
  =
  let lifecycle = contract.lifecycle in
  `Assoc
    ([ "owner", `String contract.owner
     ; "name", `String contract.name
     ; "visibility", `String (repo_create_visibility_label contract.visibility)
     ; ( "lifecycle"
       , `Assoc
           ([ "add_readme", `Bool lifecycle.add_readme
            ; "clone", `Bool lifecycle.clone
            ; "push", `Bool lifecycle.push
            ]
            @ json_opt_string "source" lifecycle.source
            @ json_opt_string "remote" lifecycle.remote
            @ json_opt_string "template" lifecycle.template) )
     ])
;;

let repo_create_contract_json_of_ir ir =
  let rec scan = function
    | Masc_exec.Shell_ir.Simple simple ->
      (match Masc_exec.Gh_capability_policy.repo_create_contract_of_simple simple with
       | Some (Ok contract) -> Some (repo_create_contract_json contract)
       | Some (Error _) | None -> None)
    | Masc_exec.Shell_ir.Pipeline stages -> List.find_map scan stages
  in
  scan ir
;;

let shell_ir_approval_input
      ~cmd
      ~cwd
      ~bin
      ~summary
      ~sandbox_profile
      ~sandbox_target
      ~risk_class
      ~typed_hit
      ?repo_create_contract
      ()
      =
  let fields =
    [ "schema", `String "masc.shell_ir_approval_request.v1"
    ; "op", `String "shell_ir_approval_required"
    ; "action", `String "execute"
    ; "kind", `String "gh_capability_requires_approval"
    ; "cmd", `String cmd
    ; "cwd", `String cwd
    ; "bin", `String bin
    ; "summary", `String summary
    ; "sandbox_profile", `String sandbox_profile
    ; "sandbox_target", `String sandbox_target
    ; ( "risk_class"
      , `String (Masc_exec.Shell_ir_risk.string_of_risk_class risk_class) )
    ; "typed_hit", `Bool typed_hit
    ]
  in
  `Assoc
    (fields
     @
     match repo_create_contract with
     | Some contract -> [ "repo_create_contract", contract ]
     | None -> [])
;;

let submit_shell_ir_approval_pending
      ~base_path
      ~keeper_name
      ?task_id
      ?(goal_ids = [])
      ~cmd
      ~cwd
      ~bin
      ~summary
      ~sandbox_profile
      ~sandbox_target
      ~risk_class
      ~typed_hit
      ?repo_create_contract
      ()
  =
  let input =
    shell_ir_approval_input
      ~cmd
      ~cwd
      ~bin
      ~summary
      ~sandbox_profile
      ~sandbox_target
      ~risk_class
      ~typed_hit
      ?repo_create_contract
      ()
  in
  let on_resolution decision =
    let event =
      match decision with
      | Agent_sdk.Hooks.Approve -> "approved"
      | Agent_sdk.Hooks.Reject _ -> "denied"
      | Agent_sdk.Hooks.Edit _ -> "edited"
    in
    record_gated_gh_lifecycle ~keeper_name ~event ~risk_class ~typed_hit;
    Log.Keeper.info
      "shell_ir approval resolved keeper=%s decision=%s cmd=%s"
      keeper_name
      (Keeper_approval_queue.approval_decision_to_string decision)
      cmd
  in
  let approval_id =
    Keeper_approval_queue.submit_pending
      ~keeper_name
      ~tool_name:"tool_execute"
      ~input
      ~risk_level:Keeper_approval_queue.High
      ~base_path
      ?task_id
      ~goal_ids
      ~sandbox_target
      ~sandbox_profile
      ~disposition:"requires_approval"
      ~disposition_reason:summary
      ~on_resolution
      ()
  in
  record_gated_gh_lifecycle ~keeper_name ~event:"requested" ~risk_class ~typed_hit;
  record_gated_gh_block_time ~keeper_name ~risk_class ~typed_hit ~seconds:0.0;
  approval_id
;;

let execute_secret_redaction ~base_path ~keeper_name =
  Keeper_secret_redaction.snapshot ~base_path ~keeper_name

let redact_execute_text redaction text =
  Keeper_secret_redaction.redact_text redaction text

let redact_execute_output redaction ~stdout ~stderr =
  let stdout = redact_execute_text redaction stdout in
  let stderr = redact_execute_text redaction stderr in
  let output =
    if String.equal stderr "" then stdout else stdout ^ stderr
  in
  stdout, stderr, output

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
  let path_probe_json ~cwd path = path_probe_json ~cwd (path_probe ~cwd path)
  let repo_root_public_prefix_from_cwd = repo_root_public_prefix_from_cwd
  let repo_cwd_relative_rewrite = repo_cwd_relative_rewrite
  let typed_execute_response_cwd_json = typed_execute_response_cwd_json
  let record_pr_action_metric = record_pr_action_metric
  let record_gh_classification_metric = record_gh_classification_metric
  let shell_ir_approval_overlay = shell_ir_approval_overlay
  let shell_ir_approval_input = shell_ir_approval_input
  let submit_shell_ir_approval_pending = submit_shell_ir_approval_pending
  let redact_execute_output ~base_path ~keeper_name ~stdout ~stderr =
    let redaction = execute_secret_redaction ~base_path ~keeper_name in
    redact_execute_output redaction ~stdout ~stderr

  let dispatch_error_deterministic_retry_fields =
    dispatch_error_deterministic_retry_fields
end

(* Typed Execute input projections extracted to
   [Keeper_tool_execute_input] (godfile decomp). *)
let has_typed_execute_input_key = Keeper_tool_execute_input.has_typed_execute_input_key
let assoc_upsert = Keeper_tool_execute_input.assoc_upsert
let typed_input_command_text = Keeper_tool_execute_input.typed_input_command_text
let typed_input_has_env = Keeper_tool_execute_input.typed_input_has_env
let typed_validation_error_text = Keeper_tool_execute_input.typed_validation_error_text

let typed_validation_deterministic_retry_fields
      (_ : Keeper_tool_execute_typed_input.validation_error)
  =
  Keeper_tool_deterministic_error.deterministic_retry_fields
    Keeper_tool_deterministic_error.Command_shape_blocked

let typed_validation_recovery_fields
      (err : Keeper_tool_execute_typed_input.validation_error)
  =
  let diagnosis ~rule_id =
    [ ( "diagnosis"
      , `Assoc
          [ "rule_id", `String rule_id
          ; "tool_suggestion", `String "Execute"
          ; "scope_policy", `String "observe"
          ] )
    ]
  in
  let recovery_plan ~input_shape ~instruction ~example =
    [ ( "recovery_plan"
      , `Assoc
          [ "next_tool", `String "Execute"
          ; "input_shape", `String input_shape
          ; "instruction", `String instruction
          ; "example", example
          ] )
    ]
  in
  match err with
  | Keeper_tool_execute_typed_input.Argv_contains_shell_pipeline_operator _ ->
    diagnosis ~rule_id:"execute_pipeline_operator_in_argv"
    @ recovery_plan
        ~input_shape:"pipeline"
        ~instruction:
          "Retry Execute with top-level pipeline=[{executable,argv}, ...], \
           removing executable/argv from the top level. Do not use sh -c and \
           do not put '|' in argv."
        ~example:
          (`Assoc
             [ ( "pipeline"
               , `List
                   [ `Assoc
                       [ "executable", `String "git"
                       ; "argv", `List [ `String "log"; `String "--oneline" ]
                       ]
                   ; `Assoc
                       [ "executable", `String "head"
                       ; "argv", `List [ `String "-20" ]
                       ]
                   ] )
             ; "cwd", `String "repos/<repo>"
             ])
  | Keeper_tool_execute_typed_input.Argv_contains_shell_redirection _ ->
    diagnosis ~rule_id:"execute_redirection_operator_in_argv"
    @ recovery_plan
        ~input_shape:"typed_redirect"
        ~instruction:
          "Retry Execute with the typed stdin/stdout/stderr fields and remove \
           shell redirection tokens from argv. For discarded stderr use \
           stderr={discard:true}; do not use sh -c."
        ~example:
          (`Assoc
             [ "executable", `String "find"
             ; "argv", `List [ `String "."; `String "-name"; `String "*.ml" ]
             ; "stderr", `Assoc [ "discard", `Bool true ]
             ; "cwd", `String "repos/<repo>"
             ])
  | Keeper_tool_execute_typed_input.Empty_executable _
  | Keeper_tool_execute_typed_input.Executable_repeated_in_argv0 _
  | Keeper_tool_execute_typed_input.Argv_contains_shell_metachar _
  | Keeper_tool_execute_typed_input.Redirect_path_not_absolute _
  | Keeper_tool_execute_typed_input.Cwd_not_absolute _
  | Keeper_tool_execute_typed_input.Pipeline_empty
  | Keeper_tool_execute_typed_input.Pipeline_too_short
  | Keeper_tool_execute_typed_input.Env_key_invalid _ -> []

let normalize_path_for_keeper_tool_execute_shell_ir_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

(* Backend target helpers for typed Shell IR dispatch. *)
let docker_sandbox_target = Keeper_sandbox_shell_ir_target.docker_target
let docker_local_fallback_target =
  Keeper_sandbox_shell_ir_target.docker_local_fallback_target

let input_with_cwd cwd = function
  | Keeper_tool_execute_typed_input.Exec
      { executable; argv; cwd = _; env; stdin; stdout; stderr } ->
    Keeper_tool_execute_typed_input.Exec
      { executable
      ; argv
      ; cwd = Some cwd
      ; env
      ; stdin
      ; stdout
      ; stderr
      }
  | Keeper_tool_execute_typed_input.Pipeline { stages; cwd = _; env } ->
    Keeper_tool_execute_typed_input.Pipeline { stages; cwd = Some cwd; env }

let typed_input_shell_ir_unvalidated input =
  match Keeper_tool_execute_typed_input.to_shell_ir_unvalidated input with
  | Error _ -> None
  | Ok ir -> Some ir

let resolve_typed_git_cwd ~config ~meta ~cwd ~cmd = function
  | None -> cwd, None
  | Some ir ->
    Keeper_tool_execute_command_semantics.resolve_sandbox_root_git_cwd
      ~config
      ~meta
      ~cwd
      ~cmd
      ir

let handle_tool_execute_typed
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  let output_redaction =
    execute_secret_redaction ~base_path:config.base_path ~keeper_name:meta.name
  in
  match
    Keeper_tool_execute_path.resolve_tool_execute_cwd
      ~config
      ~meta
      (* Keep all keepers on the shared execute-worktree root; command-level
         permission remains the Shell IR gate, not per-keeper tool_access. *)
      ~write_enabled:true
      ~args
  with
    | Error e -> error_json e
    | Ok cwd ->
        let execution_location_fields cwd =
          [ ( "execution_location"
            , Keeper_sandbox_repo_path.execution_location_json ~config ~meta ~args ~cwd )
          ]
      in
      let typed_args = assoc_upsert "cwd" (`String cwd) args in
      match Keeper_tool_execute_typed_input.of_json typed_args with
      | Error e ->
        error_json
          ~fields:
            ([ "typed", `Bool true; "cwd", `String cwd ]
             @ policy_rejection_failure_class_fields
             @ execution_location_fields cwd)
          e
      | Ok input ->
        (match Keeper_tool_execute_typed_input.validate input with
         | Error e ->
           let alts =
             Keeper_tool_execute_typed_input.validation_error_alternatives e
           in
           let fields =
             [ "typed", `Bool true; "cwd", `String cwd ]
             @ policy_rejection_failure_class_fields
             @ execution_location_fields cwd
             @ typed_validation_deterministic_retry_fields e
             @ typed_validation_recovery_fields e
             @
             (match alts with
              | [] -> []
              | _ -> [ "alternatives", `List (List.map (fun s -> `String s) alts) ])
           in
           error_json ~fields (typed_validation_error_text e)
         | Ok () ->
        let cmd = typed_input_command_text input in
        let input_ir = typed_input_shell_ir_unvalidated input in
        let cwd, root_git_cwd_error =
          resolve_typed_git_cwd
            ~config
            ~meta
            ~cwd
            ~cmd
            input_ir
        in
        let root_git_cwd_error =
          match root_git_cwd_error with
          | Some e -> Some e
          | None ->
            Option.bind input_ir Keeper_tool_execute_command_semantics.misuse_error
        in
        let input = input_with_cwd cwd input in
        let in_playground = Keeper_tool_execute_path.in_playground ~root ~cwd ~meta in
        let sandbox_profile, _sandbox_network_mode =
          Keeper_sandbox_runner.effective_sandbox_profile ~meta
        in
        let local_dispatch_sandbox ?(extra_fields = []) () =
          match
            Keeper_secret_projection.local_env_for_keeper
              ~base_path:config.base_path
              ~keeper_name:meta.name
              ()
          with
          | Error err ->
            Error
              (Keeper_sandbox_shell_ir_target.target_error
                 ~fields:extra_fields
                 ("local_secret_projection_failed: " ^ err))
          | Ok base_host_env ->
            Ok (Masc_exec.Sandbox_target.host (), extra_fields, base_host_env)
        in
        let dispatch_sandbox =
          match sandbox_profile with
          | Local -> local_dispatch_sandbox ()
          | Docker ->
            if typed_input_has_env input
            then
              Error
                (Keeper_sandbox_shell_ir_target.target_error
                   "typed Shell IR Docker dispatch does not support env yet")
            else (
              match docker_local_fallback_target ~meta with
              | Some (target, fields) when in_playground ->
                (match target with
                 | Masc_exec.Sandbox_target.Host ->
                   local_dispatch_sandbox ~extra_fields:fields ()
                 | Docker _ -> Ok (target, fields, None))
              | Some _ | None ->
                docker_sandbox_target ~turn_sandbox_factory ~meta ~cwd
                |> Result.map (fun target ->
                  ( target
                  , [ "requested_sandbox", `String "docker"
                    ; "via", `String "docker"
                    ; "sandbox_profile", `String "docker"
                    ]
                  , None )))
        in
        (match dispatch_sandbox with
         | Error ({ message; fields } : Keeper_sandbox_shell_ir_target.target_error) ->
           error_json
             ~fields:
               ([ "typed", `Bool true; "cmd", `String cmd; "cwd", `String cwd ]
                @ execution_location_fields cwd
                @ fields)
             message
         | Ok (dispatch_sandbox, sandbox_extra_fields, base_host_env) ->
        let response_cwd_json =
          typed_execute_response_cwd_json
            ~turn_sandbox_factory
            ~cwd
            ~sandbox_extra_fields
        in
        let response_cwd_field = [ "cwd", response_cwd_json ] in
        match root_git_cwd_error with
        | Some e ->
          error_json
            ~fields:
              ([ "typed", `Bool true; "cmd", `String cmd ]
               @ response_cwd_field
               @ execution_location_fields cwd)
            e
        | None ->
        (* RFC-0160 S1: lower-then-classify. Typed argv → Shell IR
           once, then both mutation classifiers consume the same IR.
           This removes the previous double-parse (mutation classifier
           re-tokenized cmd:string via the legacy string tokenizer before IR
           was even built). *)
        match Keeper_tool_execute_typed_input.to_shell_ir ~sandbox:dispatch_sandbox input with
        | Error e ->
          let alts = Keeper_tool_execute_typed_input.validation_error_alternatives e in
          let fields =
            [ "typed", `Bool true; "cmd", `String cmd ]
            @ response_cwd_field
            @ execution_location_fields cwd
            @ typed_validation_deterministic_retry_fields e
            @ typed_validation_recovery_fields e
            @
            (match alts with
             | [] -> []
             | _ -> [ "alternatives", `List (List.map (fun s -> `String s) alts) ])
          in
          error_json ~fields (typed_validation_error_text e)
        | Ok ir ->
        let cmd_for_log =
          Exec_policy.sanitize_command_for_log_of_ir ~fallback_cmd:cmd ir
          |> Exec_policy.truncate_for_log
        in
        let message_for_log s =
          String.map
            (function
              | '\n' | '\r' | '\t' -> ' '
              | c -> c)
            s
          |> Exec_policy.truncate_for_log
        in
        let typed_error_fields =
          [ "typed", `Bool true; "cmd", `String cmd_for_log ]
          @ response_cwd_field
          @ execution_location_fields cwd
        in
        let blocked_result
              ?deterministic_reason
              ?(extra_fields = [])
              ~error
              ~reason
              ~alternatives
              ()
          =
          (* RFC-0208 P1: a blocked typed command emits a Keeper-level audit
             line so denials are greppable, not only returned as tool_error
             JSON to the agent. Covers destructive-block and write-gate; the
             [error] code distinguishes them. *)
          Log.Keeper.warn
            "shell_ir blocked keeper=%s error=%s reason=%s typed_hit=%b cmd=%s"
            meta.name
            error
            (message_for_log reason)
            (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir)
            cmd_for_log;
          let deterministic_retry_fields =
            match deterministic_reason with
            | Some deterministic_reason ->
              Keeper_tool_deterministic_error.deterministic_retry_fields
                deterministic_reason
            | None -> []
          in
          Yojson.Safe.to_string
            (Exec_core.blocked_result_json
               ~classification:(Exec_core.classify_command_of_ir ir)
               ~cmd
               ~error
               ~reason
               ~alternatives
               ~retryability:Exec_core.Operator_required
               ~extra:
                 (deterministic_retry_fields
                  @ [ "cmd", `String cmd_for_log
                    ; "typed", `Bool true
                    ; "execution_time_ms", `Int 0
                    ]
                  @ extra_fields
                  @ response_cwd_field
                  @ execution_location_fields cwd)
               ())
        in
        let envelope = Keeper_tool_execute_shell_ir.classify ir in
        let risk_class = Masc_exec.Shell_ir_risk.risk_class envelope in
        let typed_hit = Masc_exec.Shell_ir_risk.typed_hit_of_ir ir in
        record_gh_classification_metric
          ~keeper_name:meta.name
          ~risk_class
          ~typed_hit
          ir;
        let typed_error_json ?dispatch_error ?(extra_fields = []) msg =
          let deterministic_retry_fields =
            match dispatch_error with
            | Some dispatch_error ->
              dispatch_error_deterministic_retry_fields dispatch_error
            | None -> []
          in
          error_json
            ~fields:
              (typed_error_fields
               @ policy_rejection_failure_class_fields
               @ deterministic_retry_fields
               @ extra_fields)
            msg
        in
        if Masc_exec.Shell_ir_risk.is_destructive envelope
        then
          blocked_result
            ~deterministic_reason:
              Keeper_tool_deterministic_error.Destructive_operation_blocked
            ~error:"destructive_operation_blocked"
            ~reason:"This typed command is destructive and is blocked for every keeper execution surface."
            ~alternatives:[ "Use a non-destructive command or a dedicated structured tool." ]
            ()
        else
        let path_missing = pre_dispatch_path_missing ~cwd ir in
        match path_missing with
        | Some missing_path ->
          let parent = Filename.dirname missing_path in
          let probe = path_probe ~cwd missing_path in
          let wildcard_hint =
            if probe.wildcard_like
            then
              " The path also contains glob metacharacters; use Grep \
               glob/pattern fields or probe the parent with ls/find instead of \
               passing a wildcard literal as a path."
            else ""
          in
          blocked_result
            ~deterministic_reason:Keeper_tool_deterministic_error.Path_not_found
            ~extra_fields:(path_probe_fields ~cwd missing_path)
            ~error:"path_not_found"
            ~reason:(Printf.sprintf
              "The path argument %S does not exist.%s Probe the parent \
               directory before retrying; do not infer package or module names \
               as directory paths."
              missing_path wildcard_hint)
            ~alternatives:
              [ Printf.sprintf "Use executable=\"ls\" argv=[%S]." parent
              ; (if probe.wildcard_like
                 then
                   "For filename patterns, prefer Grep with pattern/glob or \
                    Execute find -name after the parent path is confirmed."
                 else
                   "Read path_probe.parent_entries and retry with an existing \
                    child path.")
              ]
            ()
        | None ->
          let env_snap =
            Cancel_safe.protect
              ~on_exn:(fun _ -> None)
              (fun () -> Some (Exec_core.snapshot_env ~cwd))
          in
          (* NDT-OK: wall clock is used only for elapsed telemetry, never for
             dispatch branching or policy decisions. *)
          let t0 = Unix.gettimeofday () in
          let task_id =
            Option.map Keeper_id.Task_id.to_string meta.current_task_id
          in
          let stream_dispatch =
            Sys.getenv_opt "MASC_STREAM_EXECUTE_OUTPUT" <> Some "false"
          in
          if stream_dispatch
          then (
            try
              Keeper_keepalive_signal.record_execute_stream_start
                ~keeper_name:meta.name
                ~task_id
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Dashboard.warn
                "execute stream start callback failed keeper=%s: %s"
                meta.name
                (Printexc.to_string exn));
          let stdout_redact_state =
            Keeper_secret_redaction.create_stream_state ()
          in
          let stderr_redact_state =
            Keeper_secret_redaction.create_stream_state ()
          in
          let on_output_chunk chunk =
            if stream_dispatch
            then (
              let stream, data =
                match chunk with
                | `Stdout s -> `Stdout, s
                | `Stderr s -> `Stderr, s
              in
              let data =
                match stream with
                | `Stdout ->
                  Keeper_secret_redaction.redact_stream_chunk
                    output_redaction stdout_redact_state data
                | `Stderr ->
                  Keeper_secret_redaction.redact_stream_chunk
                    output_redaction stderr_redact_state data
              in
              try
                Keeper_keepalive_signal.record_execute_stream_chunk
                  ~keeper_name:meta.name
                  ~stream
                  data
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.warn
                  "execute stream chunk callback failed keeper=%s: %s"
                  meta.name
                  (Printexc.to_string exn))
          in
          Retired_env_warnings.report_shell_ir_path_jail_if_set
            ~source:"execute"
            ();
          let dispatch_result =
            if Env_config_runtime.Shell_ir_approval_gate.enabled ()
            then (
              let agent_id = Masc_exec.Agent_id.of_string meta.name in
              (* RFC-0254 §5.2/§5.5: the keeper lane defaults to [autonomous] —
                 no human or resolver can answer an [Ask].  Resolve the typed
                 environment overlay at each Execute decision so enforcement
                 and dashboard runtime truth observe the same live value.  The
                 trust-independent catastrophic floor in [Approval_policy.decide]
                 (destructive git, redirect write-escape, [mkfs]) still denies.
                 The floor is applied identically on Host and inside Docker
                 (RFC §13 Q2: defense-in-depth — a destructive git push reaches
                 the real remote even from a container), so no sandbox-conditional
                 branch is needed: both profiles use the same overlay. *)
              let approval_config =
                { Masc_exec.Approval_config.defaults = shell_ir_approval_overlay ()
                ; per_agent = []
                }
              in
              Keeper_tool_execute_shell_ir.dispatch_classified_with_approval
                ~agent_id
                ~approval_config
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:cwd
                ~sandbox:dispatch_sandbox
                ?base_host_env
                ~on_output_chunk
                envelope)
            else
              Keeper_tool_execute_shell_ir.dispatch_classified
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:cwd
                ~sandbox:dispatch_sandbox
                ?base_host_env
                ~on_output_chunk
                envelope
          in
          match dispatch_result with
          | Error (Keeper_tool_execute_shell_ir.Gate_reject diagnostic as err) ->
            (* RFC-0208 P1: gate denial audit line. *)
            Log.Keeper.warn
              "shell_ir gate_reject keeper=%s cmd=%s diagnostic=%s"
              meta.name
              cmd_for_log
              (message_for_log diagnostic);
            typed_error_json ~dispatch_error:err diagnostic
          | Error (Keeper_tool_execute_shell_ir.Cannot_parse as err) ->
            typed_error_json ~dispatch_error:err "Cannot parse command"
          | Error (Keeper_tool_execute_shell_ir.Too_complex as err) ->
            typed_error_json ~dispatch_error:err "Command too complex"
          | Error (Keeper_tool_execute_shell_ir.Path_reject e as err) ->
            (* RFC-0208 P1: path-policy denial audit line. *)
            Log.Keeper.warn
              "shell_ir path_reject keeper=%s cmd=%s reason=%s"
              meta.name
              cmd_for_log
              (message_for_log e);
            typed_error_json
              ~dispatch_error:err
              ~extra_fields:[ "blocked_cmd", `String cmd_for_log ]
              e
          | Error
              (Keeper_tool_execute_shell_ir.Approval_required { summary; bin; kind } as err)
            ->
            Log.Keeper.warn
              "shell_ir approval_required keeper=%s cmd=%s bin=%s kind=%s summary=%s"
              meta.name
              cmd_for_log
              bin
              (Keeper_tool_execute_shell_ir.approval_required_kind_to_string kind)
              summary;
            (match kind with
             | Keeper_tool_execute_shell_ir.Gh_capability_requires_approval ->
               let sandbox_profile =
                 Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile
               in
               let sandbox_target = sandbox_target_label dispatch_sandbox in
               let repo_create_contract = repo_create_contract_json_of_ir ir in
               let approval_id =
                 submit_shell_ir_approval_pending
                   ~base_path:root
                   ~keeper_name:meta.name
                   ?task_id
                   ~goal_ids:meta.active_goal_ids
                   ~cmd:cmd_for_log
                   ~cwd
                   ~bin
                   ~summary
                   ~sandbox_profile
                   ~sandbox_target
                   ~risk_class
                   ~typed_hit
                   ?repo_create_contract
                   ()
               in
               typed_error_json
                 ~dispatch_error:err
                 ~extra_fields:
                   [ "approval_request_id", `String approval_id
                   ; "approval_queue_status", `String "pending"
                   ; "approval_nonblocking", `Bool true
                   ; "approval_required_kind", `String "gh_capability_requires_approval"
                   ; "approval_block_time_ms", `Int 0
                   ; "approval_disposition", `String "requires_approval"
                   ]
                 summary
             | Keeper_tool_execute_shell_ir.Privileged_program_floor ->
               typed_error_json
                 ~dispatch_error:err
                 ~extra_fields:
                   [ "approval_nonblocking", `Bool false
                   ; "approval_required_kind", `String "privileged_program_floor"
                   ]
                 summary)
          | Error (Keeper_tool_execute_shell_ir.Policy_denied { reason } as err) ->
            Log.Keeper.warn
              "shell_ir policy_denied keeper=%s cmd=%s reason=%s"
              meta.name
              cmd_for_log
              reason;
            typed_error_json ~dispatch_error:err reason
          | Ok result ->
            let elapsed_ms =
              (* NDT-OK: second wall-clock read closes the elapsed telemetry
                 span recorded immediately below. *)
              elapsed_duration_ms ~start_time:t0 ~end_time:(Unix.gettimeofday ())
            in
            (* RFC-0208 P1: risk_class + typed_hit make the typed-coverage
               of live traffic observable. An offline scan of typed_hit=true
               / total gives the real exercise rate of the typed model vs the
               Generic escape hatch. *)
            record_pr_action_metric
              ~keeper_name:meta.name
              ~risk_class
              ~status:result.status
              ir;
            let effects = Masc_exec.Exec_effect.extract ir in
            let effects_str = Format.asprintf "%a" Masc_exec.Exec_effect.pp_set effects in
            Log.Keeper.info
              "shell_ir dispatch keeper=%s sandbox=%s status=%s elapsed_ms=%d risk_class=%s typed_hit=%b effects=%s"
              meta.name
              (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
              (Keeper_sandbox_exec_failure.status_label result.status)
              elapsed_ms
              (Masc_exec.Shell_ir_risk.string_of_risk_class risk_class)
              (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir)
              effects_str;
            Otel_spans.add_attrs
              ~attrs:[
                ( "shell_ir.risk_class"
                , `String
                    (Masc_exec.Shell_ir_risk.string_of_risk_class risk_class) )
              ; ( "shell_ir.typed_hit"
                , `Bool (Masc_exec.Shell_ir_risk.typed_hit_of_ir ir) )
              ; "shell_ir.effects", `String effects_str
              ]
              ();
            List.iter
              (fun (eff : Masc_exec.Exec_effect.t) ->
                 Otel_metric_store.inc_counter
                   (Keeper_metrics.to_string Keeper_metrics.ShellIrEffectTotal)
                   ~labels:[
                     ( "kind"
                     , Masc_exec.Exec_effect.string_of_effect_kind eff.kind )
                   ; "source", eff.source
                   ]
                   ())
              effects;
            let stdout, stderr, output =
              redact_execute_output output_redaction
                ~stdout:result.stdout
                ~stderr:result.stderr
            in
            let status_json =
              Keeper_alerting_path.process_status_to_json result.status
            in
            if stream_dispatch
            then (
              let flush_remaining stream state =
                let remaining =
                  Keeper_secret_redaction.redact_stream_finish
                    output_redaction state
                in
                if not (String.equal remaining "")
                then (
                  try
                    Keeper_keepalive_signal.record_execute_stream_chunk
                      ~keeper_name:meta.name
                      ~stream
                      remaining
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Dashboard.warn
                      "execute stream flush callback failed keeper=%s: %s"
                      meta.name
                      (Printexc.to_string exn))
              in
              flush_remaining `Stdout stdout_redact_state;
              flush_remaining `Stderr stderr_redact_state;
              try
                Keeper_keepalive_signal.record_execute_stream_end
                  ~keeper_name:meta.name
                  ~task_id
                  ~status:status_json
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.warn
                  "execute stream end callback failed keeper=%s: %s"
                  meta.name
                  (Printexc.to_string exn));
            (try
               Keeper_keepalive_signal.record_execute_output
                 ~keeper_name:meta.name
                 ~task_id
                 ~stdout
                 ~stderr
                 ~status:status_json
                 ~streamed:stream_dispatch
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Dashboard.warn
                 "execute output callback failed keeper=%s: %s"
                 meta.name
                 (Printexc.to_string exn));
            let failure_error_fields =
              match result.status, String.trim stderr with
              | Unix.WEXITED 0, _ | _, "" -> []
              | _, stderr -> [ "error", `String stderr; "stderr", `String stderr ]
            in
            let glob_literal_failure_fields =
              Masc_exec.Shell_ir_diagnostics.glob_literal_failure_fields
                ~ir
                ~status:result.status
                ~stderr
            in
            (* Mutually exclusive with the glob hint: both share the
               execution_hint/shell_ir_hint keys, and a command carrying a glob
               token gets the more specific glob guidance first. *)
            let duplicate_argv0_failure_fields =
              if glob_literal_failure_fields <> []
              then []
              else
                Masc_exec.Shell_ir_diagnostics.duplicate_argv0_failure_fields
                  ~ir
                  ~status:result.status
                  ~stderr
            in
            let classification = Exec_core.classify_command_of_ir ir in
            (* Only include command_descriptor on success — errors already carry
               sufficient diagnostic info (exit code, stderr, classification). *)
            let descriptor_fields =
              match result.status with
              | Unix.WEXITED 0 ->
                let descriptor = Command_descriptor.compute ir in
                [ "command_descriptor", Command_descriptor.to_json descriptor ]
              | _ -> []
            in
            Yojson.Safe.to_string
              (Exec_core.process_result_json
                 ~classification
                 ~base_path:root
                 ~keeper_name:meta.name
                 ~cmd
                 ~extra:
                   (failure_error_fields
                    @ glob_literal_failure_fields
                    @ duplicate_argv0_failure_fields
                    @ sandbox_extra_fields
                    @ [ "typed", `Bool true
                      ; "execution_time_ms", `Int elapsed_ms
                      ]
                    @ response_cwd_field
                    @ descriptor_fields
                    @ execution_location_fields cwd)
                 ~status:result.status
                 ~output
                 ~env_snapshot:env_snap
                 ())))

let handle_tool_execute
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:_
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  if has_typed_execute_input_key args
  then
    handle_tool_execute_typed
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
      ()
  else
    error_json
      ~fields:[ "typed", `Bool true ]
      "Typed Shell IR input is required. Provide executable/argv or pipeline."
;;
