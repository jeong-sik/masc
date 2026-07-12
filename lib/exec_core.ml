type command_family =
  | Read
  | Search
  | List
  | Build
  | Test
  | Git_read
  | Git_write
  | Package_install
  | Network_read
  | Clone
  | Unknown

type reversibility =
  | Read_only
  | Reversible
  | Irreversible

type risk =
  | Low
  | Medium
  | High

type semantic_status =
  | Ok
  | No_match
  | Partial
  | Blocked
  | Timeout
  | Runtime_error

type retryability =
  | None_
  | Self_correct
  | Operator_required

(* RFC-0092 Phase B Step 1: typed validator hand-off marker.
   Replaces string-based "next_action" suggestion in blocked_result_json
   extras with a closed sum.  Consumers (Cluster C Step 5,
   keeper_tool_execute_runtime.ml block path) will populate this; readers
   pattern-match exhaustively so new validator stages become a
   compile-time addition. *)
type validator_stage =
  | Probe_task_state
  | Probe_http
  | Probe_search
  | Allowed

type artifact_policy =
  | Inline_only
  | Persist_if_large

type classification =
  { family : command_family
  ; reversibility : reversibility
  ; risk : risk
  ; risk_class : Masc_exec.Shell_ir_risk.risk_class
  }

type artifact_storage = Filesystem

type artifact_ref =
  { path : string
  ; bytes : int
  ; storage : artifact_storage
  }

type executed_result =
  { command : string
  ; process_status : Unix.process_status
  ; output : string
  ; semantic_status : semantic_status
  ; classification : classification
  ; summary : string
  ; retryability : retryability
  ; artifact_refs : artifact_ref list
  ; recovery_hint : string option
  }

type diagnosis =
  { rule_id : string
  ; explanation : string
  ; rewrite : string option
  ; tool_suggestion : string option
  }

type blocked_result =
  { command : string
  ; error : string
  ; reason : string
  ; hint : string
  ; alternatives : string list
  ; classification : classification
  ; retryability : retryability
  ; summary : string
  ; diagnosis : diagnosis option
  }

type outcome =
  | Executed of executed_result
  | Blocked_result of blocked_result

type project_kind =
  | OCaml_dune
  | Node_js
  | Python
  | Rust_cargo
  | Go_module
  | Unknown_project

type exec_env_snapshot =
  { cwd : string
  ; git_repo : bool
  ; git_branch : string option
  ; project_kind : project_kind
  ; project_name : string option
  }

let string_of_project_kind = function
  | OCaml_dune -> "ocaml_dune"
  | Node_js -> "node_js"
  | Python -> "python"
  | Rust_cargo -> "rust_cargo"
  | Go_module -> "go_module"
  | Unknown_project -> "unknown"
;;

let detect_project_kind cwd =
  if Sys.file_exists (cwd ^ "/dune-project")
  then OCaml_dune
  else if Sys.file_exists (cwd ^ "/package.json")
  then Node_js
  else if
    Sys.file_exists (cwd ^ "/pyproject.toml")
    || Sys.file_exists (cwd ^ "/setup.py")
    || Sys.file_exists (cwd ^ "/requirements.txt")
  then Python
  else if Sys.file_exists (cwd ^ "/Cargo.toml")
  then Rust_cargo
  else if Sys.file_exists (cwd ^ "/go.mod")
  then Go_module
  else Unknown_project
;;

let detect_project_name cwd =
  let basename = Filename.basename cwd in
  if basename = "" || basename = "." then None else Some basename
;;

