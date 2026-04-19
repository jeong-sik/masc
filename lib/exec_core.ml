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

type artifact_policy =
  | Inline_only
  | Persist_if_large

type classification = {
  family : command_family;
  reversibility : reversibility;
  risk : risk;
  write_intent : bool;
}

type artifact_storage =
  | Filesystem

type artifact_ref = {
  path : string;
  bytes : int;
  storage : artifact_storage;
}

type executed_result = {
  command : string;
  process_status : Unix.process_status;
  output : string;
  semantic_status : semantic_status;
  classification : classification;
  summary : string;
  retryability : retryability;
  artifact_refs : artifact_ref list;
  recovery_hint : string option;
}

type blocked_result = {
  command : string;
  error : string;
  reason : string;
  hint : string;
  classification : classification;
  retryability : retryability;
  summary : string;
}

type outcome =
  | Executed of executed_result
  | Blocked_result of blocked_result

let env_int name default =
  match Sys.getenv_opt name with
  | Some value -> (match int_of_string_opt value with Some parsed -> parsed | None -> default)
  | None -> default

let artifact_threshold_bytes =
  max 1024 (env_int "MASC_EXEC_ARTIFACT_THRESHOLD_BYTES" 16384)

type quote_state =
  | No_quote
  | Single_quote
  | Double_quote

let strip_wrapping_quotes token =
  let len = String.length token in
  if len >= 2 then
    match token.[0], token.[len - 1] with
    | '\'', '\''
    | '"', '"' ->
        String.sub token 1 (len - 2)
    | _ -> token
  else
    token

let split_shell_fragments ~separator text =
  let fragments = ref [] in
  let buf = Buffer.create (String.length text) in
  let quote_state = ref No_quote in
  let escaped = ref false in
  let push_fragment () =
    let fragment = Buffer.contents buf |> String.trim in
    Buffer.clear buf;
    if fragment <> "" then fragments := fragment :: !fragments
  in
  String.iter
    (fun ch ->
      if !escaped then (
        Buffer.add_char buf ch;
        escaped := false)
      else
        match !quote_state, ch with
        | Single_quote, '\'' ->
            Buffer.add_char buf ch;
            quote_state := No_quote
        | Single_quote, _ ->
            Buffer.add_char buf ch
        | Double_quote, '"' ->
            Buffer.add_char buf ch;
            quote_state := No_quote
        | Double_quote, '\\' ->
            Buffer.add_char buf ch;
            escaped := true
        | Double_quote, _ ->
            Buffer.add_char buf ch
        | No_quote, '\\' ->
            Buffer.add_char buf ch;
            escaped := true
        | No_quote, '\'' ->
            Buffer.add_char buf ch;
            quote_state := Single_quote
        | No_quote, '"' ->
            Buffer.add_char buf ch;
            quote_state := Double_quote
        | No_quote, _ when separator ch ->
            push_fragment ()
        | No_quote, _ ->
            Buffer.add_char buf ch)
    text;
  push_fragment ();
  List.rev !fragments

let split_words text =
  split_shell_fragments
    ~separator:(function
      | ' ' | '\t' | '\r' | '\n' -> true
      | _ -> false)
    text
  |> List.map strip_wrapping_quotes

let pipeline_segments cmd =
  split_shell_fragments ~separator:(fun ch -> ch = '|') cmd

let first_segment_tokens cmd =
  match pipeline_segments cmd with
  | [] -> []
  | segment :: _ -> split_words segment

let last_segment_tokens cmd =
  match List.rev (pipeline_segments cmd) with
  | [] -> []
  | segment :: _ -> split_words segment

let git_global_option_takes_value = function
  | "-c" | "-C" | "--exec-path" | "--git-dir" | "--work-tree"
  | "--namespace" | "--super-prefix" | "--config-env" -> true
  | _ -> false

let git_global_option_has_inline_value token =
  List.exists (fun prefix -> String.starts_with ~prefix token)
    [ "--exec-path="; "--git-dir="; "--work-tree="; "--namespace="; "--config-env=" ]

let rec first_git_subcommand = function
  | [] -> None
  | token :: rest when git_global_option_takes_value token ->
      (match rest with
       | _value :: tail -> first_git_subcommand tail
       | [] -> None)
  | token :: rest when git_global_option_has_inline_value token ->
      first_git_subcommand rest
  | token :: rest when String.starts_with ~prefix:"-" token ->
      first_git_subcommand rest
  | token :: _ -> Some token

