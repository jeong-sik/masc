type exec_stage = {
  executable : string;
  argv : string list;
}

type bash_input =
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

(* Execve-style: argv tokens pass verbatim to the child process, so
   shell metacharacters ([;|&><`$*?]) are literal data, not operators.
   Only control characters that cannot survive process-boundary
   serialization are rejected.  See .mli "Design constraints" for the
   rationale and contrast with the legacy lexer in [Worker_dev_tools]. *)
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

let check_exec ~mode ~executable ~argv ~cwd ~env =
  let ( let* ) = Result.bind in
  if not (is_allowed ~mode executable)
  then Error (Executable_not_allowlisted { name = executable; mode })
  else
    let* () =
      if argv = [] then Ok () else check_argv ~executable argv
    in
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

let shell_arg text = Masc_exec.Shell_ir.Lit text

let shell_env env =
  List.map (fun (key, value) -> key, shell_arg value) env
;;

let shell_cwd = function
  | None -> None
  | Some cwd -> Some (Masc_exec.Path_scope.classify ~raw:cwd ~cwd)
;;

let shell_bin ~mode executable =
  match Masc_exec.Bin.of_string executable with
  | Ok bin -> Ok bin
  | Error (`Unknown name) ->
    Error (Executable_not_allowlisted { name; mode })
;;

let shell_simple ~mode ?cwd ?(env = []) { executable; argv } =
  let ( let* ) = Result.bind in
  let* bin = shell_bin ~mode executable in
  Ok
    { Masc_exec.Shell_ir.bin
    ; args = List.map shell_arg argv
    ; env = shell_env env
    ; cwd = shell_cwd cwd
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
;;

let to_shell_ir ~mode input =
  let ( let* ) = Result.bind in
  let* () = validate ~mode input in
  match input with
  | Exec { executable; argv; cwd; env } ->
    let stage = { executable; argv } in
    let* simple = shell_simple ~mode ?cwd ~env stage in
    Ok (Masc_exec.Shell_ir.Simple simple)
  | Pipeline { stages; cwd; env } ->
    let* simples =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | stage :: rest ->
          let* simple = shell_simple ~mode ?cwd ~env stage in
          loop (Masc_exec.Shell_ir.Simple simple :: acc) rest
      in
      loop [] stages
    in
    Ok (Masc_exec.Shell_ir.Pipeline simples)
;;

let pp_mode ppf = function
  | Dev_full -> Format.pp_print_string ppf "dev_full"
  | Readonly -> Format.pp_print_string ppf "readonly"
;;

let pp_validation_error ppf = function
  | Executable_not_allowlisted { name; mode } ->
    Format.fprintf ppf "executable %S not in %a allowlist" name pp_mode mode
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
