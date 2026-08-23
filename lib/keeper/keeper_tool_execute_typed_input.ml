(* Where a stage's standard streams attach. Reading and writing admit
   different shapes -- a source cannot be truncated, a sink cannot be read --
   so they are separate types. One shared type would have to carry a field
   that one direction ignores, and an ignored field is a value the caller can
   set and never see honoured. *)
type input_source =
  | Inherit_input
  | Empty_input
  | Read_file of { path : string }
  | Input_from_fd of int

type output_sink =
  | Inherit_output
  | Discard_output
  | Truncate_file of { path : string }
  | Append_file of { path : string }
  | Output_to_fd of int

type exec_stage = {
  argv : string list;
  stdin : input_source;
  stdout : output_sink;
  stderr : output_sink;
}

(* A command is one or more stages, each owning its own redirections. The
   head/tail split makes the empty program unrepresentable, so there is no
   emptiness to validate; a single process is simply a program whose tail is
   empty, which is why redirections and multi-stage piping are no longer
   alternatives the caller has to choose between. *)
type program = {
  head : exec_stage;
  tail : exec_stage list;
}

type execute_input = {
  program : program;
  cwd : string option;
  env : (string * string) list;
  timeout_sec : float option;
}

type validation_error =
  | Empty_argv
  | Empty_program
  | Argv_contains_nul of {
      index : int;
      token : string;
    }
  | Redirect_path_not_absolute of {
      fd : int;
      path : string;
    }
  | Cwd_not_absolute of string
  | Redirect_fd_unknown of {
      fd : int;
      target : int;
    }
  | Env_key_invalid of string

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

let optional_positive_float ~path fields key =
  let validate value =
    if Float.is_finite value && Float.compare value 0.0 > 0
    then Ok (Some value)
    else result_errorf "%s.%s must be finite and greater than zero" path key
  in
  match member fields key with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> validate value
  | Some (`Int value) -> validate (Float.of_int value)
  | Some (`Intlit value) ->
    (match Float.of_string_opt value with
     | Some value -> validate value
     | None -> result_errorf "%s.%s must be a valid number" path key)
  | Some value ->
    result_errorf
      "%s.%s must be number, got %s"
      path
      key
      (json_type_name value)
;;

let required_string_list ~path fields key =
  match member fields key with
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
  | None -> result_errorf "%s.%s is required" path key
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

(* A redirection is an object naming exactly one shape. This reads the object
   and hands the named properties to the direction's own decoder; which names
   are legal is the direction's business, not this function's. Absent or null
   means the stream is not redirected. *)
let redirect_props ~path ~key fields =
  match member fields key with
  | None | Some `Null -> Ok None
  | Some (`Assoc props) -> Ok (Some props)
  | Some value ->
    result_errorf "%s.%s must be object, got %s" path key (json_type_name value)
;;

(* [stdin] takes bytes from somewhere: inherit, nothing, a file, or another
   descriptor of the same stage. There is no write mode to name, so naming one
   is an error rather than a field this decoder drops on the floor. *)
let optional_input_source ~path fields key =
  let ( let* ) = Result.bind in
  let* props = redirect_props ~path ~key fields in
  match props with
  | None -> Ok Inherit_input
  | Some props ->
    let reject () =
      result_errorf
        "%s.%s must name exactly one of {discard:true}, {file:\"/abs/path\"} or \
         {fd:N}"
        path
        key
    in
    (match
       ( List.assoc_opt "discard" props
       , List.assoc_opt "file" props
       , List.assoc_opt "fd" props
       , List.length props )
     with
     | Some (`Bool true), None, None, 1 -> Ok Empty_input
     | Some (`Bool false), None, None, 1 -> Ok Inherit_input
     | None, Some (`String path_value), None, 1 -> Ok (Read_file { path = path_value })
     | None, None, Some (`Int target), 1 -> Ok (Input_from_fd target)
     | _ -> reject ())
;;

