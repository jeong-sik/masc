type program = Geckodriver | Firefox | Ego_browser

let name = function
  | Geckodriver -> "geckodriver"
  | Firefox -> "firefox"
  | Ego_browser -> "ego-browser"

let firefox_bundle_executable = "Firefox.app/Contents/MacOS/firefox"

(* A relative HOME would name a place relative to wherever this runs, and the
   lane takes absolute paths only. *)
let absolute_home () =
  match Sys.getenv_opt "HOME" with
  | Some home when (not (String.equal home "")) && not (Filename.is_relative home) -> Some home
  | Some _ | None -> None

let candidates = function
  | Geckodriver -> [ "geckodriver" ]
  | Ego_browser ->
    (* ego lite's onboarding links ego-browser into ~/.local/bin, which a
       shell started before it, or a service, may not have on PATH. *)
    "ego-browser"
    :: (match absolute_home () with
        | Some home -> [ Filename.concat (Filename.concat (Filename.concat home ".local") "bin") "ego-browser" ]
        | None -> [])
  | Firefox ->
    let user_applications =
      match absolute_home () with
      | Some home ->
        [ Filename.concat (Filename.concat home "Applications") firefox_bundle_executable ]
      | None -> []
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

(* The lane takes absolute paths only ([browser.automation] geckodriver and
   binary, [browser.live.bidi] firefox). A program found through a relative
   PATH entry, or given as a relative path, is reported where it is on disk
   rather than as a path that only means something from this directory. A
   working directory that cannot be read leaves no such path to report. *)
let absolute path =
  if not (Filename.is_relative path)
  then Some path
  else (
    match Sys.getcwd () with
    | cwd -> Some (Filename.concat cwd path)
    | exception Sys_error _ -> None)

(* The file a name resolves to, as {!Executable_path} decides what counts as a
   search directory: an empty entry is not the current directory. Nothing is
   started: {!probe} runs what this finds, and a caller that only asks whether
   a program is there reads this instead. *)
let locate command =
  let command = String.trim command in
  if String.equal command ""
  then None
  else (
    let found =
      if String.contains command '/'
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
    in
    Option.bind found absolute)

let probe command =
  match locate command with
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

(* Candidates are tried in order and the first one that answers ends the walk:
   a later candidate is never started once an earlier one has answered, which
   matters when a candidate is a launcher that opens a window. A failure and a
   missing file are remembered, the first of each, for when nothing answers. *)
let first_answer ~label candidates =
  let rec walk ~failed ~missing = function
    | [] ->
      (match failed, missing with
       | Some check, _ | None, Some check -> check
       | None, None -> Missing label)
    | command :: rest ->
      (match probe command with
       | Started _ as check -> check
       | Failed _ as check ->
         let failed = match failed with None -> Some check | Some _ -> failed in
         walk ~failed ~missing rest
       | Missing _ as check ->
         let missing = match missing with None -> Some check | Some _ -> missing in
         walk ~failed ~missing rest)
  in
  walk ~failed:None ~missing:None candidates

let observe program = first_answer ~label:(name program) (candidates program)

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
    ; "status", `String (if available check then "tools_available" else "unavailable")
    ; "scope", `String "current_process_environment"
    ; "checks", `List [ `Assoc row ]
    ; "lane", `String "not_checked"
    ]
