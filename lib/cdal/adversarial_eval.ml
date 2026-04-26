(** Adversarial_eval — Fresh-context adversarial evaluator.

    Structural checks only. No LLM inference. *)

type allowed_input =
  | Diff of string
  | Changed_file of
      { path : string
      ; content : string
      }
  | Type_signature of
      { module_name : string
      ; signature : string
      }
  | Interface_contract of
      { path : string
      ; content : string
      }

type banned_input_kind =
  | Readme
  | Design_doc
  | Coord_history
  | Task_history
  | Governance_history

type advisory_finding =
  { finding_id : string
  ; severity : string
  ; category : string
  ; summary : string
  ; location : string option
  }

type eval_context =
  { inputs : allowed_input list
  ; session_id : string
  ; evaluator_version : string
  }

type eval_result =
  { findings : advisory_finding list
  ; input_count : int
  ; is_advisory : bool
  }

let evaluator_version = "0.1.0"

(* --- Red line enforcement --- *)

let banned_readme_patterns = [ "readme"; "readme.md"; "readme.txt"; "readme.rst" ]

let banned_doc_patterns =
  [ "design"
  ; "architecture"
  ; "adr"
  ; "rfc"
  ; "spec"
  ; "contributing"
  ; "changelog"
  ; "license"
  ]
;;

let doc_extensions = [ ".md"; ".markdown"; ".mdx"; ".txt"; ".rst"; ".adoc"; ".asciidoc" ]
let data_artifact_extensions = [ ".json"; ".jsonl"; ".yaml"; ".yml"; ".log"; ".txt" ]

let normalize_path path =
  String.map (fun c -> if c = '\\' then '/' else c) path |> String.lowercase_ascii
;;

let contains_substring = String_util.contains_substring
let has_doc_extension path = List.exists (Filename.check_suffix path) doc_extensions

let has_data_artifact_extension path =
  List.exists (Filename.check_suffix path) data_artifact_extensions
;;

let has_history_artifact_extension path =
  has_doc_extension path || has_data_artifact_extension path
;;

let split_path_segments path =
  String.split_on_char '/' path
  |> List.filter (fun segment -> segment <> "" && segment <> ".")
;;

let tokenize_segment segment =
  let len = String.length segment in
  let is_token_char = function
    | 'a' .. 'z' | '0' .. '9' -> true
    | _ -> false
  in
  let rec collect start idx acc =
    if idx = len
    then if start < idx then String.sub segment start (idx - start) :: acc else acc
    else if is_token_char segment.[idx]
    then collect start (idx + 1) acc
    else (
      let acc =
        if start < idx then String.sub segment start (idx - start) :: acc else acc
      in
      collect (idx + 1) (idx + 1) acc)
  in
  List.rev (collect 0 0 [])
;;

let classify_path path =
  let normalized = normalize_path path in
  let lower = Filename.basename normalized in
  let segments = split_path_segments normalized in
  let dir_segments =
    match List.rev segments with
    | _basename :: rev_dirs -> List.rev rev_dirs
    | [] -> []
  in
  let check_patterns patterns =
    List.exists (fun pat -> String.starts_with ~prefix:pat lower) patterns
  in
  let basename_tokens = tokenize_segment lower in
  let segment_has_token segment token = List.mem token (tokenize_segment segment) in
  let has_doc_dir =
    List.exists
      (fun segment ->
         List.mem
           segment
           [ "docs"; "doc"; "design"; "adr"; "rfcs"; "rfc"; "spec"; "specs" ])
      dir_segments
  in
  let has_doc_token =
    List.exists
      (fun segment -> List.exists (segment_has_token segment) banned_doc_patterns)
      segments
  in
  let has_room_history =
    has_history_artifact_extension lower
    && List.exists
         (contains_substring normalized)
         [ "room_history"
         ; "room-history"
         ; "roomtaskhistory"
         ; "room_task_history"
         ; "room-task-history"
         ]
  in
  let has_task_history =
    has_history_artifact_extension lower
    && List.exists
         (contains_substring normalized)
         [ "task_history"
         ; "task-history"
         ; "taskhistory"
         ; "room/task_history"
         ; "room/task-history"
         ]
  in
  let has_governance_history =
    (List.mem "governance" basename_tokens && has_data_artifact_extension lower)
    || (has_history_artifact_extension lower
        && List.exists (contains_substring normalized) [ "session_log"; "session-log" ])
    || (List.mem "retrospective" basename_tokens && has_history_artifact_extension lower)
  in
  if check_patterns banned_readme_patterns
  then Some Readme
  else if has_room_history
  then Some Coord_history
  else if has_task_history
  then Some Task_history
  else if has_governance_history
  then Some Governance_history
  else if has_doc_extension lower && (has_doc_dir || has_doc_token)
  then Some Design_doc
  else None
;;

let validate_inputs inputs =
  let check_path path =
    match classify_path path with
    | Some kind -> Error (path, kind)
    | None -> Ok ()
  in
  let rec validate = function
    | [] -> Ok inputs
    | input :: rest ->
      let result =
        match input with
        | Diff _ -> Ok ()
        | Changed_file { path; _ } -> check_path path
        | Type_signature _ -> Ok ()
        | Interface_contract { path; _ } -> check_path path
      in
      (match result with
       | Error e -> Error e
       | Ok () -> validate rest)
  in
  validate inputs
