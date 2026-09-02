module Shell_gate = Masc_exec_command_gate.Shell_command_gate

(* Where a stage's standard streams attach. Reading and writing admit
   different shapes -- a source cannot be truncated, a sink cannot be read --
   so they are separate types. One shared type would have to carry a field
   that one direction ignores, and an ignored field is a value the caller can
   set and never see honoured. *)
type input_source =
  | Inherit_input
  | Empty_input
  | Read_file of { path : string }
  | Literal_input of { bytes : string }

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

(* A guard reads the status of whatever ran last, so a run of them is left to
   right with no precedence of its own -- the way a shell reads [a && b || c].
   The list is empty for a single program. *)
type conditional =
  | And_then
  | Or_else

(* The shell a script runs under, as a name the closed list in
   [Shell_costume] recognises. It is data rather than a constant because
   [argv:["bash";"-c";S]] normalises to this form and has to keep the shell it
   named: the corpus's 656 [param_expansion] scripts are bash expansions, and
   resolving them under a container's [sh] would be dash. *)
type script = {
  shell : string;
  text : string;
}

(* POSIX, because a script that says nothing should get the shell every image
   has. A caller that needs bash says so, and a normalised costume says what
   its argv said. *)
let default_script_shell = "sh"

type source =
  | Staged of {
      program : program;
      next : (conditional * program) list;
    }
  | Script of script

type execute_input = {
  source : source;
  cwd : string option;
  env : (string * string) list;
  timeout_sec : float option;
}

type validation_error =
  | Empty_argv
  | Empty_program
  | Redirect_outside_the_sandbox_mount of {
      path : string;
      visible_root : string;
    }
  | Directory_change_is_not_a_program of { requested : string }
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
        "%s.%s must name exactly one of {discard:true}, \
         {file:\"/abs/path\"}, or {literal:\"bytes\"}. Omit the key to \
         leave stdin alone; {discard:false} names nothing."
        path
        key
    in
    (match
       ( List.assoc_opt "discard" props
       , List.assoc_opt "file" props
       , List.length props )
     with
     | Some (`Bool true), None, 1 -> Ok Empty_input
     | None, Some (`String path_value), 1 -> Ok (Read_file { path = path_value })
     | _ ->
       (match List.assoc_opt "literal" props, List.length props with
        | Some (`String bytes), 1 -> Ok (Literal_input { bytes })
        | _ -> reject ()))
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
         {truncate:\"/abs/path\"}, {append:\"/abs/path\"} or {fd:N}. Omit the \
         key to leave the stream alone; {discard:false} names nothing."
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

(* The fields that describe one program: which process or pipeline to run and
   where its ends attach. [cwd], [env] and [timeout_sec] belong to the whole
   call, so they are read once by the caller and are not repeated per
   program. *)
let program_fields = [ "argv"; "pipeline"; "stdin"; "stdout"; "stderr" ]

let program_of_fields ~path fields =
  let ( let* ) = Result.bind in
  let argv_present = Option.is_some (member fields "argv") in
  let pipeline_value =
    match member fields "pipeline" with
    | Some value -> Some (path ^ ".pipeline", value)
    | None -> None
  in
  match argv_present, pipeline_value with
  | true, Some _ ->
    result_errorf
      "%s.argv and %s.pipeline are mutually exclusive typed Execute fields. \
       Pick exactly one form and drop the other: either {argv} for a single \
       process OR {pipeline} for a multi-stage Shell IR pipeline. To pipe \
       through a process, put it in pipeline; do not combine."
      path
      path
  | true, None ->
    let* head = stage_of_fields ~path fields in
    Ok { head; tail = [] }
  | false, Some (pipeline_path, value) ->
    let* stages = parse_pipeline ~path:pipeline_path value in
    (* Top-level redirections describe the program's own ends, which is where
       a shell puts them: stdin feeds the first stage and stdout/stderr come
       off the last. A stage that declared its own keeps it — the explicit
       one wins over the program-level default. *)
    let* stdin = optional_input_source ~path fields "stdin" in
    let* stdout = optional_output_sink ~path fields "stdout" in
    let* stderr = optional_output_sink ~path fields "stderr" in
    let default_input fallback = function
      | Inherit_input -> fallback
      | declared -> declared
    in
    let default_output fallback = function
      | Inherit_output -> fallback
      | declared -> declared
    in
    (match stages with
     | [] -> result_errorf "%s must contain at least one stage" pipeline_path
     | [ only ] ->
       let only =
         { only with
           stdin = default_input stdin only.stdin
         ; stdout = default_output stdout only.stdout
         ; stderr = default_output stderr only.stderr
         }
       in
       Ok { head = only; tail = [] }
     | head :: second :: rest ->
       let head = { head with stdin = default_input stdin head.stdin } in
       let last, middle = split_last second rest in
       let last =
         { last with
           stdout = default_output stdout last.stdout
         ; stderr = default_output stderr last.stderr
         }
       in
       Ok { head; tail = middle @ [ last ] })
  | false, None -> result_errorf "%s.argv or %s.pipeline is required" path path
;;

(* Which way the guard has to go for the next program to run. Written as the
   status it waits for, because that is what the caller is thinking about. *)
let conditional_of_string ~path = function
  | "success" -> Ok And_then
  | "failure" -> Ok Or_else
  | other ->
    result_errorf "%s.on must be \"success\" or \"failure\", got %S" path other
;;

let parse_next_entry ~path_prefix ~index (value : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "%s[%d]" path_prefix index in
  let* fields = assoc_fields ~path value in
  let* () = reject_unknown_fields ~path ~allowed:("on" :: program_fields) fields in
  let* on =
    match member fields "on" with
    | Some (`String value) -> conditional_of_string ~path value
    | Some value -> result_errorf "%s.on must be string, got %s" path (json_type_name value)
    | None -> result_errorf "%s.on is required" path
  in
  let* program = program_of_fields ~path fields in
  Ok (on, program)
;;

let optional_next ~path fields =
  let ( let* ) = Result.bind in
  match member fields "then" with
  | None | Some `Null -> Ok []
  | Some (`List entries) ->
    let path_prefix = path ^ ".then" in
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | entry :: rest ->
        let* parsed = parse_next_entry ~path_prefix ~index entry in
        loop (index + 1) (parsed :: acc) rest
    in
    loop 0 [] entries
  | Some value ->
    result_errorf "%s.then must be array, got %s" path (json_type_name value)
;;

(* The schema's [oneOf] and this function are the same rule stated twice: a
   call names one form. Stating it here is what makes [source] a sum rather
   than three optional fields a validator has to reconcile. *)
let source_of_fields ~path fields =
  let ( let* ) = Result.bind in
  let named key =
    match member fields key with
    | None | Some `Null -> false
    | Some _ -> true
  in
  let staged = List.exists named program_fields in
  match named "script", staged with
  | true, true ->
    result_errorf
      "%s names both script and %s; a call takes one form"
      path
      (String.concat "/" (List.filter named program_fields))
  | true, false ->
    let* script = optional_string ~path fields "script" in
    (* [named "script"] is what put us in this arm, so the field is present;
       a default here would turn "not a string" into an empty script. *)
    (match script with
     | None -> result_errorf "%s.script must be a string" path
     | Some script ->
       if String.trim script = ""
       then result_errorf "%s.script is empty" path
       else if named "then"
       then
         result_errorf
           "%s.then belongs to the staged form; a script writes && and || \
            itself"
           path
       else
         let* shell = optional_string ~path fields "shell" in
         let shell = Option.value shell ~default:default_script_shell in
         (* A closed list, and the same one [Shell_costume.of_argv] recognises,
            because an argv-shaped shell normalises into this field and the two
            have to agree on what a shell is. An arbitrary string here would be
            an arbitrary program name. *)
         if not (Keeper_tooling.Shell_costume.names_a_shell shell)
         then
           result_errorf
             "%s.shell is %S; a script runs under one of: %s"
             path
             shell
             (String.concat ", " Keeper_tooling.Shell_costume.shells)
         else Ok (Script { shell; text = script }))
  | false, true ->
    let* program = program_of_fields ~path fields in
    let* next = optional_next ~path fields in
    Ok (Staged { program; next })
  | false, false ->
    (* Nothing named a source. [program_of_fields] would say "argv or
       pipeline is required", which is the truth for a nested [then] entry
       but omits the third form this top level accepts. *)
    result_errorf
      "%s.argv, %s.pipeline or %s.script is required"
      path
      path
      path
;;

let of_json (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  let* fields = assoc_fields ~path:"$" json in
  let* () =
    if Option.is_some (member fields "cmd")
    then
      Error
        "cmd is not a field of this tool; the shell form is named \
         script"
    else Ok ()
  in
  let* () =
    reject_unknown_fields
      ~path:"$"
      ~allowed:
        (program_fields
        @ [ "then"; "cwd"; "env"; "timeout_sec"; "script"; "shell" ])
      fields
  in
  let* cwd = optional_string ~path:"$" fields "cwd" in
  let* env = optional_env ~path:"$" fields in
  let* timeout_sec = optional_positive_float ~path:"$" fields "timeout_sec" in
  let* source = source_of_fields ~path:"$" fields in
  Ok { source; cwd; env; timeout_sec }
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

(* [cd] is the shell's own directory, not a program. Spawned, it changes the
   directory of a child that exits immediately, so whatever the caller chained
   after it never runs. It also ignores the extra arguments and exits zero, so
   the call comes back successful with no output -- an empty answer that reads
   like a real one. Measured: 60 such calls, 56 of them reported successful and
   empty. Refusing it is not a judgement about argv content; there is no
   invocation of [cd] as a program that does anything. *)
let directory_change_program = "cd"

let check_exec ~argv ~cwd ~env =
  let ( let* ) = Result.bind in
  match argv with
  | [] -> Error Empty_argv
  | program :: _ when String.equal program "" -> Error Empty_program
  | program :: _ when String.equal (Filename.basename program) directory_change_program ->
    Error (Directory_change_is_not_a_program { requested = String.concat " " argv })
  | _ ->
    let* () = check_argv argv in
    let* () = check_cwd cwd in
    let* () = check_env env in
    Ok ()
;;

(* Naming the descriptors keeps the numbers out of the call sites that attach
   each stream. Only 1 and 2 can receive a duplicated stream: a merge is
   carried out by the dispatcher on captured output, and stdin is not a
   capture. *)
let stdin_fd = 0
let stdout_fd = 1
let stderr_fd = 2
let duplicable_fds = [ stdout_fd; stderr_fd ]

let check_path ~fd path =
  if String.length path > 0 && path.[0] = '/' then Ok ()
  else Error (Redirect_path_not_absolute { fd; path })
;;

let check_fd ~fd target =
  if List.exists (Int.equal target) duplicable_fds then Ok ()
  else Error (Redirect_fd_unknown { fd; target })
;;

let check_input_source ~fd = function
  (* A literal names no path, so the path boundary has nothing to check. *)
  | Inherit_input | Empty_input | Literal_input _ -> Ok ()
  | Read_file { path } -> check_path ~fd path
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

(* [Script] has no stages to walk before it is parsed, and the checks that
   walk them are not skipped: [Execute_shell_ir.dispatch] runs the typed gate
   and [validate_paths] over the lowered [Shell_ir.t], which is the same value
   the staged form produces. What is checked here is what a string cannot
   carry -- the call's own [cwd] and [env]. *)
let validate { source; cwd; env; timeout_sec = _ } =
  let ( let* ) = Result.bind in
  let* () = check_cwd cwd in
  let* () = check_env env in
  match source with
  | Script _ -> Ok ()
  | Staged { program; next = _ } ->
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
let input_entry ~resolve source =
  let ( let* ) = Result.bind in
  let file path =
    let* target = resolve path in
    Ok
      (Some
         (Masc_exec.Redirect_scope.File
            { fd = stdin_fd; target; mode = Masc_exec.Redirect_scope.Read }))
  in
  match source with
  | Inherit_input -> Ok None
  | Empty_input -> file dev_null
  | Read_file { path } -> file path
  | Literal_input { bytes } ->
    Ok (Some (Masc_exec.Redirect_scope.Literal { bytes }))
;;

let output_entry ~resolve ~fd sink =
  let ( let* ) = Result.bind in
  let file ~path ~mode =
    let* target = resolve path in
    Ok (Some (Masc_exec.Redirect_scope.File { fd; target; mode }))
  in
  match sink with
  | Inherit_output -> Ok None
  | Discard_output -> file ~path:dev_null ~mode:Masc_exec.Redirect_scope.Write
  | Truncate_file { path } -> file ~path ~mode:Masc_exec.Redirect_scope.Write
  | Append_file { path } -> file ~path ~mode:Masc_exec.Redirect_scope.Append
  | Output_to_fd src ->
    Ok (Some (Masc_exec.Redirect_scope.Fd_to_fd { src = fd; dst = src }))
;;

(* Where a redirect target lives. A keeper in a container writes paths as the
   container sees them; [Bound_mount] carries the two roots that make one of
   those a path here, which only holds inside the bind mount. Without it the
   target stays in the command's namespace and a sandboxed dispatch refuses
   it rather than opening whatever this host has at that path. *)
type redirect_namespace =
  | Command_filesystem
  | Bound_mount of {
      visible_root : string;
      host_root : string;
    }

let host_path_under ~visible_root ~host_root path =
  let prefix = visible_root ^ "/" in
  if String.equal path visible_root
  then Some host_root
  else if String.starts_with ~prefix path
  then
    Some
      (Filename.concat
         host_root
         (String.sub path (String.length prefix) (String.length path - String.length prefix)))
  else None
;;

let redirect_target ~namespace ~classify path =
  let as_written = classify path in
  (* The null device is the same device in either namespace, so it needs no
     translation to be openable here. *)
  if String.equal path dev_null
  then Ok (Masc_exec.Redirect_scope.on_this_host as_written dev_null)
  else (
    match namespace with
    | Command_filesystem -> Ok (Masc_exec.Redirect_scope.In_command_namespace as_written)
    | Bound_mount { visible_root; host_root } ->
      (match host_path_under ~visible_root ~host_root path with
       | Some host_path -> Ok (Masc_exec.Redirect_scope.on_this_host as_written host_path)
       | None -> Error (Redirect_outside_the_sandbox_mount { path; visible_root })))
;;

let redirects_of_stage ~namespace ~cwd { argv = _; stdin; stdout; stderr } =
  let ( let* ) = Result.bind in
  let cwd_str = Option.value cwd ~default:"/" in
  let classify path = Masc_exec.Path_scope.classify ~raw:path ~cwd:cwd_str in
  let resolve path = redirect_target ~namespace ~classify path in
  let* stdin_entry = input_entry ~resolve stdin in
  let* stdout_entry = output_entry ~resolve ~fd:stdout_fd stdout in
  let* stderr_entry = output_entry ~resolve ~fd:stderr_fd stderr in
  Ok (List.filter_map (fun x -> x) [ stdin_entry; stdout_entry; stderr_entry ])
;;

(* Through the gate, not around it. [Bash.parse_string] ownership sits inside
   the command-gate library on purpose -- its own interface says so, and a
   ratchet counts the caller files -- so the shell form crosses the same
   boundary a shell frontend would. [gate_raw] has carried this entrypoint,
   with tests, and had no production caller until now. *)
(* RFC execute-subset-dispositions step 1.

   [argv:["sh";"-c";S]] reaches the gate as one opaque program with two literal
   arguments, so whatever S contains is counted as nothing at all.  This walks
   the staged form, recognises the ones that are a script in an argv costume,
   and says what the gate would have made of each.

   Recognition and classification only: nothing here changes what runs.

   RFC execute-boundary-is-the-sandbox §6 adds the [Script] source. It used to
   yield nothing on the grounds that it "already crossed the gate", which was
   true while crossing the gate decided whether it ran. It no longer does. A
   script that says [<<EOF] gets no advice any more: the stdin field is gone
   from the schema and the shell runs the heredoc as written, so the finding
   is recognition and classification only. *)
let hidden_script_findings ~sandbox { source; _ } =
  let gate_sandbox = { Shell_gate.target = sandbox } in
  let syntax_policy =
    { Shell_gate.redirect_allowed = true; allow_pipes = true }
  in
  let of_stage (stage : exec_stage) =
    Option.map
      (fun costume ->
         ( costume.Keeper_tooling.Shell_costume.shell
         , Keeper_tooling.Shell_costume.classify
             ~syntax_policy
             ~sandbox:gate_sandbox
             costume ))
      (Keeper_tooling.Shell_costume.of_argv stage.argv)
  in
  let of_program { head; tail } = List.filter_map of_stage (head :: tail) in
  match source with
  | Script { shell; text } ->
    (* Through [of_argv], not around it: the classifier's idea of a shell form
       is the one the normalisation in [to_shell_ir_unvalidated] uses, and two
       of them would drift. *)
    (match Keeper_tooling.Shell_costume.of_argv [ shell; "-c"; text ] with
     | None -> []
     | Some costume ->
       [ ( shell
         , Keeper_tooling.Shell_costume.classify
             ~syntax_policy
             ~sandbox:gate_sandbox
             costume )
       ])
  | Staged { program; next } ->
    of_program program @ List.concat_map (fun (_, p) -> of_program p) next
;;

(* RFC execute-boundary-is-the-sandbox §4. The script goes to a real shell on
   the far side of the keeper's boundary, which is what [argv:["bash";"-c";S]]
   has always reached. [shell_simple] builds the same [Simple] that form
   builds, so the two fields produce the same child for the same text. *)
let script_to_shell ~sandbox ~cwd ~env { shell; text } =
  shell_simple ~sandbox ?cwd ~env [ shell; "-c"; text ]
;;

let to_shell_ir_unvalidated
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      ?(namespace = Command_filesystem)
      { source; cwd; env; timeout_sec = _ }
  =
  let ( let* ) = Result.bind in
  let lower stage =
    let* redirects = redirects_of_stage ~namespace ~cwd stage in
    shell_simple ~sandbox ?cwd ~env ~redirects stage.argv
  in
  let lower_program = function
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
  in
  let connector = function
    | And_then -> Masc_exec.Shell_ir.And_if
    | Or_else -> Masc_exec.Shell_ir.Or_if
  in
  (* RFC execute-subset-dispositions §3.7 step 4, for the representable only.

     [argv:["sh";"-c";S]] reaches the gate as one opaque program, so nothing
     inside S is path-scoped, redirect-policed, or held to the connector rules.
     Where the corpus census says S carries nothing the IR cannot hold -- 1212
     of 1584 recorded costumes -- lowering S is the same work under the
     boundary rather than beside it. Where it does not, today's path stays: a
     blanket flip would refuse calls that run.

     Three guards, and the third is the one that bites. [resolve_arg] answers
     [$FOO] from *this* process's environment, while a shell would answer it
     from the child's, which [Env_keeper_scrub] has filtered. Lowering a script
     that mentions a variable would quietly change the value, in the direction
     of the unfiltered one. *)
  (* RFC execute-boundary-is-the-sandbox §4.1. An argv whose program is a
     shell with [-c] is a script wearing an argv costume: it normalises to the
     script form and takes the same shell, so there is no second way to reach
     one. Nothing is classified here any more. Whether the subset can
     represent the text decided which of two execution models it got, and that
     decision is now the field's, so the classifier speaks as a judge
     (telemetry, [escaped_shell] advice) rather than as a router.

     A stage that declares its own streams keeps today's path: the script
     would have to merge them with whatever it declares, which is a different
     question. *)
  let costume_as_script stage =
    match stage.stdin, stage.stdout, stage.stderr with
    | Inherit_input, Inherit_output, Inherit_output ->
      Option.map
        (fun (costume : Keeper_tooling.Shell_costume.t) ->
           { shell = costume.Keeper_tooling.Shell_costume.shell
           ; text = costume.Keeper_tooling.Shell_costume.script
           })
        (Keeper_tooling.Shell_costume.of_argv stage.argv)
    | _ -> None
  in
  let normalised_costume =
    match source with
    | Staged { program = { head; tail = [] }; next = [] } -> costume_as_script head
    | Staged _ | Script _ -> None
  in
  match normalised_costume, source with
  | Some script, _ | None, Script script -> script_to_shell ~sandbox ~cwd ~env script
  | None, Staged { program; next } ->
  let* head = lower_program program in
  match next with
  | [] -> Ok head
  | _ :: _ ->
    let* tail =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (guard, program) :: rest ->
          let* ir = lower_program program in
          loop ((connector guard, ir) :: acc) rest
      in
      loop [] next
    in
    Ok (Masc_exec.Shell_ir.Sequence { head; tail })
;;

let to_shell_ir ?sandbox ?namespace input =
  let ( let* ) = Result.bind in
  let* () = validate input in
  to_shell_ir_unvalidated ?sandbox ?namespace input
;;

let pp_validation_error ppf = function
  | Redirect_outside_the_sandbox_mount { path; visible_root } ->
    Format.fprintf
      ppf
      "redirect target %S sits outside %s, the directory this sandbox and the \
       host share. Outside it the same path names two different files and only \
       one of them can be opened from here, so redirect somewhere under %s."
      path
      visible_root
      visible_root
  | Directory_change_is_not_a_program { requested } ->
    Format.fprintf
      ppf
      "cd is the shell's own directory, not a program: %S would change the \
       directory of a child that exits immediately, and anything chained after \
       it would not run. Put the directory in the cwd field instead, and if you \
       meant to run one command after another use then."
      requested
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
