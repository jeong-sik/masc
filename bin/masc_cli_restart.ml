module Upgrade = Server_upgrade_preparation

(* What holds the workspace before anything is asked to stop. *)
type incumbent =
  | Nothing_running
  | This_workspace of { version : string; pid : int option }

type refusal =
  | Host_not_an_address of string
  | Host_not_on_loopback of string
  | Other_workspace of string
  | Port_held_by_unknown_process
  | Owner_without_answer
  | Owner_unverifiable of string
  | Stop_refused of Upgrade.error
  | Log_unopenable of { path : string; reason : string }
  | Spawn_failed of string

type watched =
  | Replacement_ready
  | Replacement_exited of Unix.process_status option

(* How often the replacement's readiness answer is read again. Each read uses
   its own client pool (see [fresh_get]), so this alone bounds how late a
   ready server is noticed; the watch itself has no deadline. *)
let readiness_poll_interval_s = 0.25

(* How much of the replacement's log is shown when it exits before ready. *)
let failure_log_lines = 20

let loopback_url port path = Printf.sprintf "http://127.0.0.1:%d%s" port path

(* Restart reaches the running server and its replacement on 127.0.0.1, as
   setup does, so a replacement bound anywhere else would never be seen. A
   name such as localhost is not an address the replacement can bind, so it
   is refused before anything is stopped. *)
let check_host host =
  match Unix.inet_addr_of_string host with
  | address when address = Unix.inet_addr_loopback || address = Unix.inet_addr_any ->
    Ok ()
  | (_ : Unix.inet_addr) -> Error (Host_not_on_loopback host)
  | exception Failure _ -> Error (Host_not_an_address host)

(* A shared client pool refuses a host for a while after one failed connect,
   and the gap between the old listener closing and the new one binding
   always produces one. A pool per request to the replacement keeps that
   from delaying or hiding its answers. *)
let fresh_get ~clock ~port path =
  match Eio_context.get_env_opt () with
  | None -> Error "no Eio environment for the request"
  | Some env ->
    Eio.Switch.run (fun sw ->
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        Masc_http_client.get_sync ~clock ~headers:[] ~url:(loopback_url port path) ()))

let json_field name body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
  | exception Yojson.Json_error _ -> None

