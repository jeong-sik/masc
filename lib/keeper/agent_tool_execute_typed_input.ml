type exec_stage = {
  executable : string;
  argv : string list;
}

type execute_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
    }
  | Pipeline of {
      stages : exec_stage list;
      cwd : string option;
      env : (string * string) list;
    }

type allowlist_mode =
  | Dev_full
  | Readonly

type validation_error =
  | Executable_not_allowlisted of {
      name : string;
      mode : allowlist_mode;
    }
  | Empty_executable of { argv : string list }
  | Empty_argv of { executable : string }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
  | Cwd_not_absolute of string
  | Pipeline_empty
  | Pipeline_too_short
  | Env_key_invalid of string

let is_allowed ~mode name =
  match mode with
  | Dev_full -> Dev_exec_allowlist.is_dev_allowed name
  | Readonly -> Dev_exec_allowlist.is_readonly_allowed name
;;

let json_type_name (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ -> "object"
  | `Bool _ -> "boolean"
  | `Float _ -> "number"
  | `Int _ -> "integer"
  | `Intlit _ -> "integer"
  | `List _ -> "array"
  | `Null -> "null"
  | `String _ -> "string"
;;

let result_errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

let assoc_fields ~path (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> Ok fields
  | value ->
    result_errorf
      "%s must be object, got %s"
      path
      (json_type_name value)
;;

let member fields key = List.assoc_opt key fields

let reject_unknown_fields ~path ~allowed fields =
  let allowed key = List.exists (String.equal key) allowed in
  match List.find_opt (fun (key, _) -> not (allowed key)) fields with
  | None -> Ok ()
  | Some (key, _) ->
    result_errorf "%s.%s is not a supported typed Execute field" path key
;;

let required_string ~path fields key =
  match member fields key with
  | Some (`String value) -> Ok value
  | Some value ->
    result_errorf
      "%s.%s must be string, got %s"
      path
      key
      (json_type_name value)
  | None -> result_errorf "%s.%s is required" path key
;;

let optional_string ~path fields key =
  match member fields key with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some value ->
    result_errorf
      "%s.%s must be string, got %s"
      path
      key
      (json_type_name value)
;;

let optional_string_list ~path fields key =
  match member fields key with
  | None | Some `Null -> Ok []
  | Some (`List values) ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> loop (index + 1) (value :: acc) rest
      | value :: _ ->
        result_errorf
          "%s.%s[%d] must be string, got %s"
          path
          key
          index
          (json_type_name value)
    in
    loop 0 [] values
  | Some value ->
    result_errorf
      "%s.%s must be array, got %s"
      path
      key
      (json_type_name value)
;;