let snapshot_env ~cwd =
  let git_dir = cwd ^ "/.git" in
  let git_repo = Sys.file_exists git_dir || Sys.is_directory git_dir in
  let git_branch =
    if not git_repo
    then None
    else (
      let head_file = cwd ^ "/.git/HEAD" in
      if not (Sys.file_exists head_file)
      then None
      else (
        try
          let ic = open_in head_file in
          Eio_guard.protect
            ~finally:(fun () -> close_in_noerr ic)
            (fun () ->
               let line = input_line ic in
               let prefix = "ref: refs/heads/" in
               if String.starts_with ~prefix line
               then
                 Some
                   (String.sub
                      line
                      (String.length prefix)
                      (String.length line - String.length prefix))
               else Some (String.sub line 0 8))
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> None))
  in
  let project_kind = detect_project_kind cwd in
  let project_name = detect_project_name cwd in
  { cwd; git_repo; git_branch; project_kind; project_name }
;;

let env_snapshot_to_json (snap : exec_env_snapshot) : Yojson.Safe.t =
  let branch_field =
    match snap.git_branch with
    | None -> []
    | Some b -> [ "git_branch", `String b ]
  in
  let name_field =
    match snap.project_name with
    | None -> []
    | Some n -> [ "project_name", `String n ]
  in
  `Assoc
    ([ "cwd", `String snap.cwd
     ; "git_repo", `Bool snap.git_repo
     ; "project_kind", `String (string_of_project_kind snap.project_kind)
     ]
     @ branch_field
     @ name_field)
;;

let env_int name default =
  match Sys.getenv_opt name with
  | Some value ->
    (match int_of_string_opt value with
     | Some parsed -> parsed
     | None -> default)
  | None -> default
;;

let artifact_threshold_bytes =
  max 1024 (env_int "MASC_EXEC_ARTIFACT_THRESHOLD_BYTES" 16384)
;;

let last_base_command cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Error _ -> None
  | Ok ir ->
    Masc_exec.Shell_ir_command_shape.last_command_name ir
    |> Option.map Masc_exec.Shell_ir_command_shape.normalize_command_name
;;

let first_effective_stage ir =
  match Masc_exec.Shell_ir_command_shape.effective_stages ir with
  | stage :: _ -> Some stage
  | [] -> None
;;

let first_stage_arg { Masc_exec.Shell_ir_command_shape.args; _ } =
  match args with
  | sub :: _ -> Some sub
  | [] -> None
;;

let looks_like_test_command ~base ~sub =
  match String.lowercase_ascii base, Option.map String.lowercase_ascii sub with
  | ("pytest" | "pyright" | "ruff"), _ -> true
  | "cargo", Some ("test" | "check" | "clippy") -> true
  | "dune", Some ("runtest" | "test") -> true
  | "make", Some "test" -> true
  | ("npm" | "pnpm" | "yarn"), Some ("test" | "lint" | "typecheck" | "check") -> true
  | ("python" | "python3" | "node" | "go"), Some "test" -> true
  | _ -> false
;;

let family_of_stage ~risk_class stage =
  let base =
    Masc_exec.Shell_ir_command_shape.normalize_command_name
      stage.Masc_exec.Shell_ir_command_shape.bin
  in
  let sub = first_stage_arg stage in
  match String.lowercase_ascii base with
  | "git" ->
    (match
       Masc_exec.Shell_ir_command_shape.git_subcommand
         stage.Masc_exec.Shell_ir_command_shape.args
     with
     | Some "clone" -> Clone
     | _ ->
       if risk_class = Masc_exec.Shell_ir_risk.R0_Read
       then Git_read
       else Git_write)
  | "rg" | "grep" | "find" -> Search
  | "ls" | "tree" | "du" -> List
  | "cat"
  | "head"
  | "tail"
  | "wc"
  | "pwd"
  | "env"
  | "which"
  | "file"
  | "stat"
  | "cut"
  | "sort"
  | "uniq"
  | "tr"
  | "sed" -> Read
  | "curl" | "wget" -> Network_read
  | "npm" | "pnpm" | "yarn" | "pip" | "opam" ->
    if risk_class = Masc_exec.Shell_ir_risk.R0_Read
    then (if looks_like_test_command ~base ~sub then Test else Build)
    else Package_install
  | "cargo"
  | "dune"
  | "make"
  | "go"
  | "gofmt"
  | "gradle"
  | "mvn"
  | "cmake"
  | "ninja"
  | "java"
  | "javac"
  | "node"
  | "npx"
  | "python"
  | "python3"
  | "rustc"
  | "uv" -> if looks_like_test_command ~base ~sub then Test else Build
  | _ -> Unknown