(* [stdout]/[stderr] give bytes to somewhere. A file sink must say which of the
   two shell modes it is: [truncate] replaces the file, [append] adds to it.
   Neither is a safe guess for the other, so the shape carries the answer and
   there is no default to fall back on. *)
let optional_output_sink ~path fields key =
  let ( let* ) = Result.bind in
  let* props = redirect_props ~path ~key fields in
  match props with
  | None -> Ok Inherit_output
  | Some props ->
    let reject () =
      result_errorf
        "%s.%s must name exactly one of {discard:true}, \
         {truncate:\"/abs/path\"}, {append:\"/abs/path\"} or {fd:N}"
        path
        key
    in
    (match
       ( List.assoc_opt "discard" props
       , List.assoc_opt "truncate" props
       , List.assoc_opt "append" props
       , List.assoc_opt "fd" props
       , List.length props )
     with
     | Some (`Bool true), None, None, None, 1 -> Ok Discard_output
     | Some (`Bool false), None, None, None, 1 -> Ok Inherit_output
     | None, Some (`String path_value), None, None, 1 ->
       Ok (Truncate_file { path = path_value })
     | None, None, Some (`String path_value), None, 1 ->
       Ok (Append_file { path = path_value })
     | None, None, None, Some (`Int target), 1 -> Ok (Output_to_fd target)
     | _ -> reject ())
;;

let stage_of_fields ~path fields =
  let ( let* ) = Result.bind in
  let* argv = required_string_list ~path fields "argv" in
  let* stdin = optional_input_source ~path fields "stdin" in
  let* stdout = optional_output_sink ~path fields "stdout" in
  let* stderr = optional_output_sink ~path fields "stderr" in
  Ok { argv; stdin; stdout; stderr }
;;

let stage_fields = [ "argv"; "stdin"; "stdout"; "stderr" ]

let parse_stage ~path_prefix ~index (value : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "%s[%d]" path_prefix index in
  let* fields = assoc_fields ~path value in
  let* () = reject_unknown_fields ~path ~allowed:stage_fields fields in
  stage_of_fields ~path fields
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

(* Splits off the last element while keeping the caller's non-emptiness in the
   arguments: the first element is a separate parameter, so there is no empty
   case to handle. Returns the last element and everything before it. *)
let rec split_last first rest =
  match rest with
  | [] -> first, []
  | next :: more ->
    let last, middle = split_last next more in
    last, first :: middle
;;

let of_json (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let* fields = assoc_fields ~path:"$" json in
  let* () =
    if Option.is_some (member fields "cmd")
    then
      Error
        "cmd string is not a typed Shell IR input; provide \
         argv or pipeline"
    else Ok ()
  in
  let* () =
    reject_unknown_fields
      ~path:"$"
      ~allowed:
        [ "argv"
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
  let argv_present = Option.is_some (member fields "argv") in
  let pipeline_value =
    match member fields "pipeline" with
    | Some value -> Some ("$.pipeline", value)
    | None -> None
  in
  let* cwd = optional_string ~path:"$" fields "cwd" in
  let* env = optional_env ~path:"$" fields in
  let* timeout_sec = optional_positive_float ~path:"$" fields "timeout_sec" in
  match argv_present, pipeline_value with
  | true, Some _ ->
    Error
      "$.argv and $.pipeline are mutually exclusive typed Execute \
       fields. Pick exactly one form and drop the other: either {argv} for a \
       single process OR {pipeline} for a multi-stage Shell IR \
       pipeline. To pipe through a process, put it in pipeline; do not \
       combine."
  | true, None ->
    let* head = stage_of_fields ~path:"$" fields in
    Ok { program = { head; tail = [] }; cwd; env; timeout_sec }
  | false, Some (path, value) ->
    let* stages = parse_pipeline ~path value in
    (* Top-level redirections describe the program's own ends, which is where
       a shell puts them: stdin feeds the first stage and stdout/stderr come
       off the last. A stage that declared its own keeps it — the explicit
       one wins over the program-level default. *)
    let* stdin = optional_input_source ~path:"$" fields "stdin" in
    let* stdout = optional_output_sink ~path:"$" fields "stdout" in
    let* stderr = optional_output_sink ~path:"$" fields "stderr" in
    let default_input fallback = function
      | Inherit_input -> fallback
      | declared -> declared
    in
    let default_output fallback = function
      | Inherit_output -> fallback
      | declared -> declared
    in
    (match stages with
     | [] -> result_errorf "%s must contain at least one stage" path
     | [ only ] ->
       let only =
         { only with
           stdin = default_input stdin only.stdin
         ; stdout = default_output stdout only.stdout
         ; stderr = default_output stderr only.stderr
         }
       in
       Ok { program = { head = only; tail = [] }; cwd; env; timeout_sec }
     | head :: second :: rest ->
       let head = { head with stdin = default_input stdin head.stdin } in
       let last, middle = split_last second rest in
       let last =
         { last with
           stdout = default_output stdout last.stdout
         ; stderr = default_output stderr last.stderr
         }
       in
       Ok
         { program = { head; tail = middle @ [ last ] }; cwd; env; timeout_sec })
  | false, None -> Error "$.argv or $.pipeline is required"
;;

let check_argv argv =
  let rec loop i = function
    | [] -> Ok ()
    | token :: _ when String.contains token '\000' ->
      Error (Argv_contains_nul { index = i; token })
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

let check_exec ~argv ~cwd ~env =
  let ( let* ) = Result.bind in
  match argv with
  | [] -> Error Empty_argv
  | program :: _ when String.equal program "" -> Error Empty_program
  | _ ->
    let* () = check_argv argv in
    let* () = check_cwd cwd in
    let* () = check_env env in
    Ok ()
;;

(* A stage owns exactly the three standard descriptors, so duplicating any
   other number would name a descriptor the stage does not have. Naming them
   keeps the numbers out of the call sites that attach each stream. *)
let stdin_fd = 0
let stdout_fd = 1
let stderr_fd = 2
let standard_fds = [ stdin_fd; stdout_fd; stderr_fd ]

let check_path ~fd path =
  if String.length path > 0 && path.[0] = '/' then Ok ()
  else Error (Redirect_path_not_absolute { fd; path })
;;

let check_fd ~fd target =
  if List.exists (Int.equal target) standard_fds then Ok ()
  else Error (Redirect_fd_unknown { fd; target })
;;

let check_input_source ~fd = function
  | Inherit_input | Empty_input -> Ok ()
  | Read_file { path } -> check_path ~fd path
  | Input_from_fd target -> check_fd ~fd target
;;

let check_output_sink ~fd = function
  | Inherit_output | Discard_output -> Ok ()
  | Truncate_file { path } | Append_file { path } -> check_path ~fd path
  | Output_to_fd target -> check_fd ~fd target
;;

let check_stage_redirects { argv = _; stdin; stdout; stderr } =
  let ( let* ) = Result.bind in
  let* () = check_input_source ~fd:stdin_fd stdin in
  let* () = check_output_sink ~fd:stdout_fd stdout in
  check_output_sink ~fd:stderr_fd stderr
;;

let stages_of { head; tail } = head :: tail

let validate { program; cwd; env; timeout_sec = _ } =
  let ( let* ) = Result.bind in
  let* () = check_cwd cwd in
  let* () = check_env env in
  let rec each = function
    | [] -> Ok ()
    | stage :: rest ->
      let* () = check_exec ~argv:stage.argv ~cwd:None ~env:[] in
      let* () = check_stage_redirects stage in
      each rest
  in
  each (stages_of program)
;;

let shell_bin = function
  | [] -> Error Empty_argv
  | program :: argv ->
    (match Masc_exec.Exec_program.of_string program with
     | Ok bin -> Ok (bin, argv)
     | Error (`Unknown _) -> Error Empty_program)