let optional_env ~path fields =
  match member fields "env" with
  | None | Some `Null -> Ok []
  | Some (`Assoc bindings) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (key, `String value) :: rest -> loop ((key, value) :: acc) rest
      | (key, value) :: _ ->
        result_errorf
          "%s.env.%s must be string, got %s"
          path
          key
          (json_type_name value)
    in
    loop [] bindings
  | Some value ->
    result_errorf
      "%s.env must be object, got %s"
      path
      (json_type_name value)
;;

let parse_stage ~path_prefix ~index (value : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "%s[%d]" path_prefix index in
  let* fields = assoc_fields ~path value in
  let* () = reject_unknown_fields ~path ~allowed:[ "executable"; "argv" ] fields in
  let* executable = required_string ~path fields "executable" in
  let* argv = optional_string_list ~path fields "argv" in
  Ok { executable; argv }
;;

let parse_pipeline ~path (json : Yojson.Safe.t) =
  match json with
  | `List values ->
    let ( let* ) = Result.bind in
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* stage = parse_stage ~path_prefix:path ~index value in
        loop (index + 1) (stage :: acc) rest
    in
    loop 0 [] values
  | value ->
    result_errorf "%s must be array, got %s" path (json_type_name value)
;;

let of_json (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let* fields = assoc_fields ~path:"$" json in
  let* () =
    if Option.is_some (member fields "cmd")
    then
      Error
        "cmd string is not a typed Shell IR input; provide \
         executable/argv or pipeline"
    else Ok ()
  in
  let* () =
    reject_unknown_fields
      ~path:"$"
      ~allowed:[ "executable"; "argv"; "pipeline"; "cwd"; "env"; "timeout_sec" ]
      fields
  in
  let executable_present = Option.is_some (member fields "executable") in
  let pipeline_value =
    match member fields "pipeline" with
    | Some value -> Some ("$.pipeline", value)
    | None -> None
  in
  let* cwd = optional_string ~path:"$" fields "cwd" in
  let* env = optional_env ~path:"$" fields in
  match executable_present, pipeline_value with
  | true, Some _ ->
    Error
      "$.executable and $.pipeline are mutually exclusive typed Execute \
       fields. Pick exactly one form and drop the other: either {executable, \
       argv} for a single process OR {pipeline} for a multi-stage Shell IR \
       pipeline. To pipe through a process, put it in pipeline; do not \
       combine."
  | true, None ->
    let* executable = required_string ~path:"$" fields "executable" in
    let* argv = optional_string_list ~path:"$" fields "argv" in
    Ok (Exec { executable; argv; cwd; env })
  | false, Some (path, value) ->
    let* stages = parse_pipeline ~path value in
    Ok (Pipeline { stages; cwd; env })
  | false, None -> Error "$.executable or $.pipeline is required"
;;

(* Execve-style: argv tokens pass verbatim to the child process, so
   shell metacharacters ([;|&><`$*?]) are literal data, not operators.
   Only control characters that cannot survive process-boundary
   serialization are rejected.  See .mli "Design constraints" for the
   rationale. *)
let shell_metachar_in_token token =
  String.exists
    (function
      | '\000' | '\n' | '\r' -> true
      | _ -> false)
    token
;;

let check_argv ~executable argv =
  let rec loop i = function
    | [] -> Ok ()
    | token :: rest when shell_metachar_in_token token ->
      Error (Argv_contains_shell_metachar { executable; index = i; token })
    | _ :: rest -> loop (i + 1) rest
  in
  loop 0 argv
;;

let check_cwd = function
  | None -> Ok ()
  | Some path when String.length path > 0 && path.[0] = '/' -> Ok ()
  | Some path -> Error (Cwd_not_absolute path)
;;

let check_env env =
  let key_ok k =
    String.length k > 0
    && String.for_all
         (function
           | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
           | _ -> false)
         k
  in
  let rec loop = function
    | [] -> Ok ()
    | (k, _) :: _ when not (key_ok k) -> Error (Env_key_invalid k)
    | _ :: rest -> loop rest
  in
  loop env
;;

let check_wrapper_target ~mode ~wrapper_name = function
  | None -> Error (Empty_argv { executable = wrapper_name })
  | Some target when is_allowed ~mode target -> Ok ()
  | Some target -> Error (Executable_not_allowlisted { name = target; mode })
;;

let check_wrapper_exec_target ~mode ~executable ~argv =
  match executable with
  | "env" ->
    check_wrapper_target
      ~mode
      ~wrapper_name:"env"
      (Exec_policy_command_syntax.command_after_env_prefix argv)
  | "opam" -> (
    match Exec_policy_command_syntax.opam_exec_command_name argv with
    | Some "opam" -> Ok ()
    | target -> check_wrapper_target ~mode ~wrapper_name:"opam" target)
  | _ -> Ok ()
;;

let check_exec ~mode ~executable ~argv ~cwd ~env =
  let ( let* ) = Result.bind in
  let trimmed = String.trim executable in
  if String.length trimmed = 0 then Error (Empty_executable { argv })
  else if not (is_allowed ~mode trimmed)
  then Error (Executable_not_allowlisted { name = trimmed; mode })
  else
    let* () =
      if argv = [] then Ok () else check_argv ~executable argv
    in
    let* () = check_wrapper_exec_target ~mode ~executable:trimmed ~argv in
    let* () = check_cwd cwd in
    let* () = check_env env in
    Ok ()
;;

let validate ~mode = function
  | Exec { executable; argv; cwd; env } ->
    check_exec ~mode ~executable ~argv ~cwd ~env
  | Pipeline { stages = []; _ } -> Error Pipeline_empty
  | Pipeline { stages = [ _ ]; _ } -> Error Pipeline_too_short
  | Pipeline { stages; cwd; env } ->
    let ( let* ) = Result.bind in
    let* () = check_cwd cwd in
    let* () = check_env env in
    let rec each = function
      | [] -> Ok ()
      | { executable; argv } :: rest ->
        let* () = check_exec ~mode ~executable ~argv ~cwd:None ~env:[] in
        each rest
    in
    each stages
;;

let shell_bin ~mode ~argv executable =
  let trimmed = String.trim executable in
  if String.length trimmed = 0 then Error (Empty_executable { argv })
  else
    match Masc_exec.Exec_program.of_string trimmed with
    | Ok bin -> Ok bin
    | Error (`Unknown name) ->
      Error (Executable_not_allowlisted { name = trimmed; mode })
;;

let shell_simple ~mode ?(sandbox = Masc_exec.Sandbox_target.host ()) ?cwd ?(env = []) { executable; argv } =
  let ( let* ) = Result.bind in
  let* bin = shell_bin ~mode ~argv executable in
  Ok
    (Agent_tool_execute_shell_ir.simple_bin
       ?cwd_raw:cwd
       ?cwd_base:cwd
       ~sandbox
       ~env
       bin
       argv)
;;

let to_shell_ir_unvalidated ?(sandbox = Masc_exec.Sandbox_target.host ()) ~mode input =
  let ( let* ) = Result.bind in
  match input with
  | Exec { executable; argv; cwd; env } ->
    let stage = { executable; argv } in
    shell_simple ~mode ~sandbox ?cwd ~env stage
  | Pipeline { stages; cwd; env } ->
    let* simples =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | stage :: rest ->
          let* simple = shell_simple ~mode ~sandbox ?cwd ~env stage in
          loop (simple :: acc) rest
      in
      loop [] stages
    in
    Ok (Agent_tool_execute_shell_ir.pipeline simples)
;;

let to_shell_ir ?sandbox ~mode input =
  let ( let* ) = Result.bind in
  let* () = validate ~mode input in
  to_shell_ir_unvalidated ?sandbox ~mode input
;;

let pp_mode ppf = function
  | Dev_full -> Format.pp_print_string ppf "dev_full"
  | Readonly -> Format.pp_print_string ppf "readonly"
;;

let executable_not_allowlisted_hint ~name ~mode =
  if String.starts_with ~prefix:"keeper_" name || String.starts_with ~prefix:"masc_" name
  then
    Some
      "MASC tool names are not shell programs; call the visible JSON tool with \
       arguments instead of running it through Execute."
  else
    match mode, name with
    | Readonly, "gh" | Readonly, "git" ->
      Some
        "This preset is read-only. Use ReadFile/SearchFiles when visible; \
         otherwise ask for a write/execute-capable schema before using git/gh."
    | _, "bash" | _, "sh" | _, "zsh" ->
      Some
        "Shell interpreters are intentionally unavailable. Use typed \
         executable/argv, or explicit pipeline stages, without shell syntax."
    | _, "rm" | _, "chmod" | _, "chown" | _, "sudo" ->
      Some
        "This executable is privileged/destructive. Use a dedicated structured \
         workflow, a non-destructive inspection command, or ask the operator."
    | _, "jq" ->
      Some
        "jq is not part of Execute. Use typed task/board tools for MASC \
         state, or inspect files with ReadFile/SearchFiles and parse only the \
         needed fields."
    | _, "curl" ->
      Some
        "Network fetches are not available through Execute. Use a dedicated \
         structured integration/tool if one is visible."
    | _ -> None
;;

let pp_validation_error ppf = function
  | Executable_not_allowlisted { name; mode } ->
    (match executable_not_allowlisted_hint ~name ~mode with
     | None -> Format.fprintf ppf "executable %S not in %a allowlist" name pp_mode mode
     | Some hint ->
       Format.fprintf
         ppf
         "executable %S not in %a allowlist. %s"
         name
         pp_mode
         mode
         hint)
  | Empty_executable { argv = first :: rest } ->
    Format.fprintf
      ppf
      "executable is empty; argv[0]=%S looks like the command name. \
       Rewrite as executable=%S argv=%s. Do not include the executable in argv."
      first
      first
      (Yojson.Safe.to_string (`List (List.map (fun arg -> `String arg) rest)))
  | Empty_executable { argv = [] } ->
    Format.pp_print_string ppf
      "executable is empty — provide a non-empty allowlisted command name, \
       e.g. executable=\"cat\" argv=[\"file.txt\"]"
  | Empty_argv { executable } ->
    Format.fprintf ppf "executable %S invoked with empty argv" executable
  | Argv_contains_shell_metachar { executable; index; token } ->
    Format.fprintf
      ppf
      "executable %S argv[%d]=%S contains shell metacharacter; \
       split into Pipeline stages instead"
      executable
      index
      token
  | Cwd_not_absolute path ->
    Format.fprintf ppf "cwd %S is not absolute" path
  | Pipeline_empty -> Format.pp_print_string ppf "Pipeline.stages is empty"
  | Pipeline_too_short ->
    Format.pp_print_string ppf "Pipeline.stages requires at least two stages"
  | Env_key_invalid k ->
    Format.fprintf ppf "env key %S is not [A-Za-z0-9_]+" k
;;