;;

(* --- Context creation --- *)

let create_context ~session_id ~inputs = { inputs; session_id; evaluator_version }

(* --- Structural checks --- *)

let finding_counter = ref 0

let next_finding_id () =
  incr finding_counter;
  Printf.sprintf "adv-%04d" !finding_counter
;;

(** Check for large diffs that may indicate scope creep. *)
let check_diff_size diff =
  let line_count = String.split_on_char '\n' diff |> List.length in
  if line_count > 500
  then
    Some
      { finding_id = next_finding_id ()
      ; severity = "warn"
      ; category = "scope"
      ; summary =
          Printf.sprintf "Large diff (%d lines) — potential scope creep" line_count
      ; location = None
      }
  else None
;;

(** Check for files without corresponding .mli. *)
let check_missing_interface inputs =
  let ml_files =
    List.filter_map
      (fun input ->
         match input with
         | Changed_file { path; _ } ->
           if Filename.check_suffix path ".ml" then Some path else None
         | _ -> None)
      inputs
  in
  let mli_files =
    List.filter_map
      (fun input ->
         match input with
         | Interface_contract { path; _ } -> Some path
         | _ -> None)
      inputs
  in
  List.filter_map
    (fun ml_path ->
       let mli_path = ml_path ^ "i" in
       if not (List.mem mli_path mli_files)
       then
         Some
           { finding_id = next_finding_id ()
           ; severity = "info"
           ; category = "encapsulation"
           ; summary =
               Printf.sprintf
                 "Changed %s has no corresponding .mli in context"
                 (Filename.basename ml_path)
           ; location = Some ml_path
           }
       else None)
    ml_files
;;

(** Check for potentially unsafe patterns in changed files. *)
let unsafe_patterns =
  [ "Obj.magic", "type-unsafe cast"
  ; "Stdlib.Mutex", "non-Eio mutex in concurrent code"
  ; "ignore (", "silenced return value"
  ; "assert false", "runtime assertion instead of type safety"
  ; "Sys.command", "shell command execution"
  ; "Unix.execvp", "process execution"
  ]
;;

let check_unsafe_patterns inputs =
  List.concat_map
    (fun input ->
       match input with
       | Changed_file { path; content } ->
         List.filter_map
           (fun (pattern, description) ->
              if
                try
                  let pat_len = String.length pattern in
                  let content_len = String.length content in
                  let rec search i =
                    if i + pat_len > content_len
                    then false
                    else if String.sub content i pat_len = pattern
                    then true
                    else search (i + 1)
                  in
                  search 0
                with
                | Invalid_argument _ -> false
              then
                Some
                  { finding_id = next_finding_id ()
                  ; severity = "warn"
                  ; category = "safety"
                  ; summary =
                      Printf.sprintf
                        "Found '%s' (%s) in %s"
                        pattern
                        description
                        (Filename.basename path)
                  ; location = Some path
                  }
              else None)
           unsafe_patterns
       | _ -> [])
    inputs
;;

(** Check for added files without tests. *)
let check_untested_additions inputs =
  let changed_paths =
    List.filter_map
      (fun input ->
         match input with
         | Changed_file { path; _ } -> Some path
         | _ -> None)
      inputs
  in
  let has_test_file =
    List.exists
      (fun path ->
         let base = Filename.basename path in
         String.length base > 5 && String.starts_with ~prefix:"test_" base)
      changed_paths
  in
  let lib_files =
    List.filter
      (fun path ->
         let base = Filename.basename path in
         not (String.length base > 5 && String.starts_with ~prefix:"test_" base))
      changed_paths
  in
  if lib_files <> [] && not has_test_file
  then
    [ { finding_id = next_finding_id ()
      ; severity = "info"
      ; category = "testing"
      ; summary =
          Printf.sprintf
            "%d changed file(s) with no test file in context"
            (List.length lib_files)
      ; location = None
      }
    ]
  else []
;;

(* --- Main evaluation --- *)

let evaluate ctx =
  finding_counter := 0;
  let diff_findings =
    List.filter_map
      (fun input ->
         match input with
         | Diff content -> check_diff_size content
         | Changed_file _ | Type_signature _ | Interface_contract _ -> None)
      ctx.inputs
  in
  let interface_findings = check_missing_interface ctx.inputs in
  let unsafe_findings = check_unsafe_patterns ctx.inputs in
  let test_findings = check_untested_additions ctx.inputs in
  let findings = diff_findings @ interface_findings @ unsafe_findings @ test_findings in
  { findings; input_count = List.length ctx.inputs; is_advisory = true }
;;

(* --- JSON serialization --- *)

let finding_to_yojson (f : advisory_finding) : Yojson.Safe.t =
  `Assoc
    [ "finding_id", `String f.finding_id
    ; "severity", `String f.severity
    ; "category", `String f.category
    ; "summary", `String f.summary
    ; "location", Json_util.string_opt_to_json f.location
    ]
;;

let result_to_yojson (r : eval_result) : Yojson.Safe.t =
  `Assoc
    [ "findings", `List (List.map finding_to_yojson r.findings)
    ; "finding_count", `Int (List.length r.findings)
    ; "input_count", `Int r.input_count
    ; "is_advisory", `Bool r.is_advisory
    ; "evaluator_version", `String evaluator_version
    ]
;;
