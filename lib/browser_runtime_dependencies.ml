type program = Geckodriver | Firefox

let name = function
  | Geckodriver -> "geckodriver"
  | Firefox -> "firefox"

let firefox_bundle_executable = "Firefox.app/Contents/MacOS/firefox"

let candidates = function
  | Geckodriver -> [ "geckodriver" ]
  | Firefox ->
    let user_applications =
      match Sys.getenv_opt "HOME" with
      | Some home when not (String.equal home "") ->
        [ Filename.concat (Filename.concat home "Applications") firefox_bundle_executable ]
      | Some _ | None -> []
    in
    [ "firefox"
    ; Filename.concat "/Applications" firefox_bundle_executable
    ]
    @ user_applications

type check =
  | Missing of string
  | Started of { command : string; path : string; output : string }
  | Failed of { command : string; path : string; status : Unix.process_status; detail : string }

(* A version probe answers straight away or is no use. Without a bound one
   wedged executable -- a wrapper waiting on input, a stalled network mount --
   holds the setup screen open for as long as it likes. A spent budget is
   reported as a failed probe, which is what an unusable program is. *)
let probe_timeout_sec = 10.

let is_executable_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (match Unix.access path [ Unix.X_OK ] with
     | () -> true
     | exception Unix.Unix_error _ -> false)
  | { Unix.st_kind = Unix.(S_DIR | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK); _ } -> false
  | exception Unix.Unix_error _ -> false

(* The file a name resolves to, as {!Executable_path} decides what counts as a
   search directory: an empty entry is not the current directory. *)
let resolve command =
  let command = String.trim command in
  if String.equal command ""
  then None
  else if String.contains command '/'
  then if is_executable_file command then Some command else None
  else (
    match Sys.getenv_opt "PATH" with
    | None -> None
    | Some raw ->
      Executable_path.split_search_path raw
      |> List.filter (fun directory -> not (String.equal directory ""))
      |> List.find_map (fun directory ->
        let candidate = Filename.concat directory command in
        if is_executable_file candidate then Some candidate else None))

let probe command =
  match resolve command with
  | None -> Missing command
  | Some path ->
    let status, stdout, stderr =
      Process_eio.run_argv_with_status_split
        ~timeout_sec:probe_timeout_sec
        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
        [ path; "--version" ]
    in
    let output = String.trim (stdout ^ "\n" ^ stderr) in
    (match status with
     | Unix.WEXITED 0 -> Started { command; path; output }
     (* [run_argv_with_status_split] synthesises 124 on its own timeout, the
        way timeout(1) does. *)
     | Unix.WEXITED 124 ->
       Failed
         { command
         ; path
         ; status
         ; detail =
             Printf.sprintf "%s --version did not answer within %.0f seconds" path
               probe_timeout_sec
         }
     | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
       Failed { command; path; status; detail = output })

let observe program =
  let checks = List.map probe (candidates program) in
  let started =
    List.find_opt (function Started _ -> true | Missing _ | Failed _ -> false) checks
  in
  let failed =
    List.find_opt (function Failed _ -> true | Missing _ | Started _ -> false) checks
  in
  match started, failed, checks with
  | Some check, _, _ | None, Some check, _ -> check
  | None, None, check :: _ -> check
  | None, None, [] -> Missing (name program)

let available = function
  | Started _ -> true
  | Missing _ | Failed _ -> false

let path = function
  | Started { path; _ } | Failed { path; _ } ->
    Some path
  | Missing _ -> None

let to_json program check =
  let row =
    match check with
    | Missing command ->
      [ "command", `String command; "status", `String "missing" ]
    | Started { command; path; output } ->
      [ "command", `String command
      ; "status", `String "started"
      ; "path", `String path
      ; "output", `String output
      ]
    | Failed { command; path; status; detail } ->
      let process =
        match status with
        | Unix.WEXITED code -> `Assoc [ "exit_code", `Int code ]
        | Unix.WSIGNALED signal -> `Assoc [ "signal", `Int signal ]
        | Unix.WSTOPPED signal -> `Assoc [ "stopped_signal", `Int signal ]
      in
      [ "command", `String command
      ; "status", `String "failed"
      ; "path", `String path
      ; "process", process
      ; "detail", `String detail
      ]
  in
  `Assoc
    [ "schema", `String "masc.browser_tools_readiness.v1"
    ; "program", `String (name program)
    ; "status", `String (if available check then "tool_available" else "unavailable")
    ; "scope", `String "current_process_environment"
    ; "checks", `List [ `Assoc row ]
    ; "lane", `String "not_checked"
    ]
