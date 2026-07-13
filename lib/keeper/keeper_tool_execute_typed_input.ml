type exec_stage = {
  executable : string;
  argv : string list;
}

type redirect_target =
  | Inherit
  | Discard
  | File of string

type execute_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
      stdin : redirect_target;
      stdout : redirect_target;
      stderr : redirect_target;
      timeout_sec : float option;
    }
  | Pipeline of {
      stages : exec_stage list;
      cwd : string option;
      env : (string * string) list;
      timeout_sec : float option;
    }

type validation_error =
  | Empty_executable of { argv : string list }
  | Executable_repeated_in_argv0 of {
      executable : string;
      argv : string list;
    }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
  | Argv_contains_shell_pipeline_operator of {
      executable : string;
      index : int;
      token : string;
    }
  | Argv_contains_shell_redirection of {
      executable : string;
      index : int;
      token : string;
    }
  | Redirect_path_not_absolute of {
      fd : int;
      path : string;
    }
  | Cwd_not_absolute of string
  | Pipeline_empty
  | Pipeline_too_short
  | Env_key_invalid of string
  | Timeout_sec_not_positive of float

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

(* RFC-0198 Phase B: parse a [stdin]/[stdout]/[stderr] field into a
   [redirect_target].  Accepted forms (all optional; absent or null
   defaults to [Inherit]):

   - [{"discard": true}]    → [Discard]
   - [{"file": "/abs/path"}] → [File path]

   Anything else is rejected at JSON boundary so absolute-path and
   value-range validation can stay outside [validate]. *)