;;

let shell_simple
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?cwd
      ?(env = [])
      ?(redirects = [])
      argv
  =
  let ( let* ) = Result.bind in
  let* bin, arguments = shell_bin argv in
  Ok
    (Keeper_tooling.Execute_shell_ir.simple_bin
       ?cwd_raw:cwd
       ?cwd_base:cwd
       ~sandbox
       ~env
       ~redirects
       bin
       arguments)
;;

(* The device that supplies no bytes and swallows every byte written to it. *)
let dev_null = "/dev/null"

(* Each direction lowers to the IR without asking which way its fd flows: the
   source always opens for reading and the sink knows its own write mode. An
   inherited stream yields no IR entry — the child keeps the parent's
   descriptor. *)
let input_entry ~classify source =
  let file path =
    Some
      (Masc_exec.Redirect_scope.File
         { fd = stdin_fd; target = classify path; mode = Masc_exec.Redirect_scope.Read })
  in
  match source with
  | Inherit_input -> None
  | Empty_input -> file dev_null
  | Read_file { path } -> file path
  | Input_from_fd src ->
    Some (Masc_exec.Redirect_scope.Fd_to_fd { src = stdin_fd; dst = src })
;;

let output_entry ~classify ~fd sink =
  let file ~path ~mode =
    Some (Masc_exec.Redirect_scope.File { fd; target = classify path; mode })
  in
  match sink with
  | Inherit_output -> None
  | Discard_output -> file ~path:dev_null ~mode:Masc_exec.Redirect_scope.Write
  | Truncate_file { path } -> file ~path ~mode:Masc_exec.Redirect_scope.Write
  | Append_file { path } -> file ~path ~mode:Masc_exec.Redirect_scope.Append
  | Output_to_fd src -> Some (Masc_exec.Redirect_scope.Fd_to_fd { src = fd; dst = src })