;;

let reversibility_of_command ~is_destructive family =
  if is_destructive
  then Irreversible
  else (
    match family with
    | Read | Search | List | Build | Test | Git_read | Network_read -> Read_only
    | Package_install | Clone | Git_write | Unknown -> Reversible)
;;

let risk_of_command ~risk_class ~is_destructive family =
  if is_destructive
  then High
  else (
    match family with
    | Git_write | Package_install | Clone -> High
    | Unknown when risk_class <> Masc_exec.Shell_ir_risk.R0_Read -> High
    | Build | Test | Network_read | Unknown -> Medium
    | Read | Search | List | Git_read -> Low)
;;

let classify_command_of_ir ir =
  let envelope =
    Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
  in
  let risk_class = envelope.Masc_exec.Shell_ir_risk.risk in
  let is_destructive = Masc_exec.Shell_ir_risk.is_destructive envelope in
  let family =
    match first_effective_stage ir with
    | Some stage -> family_of_stage ~risk_class stage
    | None -> Unknown
  in
  { family
  ; reversibility = reversibility_of_command ~is_destructive family
  ; risk = risk_of_command ~risk_class ~is_destructive family
  ; risk_class
  }

let string_of_command_family = function
  | Read -> "read"
  | Search -> "search"
  | List -> "list"
  | Build -> "build"
  | Test -> "test"
  | Git_read -> "git_read"
  | Git_write -> "git_write"
  | Package_install -> "package_install"
  | Network_read -> "network_read"
  | Clone -> "clone"
  | Unknown -> "unknown"
;;

let string_of_reversibility = function
  | Read_only -> "read_only"
  | Reversible -> "reversible"
  | Irreversible -> "irreversible"
;;

let string_of_risk = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
;;

let classification_to_json classification =
  `Assoc
    [ "family", `String (string_of_command_family classification.family)
    ; "reversibility", `String (string_of_reversibility classification.reversibility)
    ; "risk", `String (string_of_risk classification.risk)
    ; "risk_class", `String (Masc_exec.Shell_ir_risk.string_of_risk_class classification.risk_class)
    ]
;;

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true
  | _ -> false
;;

let string_of_semantic_status = function
  | Ok -> "ok"
  | No_match -> "no_match"
  | Partial -> "partial"
  | Blocked -> "blocked"
  | Timeout -> "timeout"
  | Runtime_error -> "runtime_error"
;;

let string_of_retryability = function
  | None_ -> "none"
  | Self_correct -> "self_correct"
  | Operator_required -> "operator_required"
;;

let non_empty_lines output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
;;

let is_find_diagnostic_line line =
  let trimmed = String.trim line in
  String.starts_with ~prefix:"find:" trimmed || String.starts_with ~prefix:"find " trimmed
;;

let semantic_status_of_find_output output =
  let lines = non_empty_lines output in
  let has_result_line =
    List.exists (fun line -> not (is_find_diagnostic_line line)) lines
  in
  let has_diagnostic_line = List.exists is_find_diagnostic_line lines in
  if has_result_line && has_diagnostic_line then Partial else Runtime_error
;;

let semantic_status_of_process ~cmd ~output status =
  if process_status_is_timeout status
  then Timeout
  else (
    match status with
    | Unix.WEXITED 0 -> Ok
    | Unix.WEXITED 1 ->
      (match last_base_command cmd with
       | Some ("rg" | "grep") -> No_match
       | Some "find" -> semantic_status_of_find_output output
       | _ -> Runtime_error)
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Runtime_error)
;;

let retryability_of_semantic_status = function
  | Ok -> None_
  | Blocked | No_match | Partial | Timeout | Runtime_error -> Self_correct
;;

let semantic_status_is_success = function
  | Ok | No_match -> true
  | Blocked | Timeout | Runtime_error -> false
  | Partial -> false
;;

(* Declared projection onto the shared tool-failure taxonomy
   (Tool_result.tool_failure_class), emitted on the wire as the
   "failure_class" field that Keeper_tools_oas_failure_boundary reads as a
   closed enum. Without this declaration every Execute failure fell back to
   Runtime_failure at that boundary, collapsing timeouts (retryable) and
   policy blocks (deterministic) into one unknown, non-retryable signature
   (sangsu keeper incident, 2026-07-12). [None] exactly when
   [semantic_status_is_success] holds, so success payloads never carry a
   failure class. *)
let failure_class_of_semantic_status = function
  | Ok | No_match -> None
  | Timeout -> Some Tool_result.Transient_error
  | Blocked -> Some Tool_result.Policy_rejection
  | Partial | Runtime_error -> Some Tool_result.Runtime_failure
;;

let failure_class_field semantic_status =
  match failure_class_of_semantic_status semantic_status with
  | None -> []
  | Some failure_class ->
    [ "failure_class", `String (Tool_result.tool_failure_class_to_string failure_class) ]