let base_command_of_tokens = function
  | [] -> None
  | token :: _ -> Some (Filename.basename token)

let last_base_command cmd =
  last_segment_tokens cmd |> base_command_of_tokens

let second_token = function
  | _cmd :: sub :: _ -> Some sub
  | _ -> None

let looks_like_test_command ~base ~sub =
  match String.lowercase_ascii base, Option.map String.lowercase_ascii sub with
  | ("pytest" | "pyright" | "ruff"), _ -> true
  | "cargo", Some ("test" | "check" | "clippy") -> true
  | "dune", Some ("runtest" | "test") -> true
  | "make", Some "test" -> true
  | ("npm" | "pnpm" | "yarn"), Some ("test" | "lint" | "typecheck" | "check") -> true
  | ("python" | "python3" | "node" | "go"), Some "test" -> true
  | _ -> false

let family_of_base_command ~cmd ~tokens ~base =
  let sub = second_token tokens in
  let write_intent = Worker_dev_tools.is_write_operation cmd in
  match String.lowercase_ascii base with
  | "git" ->
      (match first_git_subcommand
               (match tokens with
                | _ :: rest -> rest
                | [] -> [])
       with
       | Some "clone" -> Clone
       | _ -> if write_intent then Git_write else Git_read)
  | "rg" | "grep" | "find" -> Search
  | "ls" | "tree" | "du" -> List
  | "cat" | "head" | "tail" | "wc" | "pwd" | "env" | "which"
  | "file" | "stat" | "cut" | "sort" | "uniq" | "tr" | "sed" ->
      Read
  | "curl" | "wget" -> Network_read
  | "npm" | "pnpm" | "yarn" | "pip" | "opam" ->
      if write_intent then Package_install
      else if looks_like_test_command ~base ~sub then Test
      else Build
  | "cargo" | "dune" | "make" | "go" | "gofmt" | "gradle" | "mvn"
  | "cmake" | "ninja" | "java" | "javac" | "node" | "npx"
  | "python" | "python3" | "rustc" | "uv" ->
      if looks_like_test_command ~base ~sub then Test else Build
  | _ -> Unknown

let reversibility_of_command ~cmd family =
  if Worker_dev_tools.is_destructive_bash_operation cmd then Irreversible
  else
    match family with
    | Read | Search | List | Build | Test | Git_read | Network_read -> Read_only
    | Package_install | Clone | Git_write | Unknown -> Reversible

let risk_of_command ~cmd ~write_intent family =
  if Worker_dev_tools.is_destructive_bash_operation cmd then High
  else
    match family with
    | Git_write | Package_install | Clone -> High
    | Unknown when write_intent -> High
    | Build | Test | Network_read | Unknown -> Medium
    | Read | Search | List | Git_read -> Low