;;

let redirects_of_stage ~cwd { argv = _; stdin; stdout; stderr } =
  let cwd_str = Option.value cwd ~default:"/" in
  let classify path = Masc_exec.Path_scope.classify ~raw:path ~cwd:cwd_str in
  List.filter_map
    (fun x -> x)
    [ input_entry ~classify stdin
    ; output_entry ~classify ~fd:stdout_fd stdout
    ; output_entry ~classify ~fd:stderr_fd stderr
    ]
;;

let to_shell_ir_unvalidated
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      { program; cwd; env; timeout_sec = _ }
  =
  let ( let* ) = Result.bind in
  let lower stage =
    shell_simple
      ~sandbox
      ?cwd
      ~env
      ~redirects:(redirects_of_stage ~cwd stage)
      stage.argv
  in
  match program with
  | { head; tail = [] } -> lower head
  | { head; tail } ->
    let* simples =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | stage :: rest ->
          let* simple = lower stage in
          loop (simple :: acc) rest
      in
      loop [] (head :: tail)
    in
    Ok (Keeper_tooling.Execute_shell_ir.pipeline simples)
;;

let to_shell_ir ?sandbox input =
  let ( let* ) = Result.bind in
  let* () = validate input in
  to_shell_ir_unvalidated ?sandbox input
;;

let pp_validation_error ppf = function
  | Empty_argv ->
    Format.pp_print_string ppf
      "argv is empty — provide a non-empty process vector, \
       e.g. argv=[\"cat\",\"file.txt\"]"
  | Empty_program ->
    Format.pp_print_string ppf
      "argv[0] is empty — provide a non-empty program token"
  | Argv_contains_nul { index; token } ->
    Format.fprintf
      ppf
      "argv[%d]=%S contains NUL; typed Execute argv strings \
       cannot contain NUL bytes"
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
  | Redirect_fd_unknown { fd; target } ->
    Format.fprintf
      ppf
      "fd=%d cannot duplicate fd=%d; a stage owns only 0, 1 and 2"
      fd
      target
  | Env_key_invalid k ->
    Format.fprintf ppf "env key %S is not [A-Za-z0-9_]+" k
;;
