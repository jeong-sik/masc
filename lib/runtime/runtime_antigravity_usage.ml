(* Reading an Antigravity account's usage windows through the official CLI's
   print-mode [/usage]. See the [.mli]. *)

(* agy 1.2.11 answered [/usage] in 19.1 s once (2026-09-26); the version
   probe is quick. The read runs off the turn path, so a wider bound only
   delays this account's projection. *)
let read_timeout_s = 60.0

(* agy's bundled changelog, 1.1.11: print mode answers the read-only slash
   commands "without starting an agent turn, spending quota, or leaving a
   conversation behind". Before it, "/usage" reached the model. *)
let minimum_version = 1, 1, 11

type phase =
  | Version_probe
  | Usage_command

type error =
  | Private_home_unavailable
  | Command_refused of
      { phase : phase
      ; detail : string
      }
  | Command_failed of
      { phase : phase
      ; status : Unix.process_status
      ; stderr_tail : string
      }
  | Version_unreadable of string
  | Version_too_old of string
  | Output_not_json
  | Decode_failed of Runtime_provider_usage_window.decode_error

let stderr_tail_bytes = 512

let phase_label = function
  | Version_probe -> "the version probe"
  | Usage_command -> "the /usage command"
;;

let compare_version (major, minor, patch) (major', minor', patch') =
  match Int.compare major major' with
  | 0 ->
    (match Int.compare minor minor' with
     | 0 -> Int.compare patch patch'
     | order -> order)
  | order -> order
;;

let version_label (major, minor, patch) = Printf.sprintf "%d.%d.%d" major minor patch

(* The CLI's stdout is not logged: an answer that failed to decode may still
   carry the account's own text. *)
let error_to_string = function
  | Private_home_unavailable -> "the disposable Antigravity HOME could not be prepared"
  | Command_refused { phase; detail } ->
    Printf.sprintf "%s did not start: %s" (phase_label phase) detail
  | Command_failed { phase; status; stderr_tail } ->
    Printf.sprintf
      "%s ended with %s%s"
      (phase_label phase)
      (With_process.status_to_string status)
      (if String.equal stderr_tail "" then "" else "; stderr: " ^ stderr_tail)
  | Version_unreadable printed ->
    Printf.sprintf "agy --version printed %S, not MAJOR.MINOR.PATCH" printed
  | Version_too_old version ->
    Printf.sprintf
      "agy %s is older than %s, where /usage would be a model turn; not sent"
      version
      (version_label minimum_version)
  | Output_not_json -> "the /usage answer is not JSON"
  | Decode_failed error -> Runtime_provider_usage_window.decode_error_to_string error
;;

let parse_version printed =
  let decimal part =
    if String.equal part "" || not (String.for_all (fun c -> c >= '0' && c <= '9') part)
    then None
    else int_of_string_opt part
  in
  match String.split_on_char '.' (String.trim printed) with
  | [ major; minor; patch ] ->
    (match decimal major, decimal minor, decimal patch with
     | Some major, Some minor, Some patch -> Some (major, minor, patch)
     | _, _, _ -> None)
  | _ -> None
;;

let ( let* ) = Result.bind

let run ~phase ~env ~cwd argv =
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~timeout_sec:read_timeout_s
      ~env
      ~cwd
      argv
  with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Ok (status, _, stderr) ->
    Error
      (Command_failed
         { phase
         ; status
         ; stderr_tail =
             String_util.utf8_suffix ~max_bytes:stderr_tail_bytes (String.trim stderr)
         })
  | Error refusal ->
    Error (Command_refused { phase; detail = Process_eio.spawn_refusal_to_string refusal })
;;

(* The context observation's environment: the account's own variables, the
   disposable HOME, and a TMPDIR inside the root that is removed after. *)
let environment ~home_dir ~runtime_root =
  let key entry =
    match String.index_opt entry '=' with
    | None -> entry
    | Some i -> String.sub entry 0 i
  in
  Runtime_antigravity.official_client_environment ~home_dir ()
  |> Array.to_list
  |> List.filter (fun entry -> not (List.mem (key entry) [ "TMPDIR"; "TMP"; "TEMP" ]))
  |> List.cons ("TMPDIR=" ^ runtime_root)
  |> Array.of_list
;;

let read_in ~cli_path ~oauth_source runtime_root =
  let* home =
    Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf:"usage-read" ~oauth_source
    |> Result.map_error (fun (_ : Runtime_antigravity_home.error) -> Private_home_unavailable)
  in
  let* () =
    Runtime_antigravity_home.clear_mcp_config home
    |> Result.map_error (fun (_ : Runtime_antigravity_home.error) -> Private_home_unavailable)
  in
  let home_dir = Runtime_antigravity_home.home_dir home in
  let env = environment ~home_dir ~runtime_root in
  let* printed = run ~phase:Version_probe ~env ~cwd:home_dir [ cli_path; "--version" ] in
  let* () =
    match parse_version printed with
    | None -> Error (Version_unreadable (String.trim printed))
    | Some version when compare_version version minimum_version < 0 ->
      Error (Version_too_old (version_label version))
    | Some (_ : int * int * int) -> Ok ()
  in
  let* answer =
    run
      ~phase:Usage_command
      ~env
      ~cwd:home_dir
      [ cli_path; "-p"; "/usage"; "--output-format"; "json" ]
  in
  let* json =
    match Yojson.Safe.from_string answer with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error Output_not_json
  in
  Runtime_provider_usage_window.decode_antigravity_usage json
  |> Result.map_error (fun error -> Decode_failed error)
;;

(* The root holds a copy of the account's OAuth file, so a removal that
   fails is said out loud. *)
let remove_root runtime_root =
  try Fs_compat.remove_tree runtime_root with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Antigravity usage read left its disposable HOME %s behind: %s"
      runtime_root
      (Printexc.to_string exn)
;;

let read ~cli_path ~oauth_source =
  match Filename.temp_dir "masc-antigravity-usage-" "" |> Unix.realpath with
  | exception (Sys_error _ | Unix.Unix_error _) -> Error Private_home_unavailable
  | runtime_root ->
    let run () =
      try read_in ~cli_path ~oauth_source runtime_root with
      | Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable
    in
    (match Eio_context.get_switch_opt () with
     | None -> Fun.protect ~finally:(fun () -> remove_root runtime_root) run
     | Some (_ : Eio.Switch.t) ->
       (* As in the context observation: Eio runs a release hook
          cancellation-protected, so the removal survives a cancelled read. *)
       Eio.Switch.run (fun sw ->
         Eio.Switch.on_release sw (fun () -> remove_root runtime_root);
         run ()))
;;