let optional_redirect_target ~path fields key =
  match member fields key with
  | None | Some `Null -> Ok Inherit
  | Some (`Assoc props) ->
    (match List.assoc_opt "discard" props, List.assoc_opt "file" props with
     | Some (`Bool true), None -> Ok Discard
     | Some (`Bool false), None -> Ok Inherit
     | None, Some (`String path_value) -> Ok (File path_value)
     | Some _, Some _ ->
       result_errorf
         "%s.%s must specify exactly one of {discard:true} or \
          {file:\"/abs/path\"}; received both"
         path
         key
     | _ ->
       result_errorf
         "%s.%s must be {discard:true} or {file:\"/abs/path\"}"
         path
         key)
  | Some value ->
    result_errorf
      "%s.%s must be object, got %s"
      path
      key
      (json_type_name value)
;;

(* [timeout_sec] shape check only: accepts a JSON int or float and stores it
   unvalidated.  Positivity/finiteness is [validate]'s job (check_timeout_sec
   below), mirroring how [cwd]'s absolute-path check lives in [validate]
   rather than here. *)
let optional_timeout_sec ~path fields key =
  match member fields key with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (float_of_int value))
  | Some value ->
    result_errorf
      "%s.%s must be number, got %s"
      path
      key
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
      ~allowed:
        [ "executable"
        ; "argv"
        ; "pipeline"
        ; "cwd"
        ; "env"
        ; "timeout_sec"
        ; "stdin"
        ; "stdout"
        ; "stderr"
        ]
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
  let* timeout_sec = optional_timeout_sec ~path:"$" fields "timeout_sec" in
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
    let* stdin = optional_redirect_target ~path:"$" fields "stdin" in
    let* stdout = optional_redirect_target ~path:"$" fields "stdout" in
    let* stderr = optional_redirect_target ~path:"$" fields "stderr" in
    Ok (Exec { executable; argv; cwd; env; stdin; stdout; stderr; timeout_sec })
  | false, Some (path, value) ->
    (* RFC-0198 Phase B 한계: typed redirect triple(stdin/stdout/stderr)은 [Exec]
       variant에만 존재하고 [Pipeline]에는 없다. 그런데 이 세 키는
       reject_unknown_fields 허용 목록(위 reject_unknown_fields ~allowed)에 들어
       있어 pipeline과 함께 와도 파싱은 통과하고, [Pipeline { stages; cwd; env }]가
       redirect를 버려 조용히 폐기된다 — silent failure. 명시적으로 거부해 사일런트
       드롭을 차단한다. 근본 해결(Pipeline endpoint redirect 실제 지원)은 [Pipeline]
       variant에 redirect_target triple을 추가하는 타입 확장이며 후속 작업이다. *)
    let redirect_present key =
      match member fields key with
      | None | Some `Null -> false
      | Some _ -> true
    in
    if
      redirect_present "stdin"
      || redirect_present "stdout"
      || redirect_present "stderr"
    then
      Error
        "$.stdin / $.stdout / $.stderr are not supported with $.pipeline; typed \
         redirects apply only to the single-process {executable, argv} form. \
         Put the redirecting command in its own pipeline stage, or use the \
         {executable, argv} form with the typed redirect fields."
    else
      let* stages = parse_pipeline ~path value in
      Ok (Pipeline { stages; cwd; env; timeout_sec })
  | false, None -> Error "$.executable or $.pipeline is required"
;;

(* Execve-style: argv tokens pass verbatim to the child process, so shell
   metacharacters ([;|&><`$*?]) and line breaks inside a payload token are
   literal data, not operators.  NUL is the only byte that cannot be
   represented inside an argv string.  See .mli "Design constraints" for the
   rationale. *)
let shell_metachar_in_token token =
  String.exists
    (function
      | '\000' -> true
      | _ -> false)
    token
;;

(* A standalone pipe token is almost always a caller attempting shell syntax
   inside direct Exec.argv.  Unlike payload tokens such as [foo|bar], ["|"]
   cannot create a pipe in execve argv and commonly becomes a bogus filename
   ([tail: |: No such file or directory]).  Keep this narrow: [;] is a valid
   argv sentinel for find -exec, and [&] can be payload data. *)
let looks_like_shell_pipeline_operator = function
  | "|" | "|&" -> true
  | _ -> false
;;

(* RFC-0198 Phase A.  Detects argv tokens whose entire shape matches a
   shell redirection operator.  These cannot do anything useful inside
   execve argv — the child sees them as literal text, which most
   programs ([find], [grep], [test]) misparse and fail at runtime
   ([find: 2>/dev/null: unknown primary]).  Rejecting at validation
   surfaces the contract violation as a typed alternative pointing at
   RFC-0198 Phase B typed redirect fields or Pipeline mode.

   Conservative recognizer: only matches tokens that are *exclusively*
   a redirection operator (with optional leading fd digit and attached
   path).  Tokens that merely *contain* [>] or [<] as part of payload
   data ([find -name '*>foo'], [grep '<<<']) pass through unchanged. *)
let is_digit c = c >= '0' && c <= '9'
let is_path_start c = c = '/' || c = '.' || c = '~'

let looks_like_shell_redirection token =
  let len = String.length token in
  if len = 0
  then false
  else
    let op_start =
      (* Skip optional leading fd digit like [2>] or [0<]. *)
      if is_digit token.[0] then 1 else 0
    in
    if op_start >= len
    then false
    else
      let c = token.[op_start] in
      if c = '>' || c = '<'
      then
        let rest = op_start + 1 in
        if rest >= len
        then true (* [>], [<], [2>], [0<] *)
        else
          let nxt = token.[rest] in
          if c = '>' && nxt = '>'
          then
            if rest + 1 >= len
            then true (* [>>] alone *)
            else
              let nxt2 = token.[rest + 1] in
              nxt2 = '&' || is_path_start nxt2 (* [>>&N], [>>/...], [>>./...] *)
          else
            (* [>X] / [<X] where X = &digit, /, ., ~ *)
            (nxt = '&' && rest + 1 < len && is_digit token.[rest + 1])
            || is_path_start nxt
      else if op_start = 0 && c = '&' && len >= 2 && is_digit token.[1]
      then true (* [&1], [&2] — fd reference standalone *)
      else false
;;

let check_argv ~executable argv =
  let rec loop i = function
    | [] -> Ok ()
    | token :: _ when shell_metachar_in_token token ->
      Error (Argv_contains_shell_metachar { executable; index = i; token })
    | token :: _ when looks_like_shell_pipeline_operator token ->
      Error
        (Argv_contains_shell_pipeline_operator { executable; index = i; token })
    | token :: _ when looks_like_shell_redirection token ->
      Error (Argv_contains_shell_redirection { executable; index = i; token })
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

let check_timeout_sec = function
  | None -> Ok ()
  | Some v when Float.is_finite v && v > 0.0 -> Ok ()
  | Some v -> Error (Timeout_sec_not_positive v)
;;

let check_exec ~executable ~argv ~cwd ~env =
  let ( let* ) = Result.bind in
  let trimmed = String.trim executable in
  if String.length trimmed = 0 then Error (Empty_executable { argv })
  else (
    let* () =
      if argv = [] then Ok () else check_argv ~executable argv
    in
    let* () = check_cwd cwd in
    let* () = check_env env in
    Ok ())
;;

let check_redirect_target ~fd = function
  | Inherit | Discard -> Ok ()
  | File path when String.length path > 0 && path.[0] = '/' -> Ok ()
  | File path -> Error (Redirect_path_not_absolute { fd; path })
;;

let check_redirects ~stdin ~stdout ~stderr =
  let ( let* ) = Result.bind in
  let* () = check_redirect_target ~fd:0 stdin in
  let* () = check_redirect_target ~fd:1 stdout in
  check_redirect_target ~fd:2 stderr
;;

let validate = function
  | Exec { executable; argv; cwd; env; stdin; stdout; stderr; timeout_sec } ->
    let ( let* ) = Result.bind in
    let* () = check_exec ~executable ~argv ~cwd ~env in
    let* () = check_redirects ~stdin ~stdout ~stderr in
    check_timeout_sec timeout_sec
  | Pipeline { stages = []; _ } -> Error Pipeline_empty
  | Pipeline { stages = [ _ ]; _ } -> Error Pipeline_too_short
  | Pipeline { stages; cwd; env; timeout_sec } ->
    let ( let* ) = Result.bind in
    let* () = check_cwd cwd in
    let* () = check_env env in
    let* () = check_timeout_sec timeout_sec in
    let rec each = function
      | [] -> Ok ()
      | { executable; argv } :: rest ->
        let* () = check_exec ~executable ~argv ~cwd:None ~env:[] in
        each rest
    in
    each stages
;;

let shell_bin ~argv executable =
  let trimmed = String.trim executable in
  if String.length trimmed = 0 then Error (Empty_executable { argv })
  else
    match Masc_exec.Exec_program.of_string trimmed with
    | Ok bin -> Ok bin
    | Error (`Unknown _) -> Error (Empty_executable { argv })
;;

let shell_simple
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?cwd
      ?(env = [])
      ?(redirects = [])
      { executable; argv }
  =
  let ( let* ) = Result.bind in
  let* bin = shell_bin ~argv executable in
  Ok
    (Keeper_tool_execute_shell_ir.simple_bin
       ?cwd_raw:cwd
       ?cwd_base:cwd
       ~sandbox
       ~env
       ~redirects
       bin
       argv)
;;

(* RFC-0198 Phase B: lower the typed [redirect_target] triple into the
   IR-level [Redirect_scope.t list].  [Inherit] yields no IR entry —
   the child simply inherits the parent's fd.  [Discard] resolves to
   [/dev/null] with the fd-appropriate mode (read for fd=0, write for
   fd=1/2).  [File path] uses the caller-supplied absolute path; the
   validation gate already rejected relative paths via
   {!Redirect_path_not_absolute}. *)
let redirects_of ~cwd ~stdin ~stdout ~stderr =
  let cwd_str = Option.value cwd ~default:"/" in
  let classify path = Masc_exec.Path_scope.classify ~raw:path ~cwd:cwd_str in
  let entry fd mode = function
    | Inherit -> None
    | Discard ->
      Some
        (Masc_exec.Redirect_scope.File
           { fd; target = classify "/dev/null"; mode })
    | File path ->
      Some
        (Masc_exec.Redirect_scope.File
           { fd; target = classify path; mode })
  in
  List.filter_map
    (fun x -> x)
    [ entry 0 Masc_exec.Redirect_scope.Read stdin
    ; entry 1 Masc_exec.Redirect_scope.Write stdout
    ; entry 2 Masc_exec.Redirect_scope.Write stderr
    ]
;;

let to_shell_ir_unvalidated ?(sandbox = Masc_exec.Sandbox_target.host ()) input =
  let ( let* ) = Result.bind in
  match input with
  | Exec { executable; argv; cwd; env; stdin; stdout; stderr; timeout_sec = _ } ->
    let stage = { executable; argv } in
    let redirects = redirects_of ~cwd ~stdin ~stdout ~stderr in
    shell_simple ~sandbox ?cwd ~env ~redirects stage
  | Pipeline { stages; cwd; env; timeout_sec = _ } ->
    let* simples =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | { executable; argv } :: rest ->
          let stage = { executable; argv } in
          let* simple = shell_simple ~sandbox ?cwd ~env stage in
          loop (simple :: acc) rest
      in
      loop [] stages
    in
    Ok (Keeper_tool_execute_shell_ir.pipeline simples)
;;

let to_shell_ir ?sandbox input =
  let ( let* ) = Result.bind in
  let* () = validate input in
  to_shell_ir_unvalidated ?sandbox input
;;

let pp_validation_error ppf = function
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
      "executable is empty — provide a non-empty executable name, \
       e.g. executable=\"cat\" argv=[\"file.txt\"]"
  | Executable_repeated_in_argv0 { executable; argv = _ :: rest } ->
    Format.fprintf
      ppf
      "executable %S is repeated as argv[0]; typed Execute argv contains \
       only arguments after the executable. Rewrite as executable=%S argv=%s."
      executable
      executable
      (Yojson.Safe.to_string (`List (List.map (fun arg -> `String arg) rest)))
  | Executable_repeated_in_argv0 { executable; argv = [] } ->
    Format.fprintf
      ppf
      "executable %S was reported as duplicated in argv[0], but argv is empty"
      executable
  | Argv_contains_shell_metachar { executable; index; token } ->
    Format.fprintf
      ppf
      "executable %S argv[%d]=%S contains NUL; typed Execute argv strings \
       cannot contain NUL bytes"
      executable
      index
      token
  | Argv_contains_shell_pipeline_operator { executable; index; token } ->
    Format.fprintf
      ppf
      "executable %S argv[%d]=%S is a shell pipeline operator; argv tokens \
       are passed verbatim to execve and never create pipelines. Retry \
       Execute with the top-level pipeline field, e.g. \
       pipeline=[{executable;argv},...]. Do not wrap this in sh/bash and do \
       not put %S in argv."
      executable
      index
      token
      token
  | Argv_contains_shell_redirection { executable; index; token } ->
    Format.fprintf
      ppf
      "executable %S argv[%d]=%S is a shell redirection operator; argv \
       tokens are passed verbatim to execve and never interpreted as \
       redirection. Use the typed redirect fields (RFC-0198 Phase B: \
       stderr={discard:true}, stdout={discard:true}, or \
       {file:\"/abs/path\"}) or use Execute.pipeline."
      executable
      index
      token
  | Redirect_path_not_absolute { fd; path } ->
    let label =
      match fd with
      | 0 -> "stdin"
      | 1 -> "stdout"
      | 2 -> "stderr"
      | n -> Printf.sprintf "fd=%d" n
    in
    Format.fprintf
      ppf
      "%s redirect target %S is not absolute; typed Execute redirect \
       paths must be absolute (e.g. \"/tmp/out.log\")"
      label
      path
  | Cwd_not_absolute path ->
    Format.fprintf ppf "cwd %S is not absolute" path
  | Pipeline_empty -> Format.pp_print_string ppf "pipeline is empty"
  | Pipeline_too_short ->
    Format.pp_print_string ppf "pipeline requires at least two stages"
  | Env_key_invalid k ->
    Format.fprintf ppf "env key %S is not [A-Za-z0-9_]+" k
  | Timeout_sec_not_positive v ->
    Format.fprintf
      ppf
      "timeout_sec %.3f must be a finite number greater than 0"
      v
;;

let validation_error_alternatives : validation_error -> string list = function
  | Empty_executable _ -> []
  | Executable_repeated_in_argv0 _ -> []
  | Argv_contains_shell_metachar _ -> []
  | Argv_contains_shell_pipeline_operator _ -> [ "Execute.pipeline" ]
  | Argv_contains_shell_redirection _ ->
    [ "stderr:{discard:true}"; "stdout:{discard:true}"; "Execute.pipeline" ]
  | Redirect_path_not_absolute _ -> []
  | Cwd_not_absolute _ -> []
  | Pipeline_empty -> []
  | Pipeline_too_short -> []
  | Env_key_invalid _ -> []
  (* No alternative field exists: the fix is a valid value in the same
     [timeout_sec] field, already stated by [pp_validation_error]. *)
  | Timeout_sec_not_positive _ -> []
;;