;;

let family_label = function
  | Read -> "read"
  | Search -> "search"
  | List -> "list"
  | Build -> "build"
  | Test -> "test"
  | Git_read -> "git inspection"
  | Git_write -> "git write"
  | Package_install -> "package management"
  | Network_read -> "network"
  | Clone -> "clone"
  | Unknown -> "command"
;;

let summary_of_status classification semantic_status =
  let label = family_label classification.family in
  match semantic_status with
  | Ok -> Printf.sprintf "%s command completed." (String.capitalize_ascii label)
  | No_match ->
    Printf.sprintf "%s completed with no matches." (String.capitalize_ascii label)
  | Partial ->
    Printf.sprintf "%s completed with partial results." (String.capitalize_ascii label)
  | Blocked ->
    Printf.sprintf "%s command blocked before execution." (String.capitalize_ascii label)
  | Timeout -> Printf.sprintf "%s command timed out." (String.capitalize_ascii label)
  | Runtime_error ->
    Printf.sprintf "%s command failed at runtime." (String.capitalize_ascii label)
;;

let default_recovery_hint classification semantic_status =
  match semantic_status with
  | Ok -> None
  | No_match ->
    Some
      (match classification.family with
       | Search -> "Adjust the search pattern or narrow the target path, then retry."
       | _ -> "Retry with a narrower command or switch to a structured shell op.")
  | Partial ->
    Some
      "Inspect the output for partial results and retry with a narrower scope if needed."
  | Timeout ->
    Some
      "Narrow the command scope, reduce output volume, or increase timeout_sec \
       moderately."
  | Runtime_error ->
    Some
      "Inspect the command output, then retry with a narrower command or a structured \
       shell op."
  | Blocked ->
    Some
      "Revise the command or switch to the structured shell tool that matches the intent."
;;

let lowercase_contains haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0
    then true
    else if i + n_len > h_len
    then false
    else if String.sub haystack i n_len = needle
    then true
    else loop (i + 1)
  in
  loop 0

let mentions_task_state_file text =
  List.exists
    (lowercase_contains text)
    [ ".masc/backlog.json"
    ; ".masc/state/backlog.json"
    ; "repos/masc/.masc/backlog.json"
    ; "repos/masc/.masc/tasks/backlog.json"
    ; "repos/masc/backlog.json"
    ; "tasks/backlog.json"
    ]

let task_state_file_recovery_hint =
  "This is not a keeper-visible task-state path. Do not read .masc/backlog.json \
   or repo-local backlog files from shell. Use keeper_tasks_list for task/backlog \
   state and keeper_context_status for current_task_id/sandbox paths."

