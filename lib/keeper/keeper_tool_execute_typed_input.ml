module Shell_gate = Masc_exec_command_gate.Shell_command_gate

type script = {
  shell : string;
  text : string;
}

(* POSIX, because a script that says nothing should get the shell every image
   has. A caller that needs bash says so, and a normalised costume says what
   its argv said. *)
let default_script_shell = "sh"

type source =
  | Argv of string list
  | Script of script

type execute_input = {
  source : source;
  cwd : string option;
  timeout_sec : float option;
}

type validation_error =
  | Empty_argv
  | Empty_program
  | Directory_change_is_not_a_program of { requested : string }
  | Argv_contains_nul of {
      index : int;
      token : string;
    }
  | Cwd_not_absolute of string

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

(* The schema's [oneOf] and this function are the same rule stated twice: a
   call names one form. Stating it here is what makes [source] a sum rather
   than two optional fields a validator has to reconcile. *)
let source_of_fields ~path fields =
  let ( let* ) = Result.bind in
  let named key =
    match member fields key with
    | None | Some `Null -> false
    | Some _ -> true
  in
  match named "script", named "argv" with
  | true, true ->
    result_errorf "%s names both script and argv; a call takes one form" path
  | true, false ->
    let* script = optional_string ~path fields "script" in
    (* [named "script"] is what put us in this arm, so the field is present;
       a default here would turn "not a string" into an empty script. *)
    (match script with
     | None -> result_errorf "%s.script must be a string" path
     | Some script ->
       if String.trim script = ""
       then result_errorf "%s.script is empty" path
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
    let* argv = required_string_list ~path fields "argv" in
    Ok (Argv argv)
  | false, false -> result_errorf "%s.argv or %s.script is required" path path
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
      ~allowed:[ "argv"; "script"; "shell"; "cwd"; "timeout_sec" ]
      fields
  in
  let* cwd = optional_string ~path:"$" fields "cwd" in
  let* timeout_sec = optional_positive_float ~path:"$" fields "timeout_sec" in
  let* source = source_of_fields ~path:"$" fields in
  Ok { source; cwd; timeout_sec }
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

(* [cd] is the shell's own directory, not a program. Spawned, it changes the
   directory of a child that exits immediately, so whatever the caller chained
   after it never runs. It also ignores the extra arguments and exits zero, so
   the call comes back successful with no output -- an empty answer that reads
   like a real one. Measured: 60 such calls, 56 of them reported successful and
   empty. Refusing it is not a judgement about argv content; there is no
   invocation of [cd] as a program that does anything. *)
let directory_change_program = "cd"

let check_exec ~argv ~cwd =
  let ( let* ) = Result.bind in
  match argv with
  | [] -> Error Empty_argv
  | program :: _ when String.equal program "" -> Error Empty_program
  | program :: _ when String.equal (Filename.basename program) directory_change_program ->
    Error (Directory_change_is_not_a_program { requested = String.concat " " argv })
  | _ ->
    let* () = check_argv argv in
    check_cwd cwd
;;

let validate { source; cwd; timeout_sec = _ } =
  let ( let* ) = Result.bind in
  let* () = check_cwd cwd in
  match source with
  | Script _ -> Ok ()
  | Argv argv -> check_exec ~argv ~cwd:None
;;

let shell_bin = function
  | [] -> Error Empty_argv
  | program :: argv ->
    (match Masc_exec.Exec_program.of_string program with
     | Ok bin -> Ok (bin, argv)
     | Error (`Unknown _) -> Error Empty_program)
;;

let shell_simple ?(sandbox = Masc_exec.Sandbox_target.host ()) ?cwd argv =
  let ( let* ) = Result.bind in
  let* bin, arguments = shell_bin argv in
  Ok
    (Keeper_tooling.Execute_shell_ir.simple_bin
       ?cwd_raw:cwd
       ?cwd_base:cwd
       ~sandbox
       bin
       arguments)
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
  let of_costume costume =
    ( costume.Keeper_tooling.Shell_costume.shell
    , Keeper_tooling.Shell_costume.classify ~syntax_policy ~sandbox:gate_sandbox costume )
  in
  match source with
  | Script { shell; text } ->
    (* Through [of_argv], not around it: the classifier's idea of a shell form
       is the one the normalisation in [to_shell_ir_unvalidated] uses, and two
       of them would drift. *)
    (match Keeper_tooling.Shell_costume.of_argv [ shell; "-c"; text ] with
     | None -> []
     | Some costume -> [ of_costume costume ])
  | Argv argv ->
    Option.to_list (Option.map of_costume (Keeper_tooling.Shell_costume.of_argv argv))
;;

(* RFC execute-boundary-is-the-sandbox §4. The script goes to a real shell on
   the far side of the keeper's boundary, which is what [argv:["bash";"-c";S]]
   has always reached. [shell_simple] builds the same [Simple] that form
   builds, so the two fields produce the same child for the same text. *)
let script_to_shell ~sandbox ~cwd { shell; text } =
  shell_simple ~sandbox ?cwd [ shell; "-c"; text ]
;;

let to_shell_ir_unvalidated
      ?(sandbox = Masc_exec.Sandbox_target.host ())
      { source; cwd; timeout_sec = _ }
  =
  (* RFC execute-boundary-is-the-sandbox §4.1. An argv whose program is a
     shell with [-c] is a script wearing an argv costume: it normalises to the
     script form and takes the same shell, so there is no second way to reach
     one. Nothing is classified here any more. Whether the subset can
     represent the text decided which of two execution models it got, and that
     decision is now the field's, so the classifier speaks as a judge
     (telemetry, [escaped_shell] advice) rather than as a router. *)
  match source with
  | Script script -> script_to_shell ~sandbox ~cwd script
  | Argv argv ->
    (match Keeper_tooling.Shell_costume.of_argv argv with
     | Some costume ->
       script_to_shell
         ~sandbox
         ~cwd
         { shell = costume.Keeper_tooling.Shell_costume.shell
         ; text = costume.Keeper_tooling.Shell_costume.script
         }
     | None -> shell_simple ~sandbox ?cwd argv)
;;

let to_shell_ir ?sandbox input =
  let ( let* ) = Result.bind in
  let* () = validate input in
  to_shell_ir_unvalidated ?sandbox input
;;

let pp_validation_error ppf = function
  | Directory_change_is_not_a_program { requested } ->
    Format.fprintf
      ppf
      "cd is the shell's own directory, not a program: %S would change the \
       directory of a child that exits immediately, and anything chained after \
       it would not run. Put the directory in the cwd field instead, and if you \
       meant to run one command after another write them as a script."
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
  | Cwd_not_absolute path ->
    Format.fprintf ppf "cwd %S is not absolute" path
;;