let answered_pid body =
  match json_field "pid" body with
  | Some (`Int pid) -> Some pid
  | _ -> None

let stop_error_message = function
  | Upgrade.Admin_required ->
    "the running server refused local operator access; sign in and run restart again"
  | Different_workspace -> "the server on this port serves another workspace"
  | Incumbent_changed -> "the running server changed while restart was checking it; run restart again"
  | Owner_unavailable -> "the workspace owner could not be verified"
  | Invalid_health -> "the port did not answer with a workspace identity"
  | Already_requested -> "a graceful shutdown was already requested"
  | Closed -> "the owner check closed before the stop request"
  | Port_unavailable -> "the port could not be inspected"

let observe ~clock ~run_dir ~base_path ~port =
  match Masc_http_client.get_sync ~clock ~headers:[]
          ~url:(loopback_url port "/health?full=1") () with
  | Ok (200, body) ->
    (match Upgrade.decode_health body with
     | Ok identity when String.equal identity.base_path base_path ->
       let pid =
         match Masc_http_client.get_sync ~clock ~headers:[]
                 ~url:(loopback_url port "/health/ready") () with
         | Ok (_, body) -> answered_pid body
         | Error _ -> None
       in
       Ok (This_workspace { version = identity.version; pid })
     | Ok identity -> Error (Other_workspace identity.base_path)
     | Error _ -> Error Port_held_by_unknown_process)
  | Ok _ | Error _ ->
    (* Nothing answered: whether a lease owner or another listener is there
       decides between starting fresh and refusing. *)
    (match Upgrade.replacement_readiness ~run_dir ~base_path ~port with
     | Ok Upgrade.Replacement_can_start -> Ok Nothing_running
     | Ok Upgrade.Owner_draining -> Error Owner_without_answer
     | Ok Upgrade.Port_busy -> Error Port_held_by_unknown_process
     | Error error -> Error (Owner_unverifiable (stop_error_message error)))

let refusal_message ~base_path ~port = function
  | Host_not_an_address host ->
    Printf.sprintf "--host %s is not an IP address, and the replacement could not bind it. \
                    Nothing was stopped or started." host
  | Host_not_on_loopback host ->
    Printf.sprintf "Restart checks and stops servers on 127.0.0.1, so it cannot watch a \
                    replacement bound to --host %s. Nothing was stopped or started; use \
                    `masc start --host %s` for that address." host host
  | Other_workspace other ->
    Printf.sprintf "Port %d serves another workspace (%s). Nothing was stopped or started." port other
  | Port_held_by_unknown_process ->
    Printf.sprintf "Port %d is held by a process that is not this workspace's MASC server. \
                    Nothing was stopped or started." port
  | Owner_without_answer ->
    Printf.sprintf "A process holds %s but does not answer on port %d, so it cannot be asked \
                    to stop. If it is shutting down, run restart again once it has exited; \
                    if it serves another port, pass that --port." base_path port
  | Owner_unverifiable reason ->
    Printf.sprintf "The owner of %s could not be checked (%s). Nothing was stopped or started."
      base_path reason
  | Stop_refused error ->
    Printf.sprintf "The stop request was not sent: %s." (stop_error_message error)
  | Log_unopenable { path; reason } ->
    Printf.sprintf "The log file %s could not be opened (%s). A server named above as asked \
                    to stop is shutting down; start one with `masc start`." path reason
  | Spawn_failed reason ->
    Printf.sprintf "The replacement could not be started (%s). A server named above as asked \
                    to stop is shutting down; start one with `masc start`." reason

let default_log_path ~base_path =
  let now = Unix.gmtime (Unix.gettimeofday ()) in
  Filename.concat
    (Filename.concat (Filename.concat base_path Common.masc_dirname) "logs")
    (Printf.sprintf "masc-start-%04d%02d%02dT%02d%02d%02dZ.log"
       (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday now.tm_hour now.tm_min now.tm_sec)

let open_log path =
  match
    Fs_compat.mkdir_p (Filename.dirname path);
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600
  with
  | fd -> Ok fd
  | exception Unix.Unix_error (error, _, _) ->
    Error (Log_unopenable { path; reason = Unix.error_message error })
  | exception Sys_error reason -> Error (Log_unopenable { path; reason })

let log_tail path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ -> []
  | content ->
    let lines = String.split_on_char '\n' content |> List.filter (fun line -> line <> "") in
    let drop = max 0 (List.length lines - failure_log_lines) in
    List.filteri (fun index _ -> index >= drop) lines

(* Unix.process_status carries OCaml's own signal numbers, not the host's. *)
let signal_name signal =
  List.assoc_opt signal
    [ Sys.sigterm, "SIGTERM"; Sys.sigkill, "SIGKILL"; Sys.sigint, "SIGINT"
    ; Sys.sighup, "SIGHUP"; Sys.sigsegv, "SIGSEGV"; Sys.sigabrt, "SIGABRT"
    ; Sys.sigbus, "SIGBUS"; Sys.sigstop, "SIGSTOP"; Sys.sigtstp, "SIGTSTP" ]
  |> Option.value ~default:(Printf.sprintf "signal %d" signal)

let exit_description = function
  | Some (Unix.WEXITED code) -> Printf.sprintf "exited with status %d" code
  | Some (Unix.WSIGNALED signal) -> Printf.sprintf "was killed by %s" (signal_name signal)
  | Some (Unix.WSTOPPED signal) -> Printf.sprintf "was stopped by %s" (signal_name signal)
  | None -> "exited"

(* What a readiness answer that is not the replacement's 200 says, so the wait
   shows why it goes on. [None] while nothing listens yet. *)
let describe_answer ~child_pid = function
  | Error _ -> None
  | Ok (status, body) ->
    (match answered_pid body, json_field "phase" body, json_field "error" body with
     | Some pid, _, _ when pid <> child_pid ->
       Some (Printf.sprintf "pid %d is still answering on this port" pid)
     | Some _, Some (`String phase), _ -> Some ("starting: " ^ phase)
     | _, _, Some (`String error) -> Some (Printf.sprintf "answered %d: %s" status error)
     | _ -> Some (Printf.sprintf "answered %d" status))

(* The replacement answers on the port the predecessor drains on, so a 200 only
   counts once it carries the replacement's own pid. *)
let watch ~clock ~port (child : Posix_spawn_detached.t) =
  let rec ready last =
    let answer = fresh_get ~clock ~port "/health/ready" in
    match answer with
    | Ok (200, body) when answered_pid body = Some child.pid -> Replacement_ready
    | Ok _ | Error _ ->
      let note = describe_answer ~child_pid:child.pid answer in
      (match note with
       | Some text when note <> last -> Printf.printf "  %s\n%!" text
       | Some _ | None -> ());
      Eio.Time.sleep clock readiness_poll_interval_s;
      ready (if Option.is_some note then note else last)
  in
  Eio.Fiber.first
    (fun () -> Replacement_exited (Eio.Promise.await child.exited))
    (fun () -> ready None)

let build_summary ~clock ~port =
  match fresh_get ~clock ~port "/health" with
  | Ok (200, body) ->
    (match json_field "build" body with
     | Some (`Assoc build) ->
       (match List.assoc_opt "release_version" build, List.assoc_opt "binary_commit" build with
        | Some (`String version), Some (`String commit) ->
          Printf.sprintf "masc %s (%s)" version
            (if String.length commit > 11 then String.sub commit 0 11 else commit)
        | _ -> "masc")
     | _ -> "masc")
  | Ok _ | Error _ -> "masc"