let recovery_hint_for_output ~cmd ~output classification semantic_status =
  match semantic_status with
  | Runtime_error
    when mentions_task_state_file cmd || mentions_task_state_file output ->
    Some task_state_file_recovery_hint
  | _ -> default_recovery_hint classification semantic_status

let ensure_exec_artifact_dir path =
  try Fs_compat.mkdir_p path with
  | Sys_error msg -> Log.Backend.warn "exec artifact mkdir failed: %s" msg
;;

let persist_artifact_if_needed ~base_path ~keeper_name ~cmd ~output =
  if String.length output <= artifact_threshold_bytes
  then None
  else (
    let now = Unix.gettimeofday () in
    let tm = Unix.localtime now in
    let keeper = Playground_paths.sanitize_keeper_name keeper_name in
    let dir =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        (Printf.sprintf
           "exec-artifacts/%s/%04d-%02d-%02d"
           keeper
           (tm.tm_year + 1900)
           (tm.tm_mon + 1)
           tm.tm_mday)
    in
    ensure_exec_artifact_dir dir;
    let digest =
      Digest.to_hex (Digest.string (cmd ^ "\n" ^ output ^ "\n" ^ string_of_float now))
    in
    let digest_prefix = String.sub digest 0 (min 12 (String.length digest)) in
    let path =
      Filename.concat
        dir
        (Printf.sprintf "%d-%s.txt" (int_of_float (now *. 1000.0)) digest_prefix)
    in
    match Fs_compat.save_file_atomic path output with
    | Ok () -> Some { path; bytes = String.length output; storage = Filesystem }
    | Error err ->
      Log.Backend.warn "exec artifact persist failed: %s" err;
      None)
;;

let string_of_artifact_storage = function
  | Filesystem -> "filesystem"
;;