let classify_command ~cmd =
  let tokens = first_segment_tokens cmd in
  let write_intent = Worker_dev_tools.is_write_operation cmd in
  let family =
    match base_command_of_tokens tokens with
    | Some base -> family_of_base_command ~cmd ~tokens ~base
    | None -> Unknown
  in
  {
    family;
    reversibility = reversibility_of_command ~cmd family;
    risk = risk_of_command ~cmd ~write_intent family;
    write_intent;
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

let string_of_reversibility = function
  | Read_only -> "read_only"
  | Reversible -> "reversible"
  | Irreversible -> "irreversible"

let string_of_risk = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"

let classification_to_json classification =
  `Assoc
    [
      ("family", `String (string_of_command_family classification.family));
      ( "reversibility",
        `String (string_of_reversibility classification.reversibility) );
      ("risk", `String (string_of_risk classification.risk));
      ("write_intent", `Bool classification.write_intent);
    ]

let process_status_is_timeout = function
  | Unix.WSIGNALED sig_num -> sig_num = Sys.sigterm
  | Unix.WEXITED 124 -> true
  | _ -> false

let string_of_semantic_status = function
  | Ok -> "ok"
  | No_match -> "no_match"
  | Partial -> "partial"
  | Blocked -> "blocked"
  | Timeout -> "timeout"
  | Runtime_error -> "runtime_error"

let string_of_retryability = function
  | None_ -> "none"
  | Self_correct -> "self_correct"
  | Operator_required -> "operator_required"

let non_empty_lines output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let is_find_diagnostic_line line =
  let trimmed = String.trim line in
  String.starts_with ~prefix:"find:" trimmed
  || String.starts_with ~prefix:"find " trimmed

let semantic_status_of_find_output output =
  let lines = non_empty_lines output in
  let has_result_line =
    List.exists (fun line -> not (is_find_diagnostic_line line)) lines
  in
  let has_diagnostic_line = List.exists is_find_diagnostic_line lines in
  if has_result_line && has_diagnostic_line then Partial else Runtime_error

let semantic_status_of_process ~cmd ~output status =
  if process_status_is_timeout status then Timeout
  else
    match status with
    | Unix.WEXITED 0 -> Ok
    | Unix.WEXITED 1 ->
        (match last_base_command cmd with
         | Some ("rg" | "grep") -> No_match
         | Some "find" -> semantic_status_of_find_output output
         | _ -> Runtime_error)
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Runtime_error

let retryability_of_semantic_status = function
  | Ok -> None_
  | Blocked | No_match | Partial | Timeout | Runtime_error -> Self_correct

let semantic_status_is_success = function
  | Ok | No_match -> true
  | Blocked | Timeout | Runtime_error -> false
  | Partial -> false

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

let summary_of_status classification semantic_status =
  let label = family_label classification.family in
  match semantic_status with
  | Ok -> Printf.sprintf "%s command completed." (String.capitalize_ascii label)
  | No_match -> Printf.sprintf "%s completed with no matches." (String.capitalize_ascii label)
  | Partial -> Printf.sprintf "%s completed with partial results." (String.capitalize_ascii label)
  | Blocked -> Printf.sprintf "%s command blocked before execution." (String.capitalize_ascii label)
  | Timeout -> Printf.sprintf "%s command timed out." (String.capitalize_ascii label)
  | Runtime_error -> Printf.sprintf "%s command failed at runtime." (String.capitalize_ascii label)

let default_recovery_hint classification semantic_status =
  match semantic_status with
  | Ok -> None
  | No_match ->
      Some
        (match classification.family with
         | Search ->
             "Adjust the search pattern or narrow the target path, then retry."
         | _ ->
             "Retry with a narrower command or switch to a structured shell op.")
  | Partial ->
      Some "Inspect the output for partial results and retry with a narrower scope if needed."
  | Timeout ->
      Some "Narrow the command scope, reduce output volume, or increase timeout_sec moderately."
  | Runtime_error ->
      Some "Inspect the command output, then retry with a narrower command or a structured shell op."
  | Blocked ->
      Some "Revise the command or switch to the structured shell tool that matches the intent."

let ensure_exec_artifact_dir path =
  try Fs_compat.mkdir_p path
  with
  | Sys_error msg ->
      Logs.warn (fun f -> f "exec artifact mkdir failed: %s" msg)

let persist_artifact_if_needed ~base_path ~keeper_name ~cmd ~output =
  if String.length output <= artifact_threshold_bytes then
    None
  else
    let now = Unix.gettimeofday () in
    let tm = Unix.localtime now in
    let keeper = Playground_paths.sanitize_keeper_name keeper_name in
    let dir =
      Filename.concat base_path
        (Printf.sprintf ".masc/exec-artifacts/%s/%04d-%02d-%02d"
           keeper
           (tm.tm_year + 1900)
           (tm.tm_mon + 1)
           tm.tm_mday)
    in
    ensure_exec_artifact_dir dir;
    let digest =
      Digest.to_hex (Digest.string (cmd ^ "\n" ^ output ^ "\n" ^ string_of_float now))
    in
    let digest_prefix =
      String.sub digest 0 (min 12 (String.length digest))
    in
    let path =
      Filename.concat dir
        (Printf.sprintf "%d-%s.txt"
           (int_of_float (now *. 1000.0))
           digest_prefix)
    in
    match Fs_compat.save_file_atomic path output with
    | Ok () -> Some { path; bytes = String.length output; storage = Filesystem }
    | Error err ->
        Logs.warn (fun f -> f "exec artifact persist failed: %s" err);
        None

let string_of_artifact_storage = function
  | Filesystem -> "filesystem"

let artifact_ref_to_json artifact_ref =
  `Assoc
    [
      ("kind", `String "full_output");
      ("path", `String artifact_ref.path);
      ("bytes", `Int artifact_ref.bytes);
      ("storage", `String (string_of_artifact_storage artifact_ref.storage));
    ]

let artifact_refs_of_output ~artifact_policy ~base_path ~keeper_name ~cmd ~output =
  match artifact_policy with
  | Inline_only -> []
  | Persist_if_large ->
      (match persist_artifact_if_needed ~base_path ~keeper_name ~cmd ~output with
       | Some artifact_ref -> [ artifact_ref ]
       | None -> [])

let build_process_outcome ~artifact_policy ~base_path ~keeper_name ~cmd ~status
    ~output =
  let classification = classify_command ~cmd in
  let semantic_status = semantic_status_of_process ~cmd ~output status in
  let summary = summary_of_status classification semantic_status in
  let retryability = retryability_of_semantic_status semantic_status in
  let artifact_refs =
    artifact_refs_of_output ~artifact_policy ~base_path ~keeper_name ~cmd
      ~output
  in
  let recovery_hint =
    match default_recovery_hint classification semantic_status with
    | Some hint -> Some hint
    | None -> None
  in
  Executed
    {
      command = cmd;
      process_status = status;
      output;
      semantic_status;
      classification;
      summary;
      retryability;
      artifact_refs;
      recovery_hint;
    }

let build_blocked_outcome ~cmd ~error ~reason ?hint ?(retryability = Self_correct) () =
  let classification = classify_command ~cmd in
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
    {
      command = cmd;
      error;
      reason;
      hint = recovery_hint;
      classification;
      retryability;
      summary;
    }

let semantic_payload_to_yojson (key, value) =
  let v : Yojson.Safe.t =
    match value with
    | `String s -> `String s
    | `Int i -> `Int i
    | `Float f -> `Float f
  in
  (key, v)

let semantic_fields_of_executed (result : executed_result) :
    (string * Yojson.Safe.t) list =
  if not (Masc_exec.Exec_semantic.enabled ()) then []
  else
    let sem =
      Masc_exec.Exec_semantic.interpret_cmd
        ~cmd:result.command
        ~status:result.process_status
        ~output:result.output
    in
    let kind = Masc_exec.Exec_semantic.to_kind sem in
    let payload_fields =
      Masc_exec.Exec_semantic.to_payload sem
      |> List.map semantic_payload_to_yojson
    in
    let hint_field =
      match Masc_exec.Exec_semantic.to_hint sem with
      | None -> []
      | Some h -> [ "hint", `String h ]
    in
    let semantic_obj : Yojson.Safe.t =
      `Assoc (("kind", `String kind) :: payload_fields @ hint_field)
    in
    let rci_field =
      match Masc_exec.Exec_semantic.to_hint sem with
      | None -> []
      | Some h -> [ "return_code_interpretation", `String h ]
    in
    ("semantic_exit", semantic_obj) :: rci_field

let outcome_to_json ?(extra = []) = function
  | Executed result ->
      let hint_fields =
        match result.recovery_hint with
        | Some hint ->
            [ ("hint", `String hint); ("recovery_hint", `String hint) ]
        | None -> []
      in
      `Assoc
        ([
           ("ok", `Bool (semantic_status_is_success result.semantic_status));
         ]
         @ extra
         @ [
             ( "status",
               Keeper_alerting_path.process_status_to_json result.process_status );
             ("output", `String result.output);
             ( "semantic_status",
               `String (string_of_semantic_status result.semantic_status) );
             ("classification", classification_to_json result.classification);
             ("retryability", `String (string_of_retryability result.retryability));
             ("summary", `String result.summary);
             ("artifact_refs", `List (List.map artifact_ref_to_json result.artifact_refs));
           ]
         @ hint_fields
         @ semantic_fields_of_executed result)
  | Blocked_result result ->
      `Assoc
        ([
           ("ok", `Bool false);
           ("error", `String result.error);
           ("reason", `String result.reason);
         ]
         @ extra
         @ [
             ("semantic_status", `String (string_of_semantic_status Blocked));
             ("classification", classification_to_json result.classification);
             ("retryability", `String (string_of_retryability result.retryability));
             ("summary", `String result.summary);
             ("hint", `String result.hint);
             ("recovery_hint", `String result.hint);
           ])

let process_result_json ?(artifact_policy = Persist_if_large) ~base_path
    ~keeper_name ~cmd ?(extra = []) ~status ~output () =
  build_process_outcome ~artifact_policy ~base_path ~keeper_name ~cmd ~status
    ~output
  |> outcome_to_json ~extra

let blocked_result_json ~cmd ~error ~reason ?hint ?(retryability = Self_correct)
    ?(extra = []) () =
  build_blocked_outcome ~cmd ~error ~reason ?hint ~retryability ()
  |> outcome_to_json ~extra