let replace ~sw ~clock ~run_dir ~base_path ~port ~host ~log_path ~agent ~login =
  let open Result.Syntax in
  let* () = check_host host in
  let* incumbent = observe ~clock ~run_dir ~base_path ~port in
  let* wait_flag =
    match incumbent with
    | Nothing_running ->
      (* Nobody was asked to stop, so a lease someone takes meanwhile is a
         real owner: plain start refuses it instead of waiting forever. *)
      Printf.printf "No server holds %s; starting one on port %d.\n%!" base_path port;
      Ok []
    | This_workspace { version; pid } ->
      let* () =
        Masc_cli_owner_upgrade.with_selected_owner ~sw ~clock ~base_path ~port ~agent
          ~expected_version:version ~login Upgrade.request_termination
        |> Result.map_error (fun error -> Stop_refused error)
      in
      let named = match pid with Some pid -> Printf.sprintf " (pid %d)" pid | None -> "" in
      Printf.printf "Asked masc %s%s on port %d to stop.\n%!" version named port;
      Ok [ "--wait-for-previous-owner" ]
  in
  let argv =
    (Sys.executable_name :: "start" :: wait_flag)
    @ [ "--base-path"; base_path; "--port"; string_of_int port; "--host"; host ]
  in
  (* Opened only now, so a refusal above leaves no empty log behind. *)
  let* log_fd = open_log log_path in
  let* child =
    Fun.protect ~finally:(fun () -> Unix.close log_fd) (fun () ->
      Posix_spawn_detached.spawn ~sw ~argv ~env:(Unix.environment ()) ~output:log_fd
      |> Result.map_error (fun reason -> Spawn_failed reason))
  in
  let pid = child.Posix_spawn_detached.pid in
  Printf.printf "Started pid %d. Log: %s\n\
                 Waiting for it to become ready; Ctrl-C stops watching, not the server.\n%!"
    pid log_path;
  let started_at = Eio.Time.now clock in
  match watch ~clock ~port child with
  | Replacement_ready ->
    Printf.printf "Ready after %.1f s: %s, pid %d, serving %s on port %d.\n%!"
      (Eio.Time.now clock -. started_at) (build_summary ~clock ~port)
      pid base_path port;
    Ok 0
  | Replacement_exited status ->
    Printf.eprintf "pid %d %s before it was ready. Last lines of %s:\n%!"
      pid (exit_description status) log_path;
    List.iter (Printf.eprintf "  %s\n") (log_tail log_path);
    Ok 1

let run ~base_path ~port ~host ~log_path ~agent ~login =
  match Unix.realpath base_path with
  | exception Unix.Unix_error (error, _, _) ->
    Printf.eprintf "Workspace %s could not be resolved (%s). Nothing was stopped or started.\n"
      base_path (Unix.error_message error);
    1
  | base_path ->
    let run_dir = (Host_config.host ()).base_path_lease_dir in
    let log_path = Option.value log_path ~default:(default_log_path ~base_path) in
    (match
       Masc_cli_owner_upgrade.with_http (fun sw clock ->
         replace ~sw ~clock ~run_dir ~base_path ~port ~host ~log_path ~agent ~login)
     with
     | Ok code -> code
     | Error refusal ->
       prerr_endline (refusal_message ~base_path ~port refusal);
       1
     | exception (Unix.Unix_error _ | Sys_error _ as error) ->
       Printf.eprintf "Restart stopped: %s. A server named above as asked to stop is \
                       shutting down; start one with `masc start`.\n"
         (Printexc.to_string error);
       1)