let artifact_ref_to_json artifact_ref =
  `Assoc
    [ "kind", `String "full_output"
    ; "path", `String artifact_ref.path
    ; "bytes", `Int artifact_ref.bytes
    ; "storage", `String (string_of_artifact_storage artifact_ref.storage)
    ]
;;

let artifact_refs_of_output ~artifact_policy ~base_path ~keeper_name ~cmd ~output =
  match artifact_policy with
  | Inline_only -> []
  | Persist_if_large ->
    (match persist_artifact_if_needed ~base_path ~keeper_name ~cmd ~output with
     | Some artifact_ref -> [ artifact_ref ]
     | None -> [])
;;

let default_classification = { family = Unknown; reversibility = Read_only; risk = Low; risk_class = Masc_exec.Shell_ir_risk.R0_Read }

let build_process_outcome ~classification ~artifact_policy ~base_path ~keeper_name ~cmd ~status ~output =
  let semantic_status = semantic_status_of_process ~cmd ~output status in
  let summary = summary_of_status classification semantic_status in
  let retryability = retryability_of_semantic_status semantic_status in
  let artifact_refs =
    artifact_refs_of_output ~artifact_policy ~base_path ~keeper_name ~cmd ~output
  in
  let recovery_hint = recovery_hint_for_output ~cmd ~output classification semantic_status in
  Executed
    { command = cmd
    ; process_status = status
    ; output
    ; semantic_status
    ; classification
    ; summary
    ; retryability
    ; artifact_refs
    ; recovery_hint
    }
;;

let build_blocked_outcome
      ?(classification = default_classification)
      ~cmd
      ~error
      ~reason
      ?hint
      ?(alternatives = [])
      ?(retryability = Self_correct)
      ?(diag = None)
      ()
  =
  let summary = summary_of_status classification Blocked in
  let recovery_hint =
    match hint with
    | Some value -> value
    | None ->
      Option.value
        ~default:"Revise the command or use a more specific shell tool."
        (default_recovery_hint classification Blocked)
  in
  Blocked_result
    { command = cmd
    ; error
    ; reason
    ; hint = recovery_hint
    ; alternatives
    ; classification
    ; retryability
    ; summary
    ; diagnosis = diag
    }
;;

let semantic_payload_to_yojson (key, value) =
  let v : Yojson.Safe.t =
    match value with
    | `String s -> `String s
    | `Int i -> `Int i
    | `Float f -> `Float f
  in
  key, v
;;

let semantic_fields_of_executed (result : executed_result) : (string * Yojson.Safe.t) list
  =
  if not (Masc_exec.Exec_semantic.enabled ())
  then []
  else (
    let sem =
      Masc_exec.Exec_semantic.interpret_cmd
        ~cmd:result.command
        ~status:result.process_status
        ~output:result.output
    in
    let kind = Masc_exec.Exec_semantic.to_kind sem in
    let payload_fields =
      Masc_exec.Exec_semantic.to_payload sem |> List.map semantic_payload_to_yojson
    in
    let hint_field =
      match Masc_exec.Exec_semantic.to_hint sem with
      | None -> []
      | Some h -> [ "hint", `String h ]
    in
    let alternatives_field =
      match Masc_exec.Exec_semantic.to_alternatives sem with
      | [] -> []
      | alts -> [ "alternatives", `List (List.map (fun a -> `String a) alts) ]
    in
    let semantic_obj : Yojson.Safe.t =
      `Assoc ((("kind", `String kind) :: payload_fields) @ hint_field @ alternatives_field)
    in
    let rci_field =
      match Masc_exec.Exec_semantic.to_hint sem with
      | None -> []
      | Some h -> [ "return_code_interpretation", `String h ]
    in
    ("semantic_exit", semantic_obj) :: rci_field)
;;

(* Tick 9: head+tail output cap — opt-in via MASC_BASH_OUTPUT_CAP.
   Defaults match the claude-code EndTruncatingAccumulator shape
   (500 KB head + 500 KB tail).  Overrides via MASC_BASH_CAP_HEAD /
   MASC_BASH_CAP_TAIL let keepers experiment without code changes.
   Applies only to JSON emission; the record keeps the original
   bytes so semantic interpretation and marker inference see the
   full stream. *)
let default_head_cap = 512 * 1024
let default_tail_cap = 512 * 1024

let env_int key =
  match Sys.getenv_opt key with
  | None | Some "" -> None
  | Some s -> int_of_string_opt (String.trim s)
;;

let output_cap_enabled () =
  match Sys.getenv_opt "MASC_BASH_OUTPUT_CAP" with
  | Some ("1" | "true" | "TRUE" | "yes") -> true
  | _ -> false
;;

let cap_output_for_json output =
  if not (output_cap_enabled ())
  then output, None
  else (
    let head_cap =
      Option.value ~default:default_head_cap (env_int "MASC_BASH_CAP_HEAD")
    in
    let tail_cap =
      Option.value ~default:default_tail_cap (env_int "MASC_BASH_CAP_TAIL")
    in
    let head_cap = max 0 head_cap
    and tail_cap = max 0 tail_cap in
    let b = Masc_exec.Exec_buffer.create ~head_cap ~tail_cap in
    Masc_exec.Exec_buffer.add_string b output;
    let rendered = Masc_exec.Exec_buffer.render b in
    let total = Masc_exec.Exec_buffer.total_bytes b in
    let dropped = Masc_exec.Exec_buffer.bytes_dropped b in
    let meta : Yojson.Safe.t =
      `Assoc
        [ "total_bytes", `Int total
        ; "bytes_dropped", `Int dropped
        ; "head_cap", `Int head_cap
        ; "tail_cap", `Int tail_cap
        ]
    in
    rendered, Some meta)
;;

let outcome_to_json ?(extra = []) ?(env_snapshot = None) = function
  | Executed result ->
    let hint_fields =
      match result.recovery_hint with
      | Some hint -> [ "hint", `String hint; "recovery_hint", `String hint ]
      | None -> []
    in
    let capped_output, output_cap_field = cap_output_for_json result.output in
    let cap_field =
      match output_cap_field with
      | None -> []
      | Some meta -> [ "output_cap", meta ]
    in
    let env_field =
      match env_snapshot with
      | None -> []
      | Some snap -> [ "environment", env_snapshot_to_json snap ]
    in
    `Assoc
      ([ "ok", `Bool (semantic_status_is_success result.semantic_status) ]
       @ extra
       @ [ "status", Keeper_alerting_path.process_status_to_json result.process_status
         ; "output", `String capped_output
         ]
       @ cap_field
       @ [ "semantic_status", `String (string_of_semantic_status result.semantic_status)
         ; "classification", classification_to_json result.classification
         ; "retryability", `String (string_of_retryability result.retryability)
         ; "summary", `String result.summary
         ; "artifact_refs", `List (List.map artifact_ref_to_json result.artifact_refs)
         ]
       @ failure_class_field result.semantic_status
       @ hint_fields
       @ semantic_fields_of_executed result
       @ (match
            Masc_exec.Output_parse.try_parse
              ~cmd:result.command
              ~status:result.process_status
              ~output:result.output
          with
          | None -> []
          | Some json -> [ "structured_output", json ])
       @ env_field)
  | Blocked_result result ->
    let alternatives_field =
      match result.alternatives with
      | [] -> []
      | alts -> [ "alternatives", `List (List.map (fun a -> `String a) alts) ]
    in
    let diagnosis_field =
      match result.diagnosis with
      | None -> []
      | Some d ->
        let rewrite_field =
          match d.rewrite with
          | None -> []
          | Some r -> [ "rewrite", `String r ]
        in
        let tool_field =
          match d.tool_suggestion with
          | None -> []
          | Some t -> [ "tool_suggestion", `String t ]
        in
        [ ( "diagnosis"
          , `Assoc
              ([ "rule_id", `String d.rule_id; "explanation", `String d.explanation ]
               @ rewrite_field
               @ tool_field) )
        ]
    in
    let env_field =
      match env_snapshot with
      | None -> []
      | Some snap -> [ "environment", env_snapshot_to_json snap ]
    in
    `Assoc
      ([ "ok", `Bool false
       ; "error", `String result.error
       ; "reason", `String result.reason
       ]
       @ extra
       @ [ "semantic_status", `String (string_of_semantic_status Blocked)
         ; "classification", classification_to_json result.classification
         ; "retryability", `String (string_of_retryability result.retryability)
         ; "summary", `String result.summary
         ; "hint", `String result.hint
         ; "recovery_hint", `String result.hint
         ]
       @ failure_class_field Blocked
       @ diagnosis_field
       @ alternatives_field
       @ env_field)
;;

let process_result_json
      ?(artifact_policy = Persist_if_large)
      ?classification
      ~base_path
      ~keeper_name
      ~cmd
      ?(extra = [])
      ?(env_snapshot = None)
      ~status
      ~output
      ()
  =
  build_process_outcome
    ~classification:(Option.value classification ~default:default_classification)
    ~artifact_policy ~base_path ~keeper_name ~cmd ~status ~output
  |> outcome_to_json ~extra ~env_snapshot
;;

let blocked_result_json
      ?classification
      ~cmd
      ~error
      ~reason
      ?hint
      ?(alternatives = [])
      ?(retryability = Self_correct)
      ?(diag = None)
      ?(extra = [])
      ?(env_snapshot = None)
      ()
  =
  (match classification with
   | Some c -> build_blocked_outcome ~classification:c ~cmd ~error ~reason ?hint ~alternatives ~retryability ~diag ()
   | None -> build_blocked_outcome ~cmd ~error ~reason ?hint ~alternatives ~retryability ~diag ())
  |> outcome_to_json ~extra ~env_snapshot
;;
