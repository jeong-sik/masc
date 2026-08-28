(** OpenSSH transport for the [Remote_ssh] keeper sandbox profile.

    The remote command is always the literal [masc-exec-shim]. Request data is
    carried only in the framed stdin protocol, never interpolated into the ssh
    argv. *)

let ( let* ) = Result.bind

let transport_error endpoint detail =
  Printf.sprintf "remote_ssh_transport_error: endpoint %s: %s" endpoint detail
;;

let local_timeout_error endpoint budget =
  Printf.sprintf
    "remote_ssh_local_timeout: endpoint %s exceeded local wall-clock budget %.2fs"
    endpoint budget
;;

let remote_timeout_error endpoint timeout_sec =
  Printf.sprintf
    "remote_ssh_remote_timeout: endpoint %s payload exceeded remote timeout %.2fs"
    endpoint timeout_sec
;;

let resolve_path ~base_path path =
  if Filename.is_relative path then Filename.concat base_path path else path
;;

let runtime_config_path ~base_path =
  let workspace_path = Filename.concat base_path ".masc/runtime.toml" in
  if Sys.file_exists workspace_path then Some workspace_path else Runtime.config_path ()
;;

let resolve_endpoint ~base_path ~keeper_name =
  let* defaults =
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path keeper_name
    |> Result.map_error Keeper_types_profile.keeper_toml_load_error_to_string
  in
  let* endpoint_name =
    match defaults.remote_endpoint with
    | Some name when String.trim name <> "" -> Ok (String.trim name)
    | _ ->
      Error
        (Printf.sprintf
           "remote_ssh_endpoint_missing: keeper %s has no remote_endpoint"
           keeper_name)
  in
  let* config_path =
    runtime_config_path ~base_path
    |> Option.to_result
         ~none:
           (Printf.sprintf
              "remote_ssh_runtime_config_missing: endpoint %s cannot be resolved because runtime.toml is unavailable"
              endpoint_name)
  in
  let* runtime_config =
    Runtime_toml.parse_file config_path
    |> Result.map_error (fun errors ->
      let details =
        errors
        |> List.map Runtime_toml.show_parse_error
        |> String.concat "; "
      in
      Printf.sprintf
        "remote_ssh_runtime_config_invalid: endpoint %s: %s"
        endpoint_name details)
  in
  Runtime_schema.exec_ssh_endpoint runtime_config endpoint_name
  |> Option.to_result
       ~none:
         (Printf.sprintf
            "remote_ssh_endpoint_unknown: endpoint %s is not declared in [exec.ssh.endpoints]"
            endpoint_name)
;;

type shared_state =
  { semaphore : Eio.Semaphore.t
  ; first_dispatch_logged : bool Atomic.t
  }

(* Runner values are rebuilt per typed dispatch, while the SSH connection and
   sshd MaxSessions ceiling are endpoint-scoped. Keep the admission state at
   that same scope. This is a module-global registry, so Stdlib.Mutex is the
   correct guard; no yielding work or logging happens while it is held. *)
let shared_states : (string, shared_state) Hashtbl.t = Hashtbl.create 8
let shared_states_mu = Stdlib.Mutex.create ()

let shared_state ~base_path (endpoint : Exec_ssh_endpoint.t) =
  let key =
    Printf.sprintf "%s\x00%s\x00%d"
      base_path endpoint.name endpoint.max_concurrent_sessions
  in
  Stdlib.Mutex.protect shared_states_mu (fun () ->
    match Hashtbl.find_opt shared_states key with
    | Some state -> state
    | None ->
      let state =
        { semaphore = Eio.Semaphore.make endpoint.max_concurrent_sessions
        ; first_dispatch_logged = Atomic.make false
        }
      in
      Hashtbl.add shared_states key state;
      state)
;;

type t =
  { endpoint : Exec_ssh_endpoint.t
  ; ssh_bin : string
  ; identity_file : string
  ; known_hosts_file : string
  ; control_path_dir : string
  ; host_playground_root : string
  ; shared : shared_state
  }

let ensure_control_path_dir path =
  try
    Fs_compat.mkdir_p path;
    Unix.chmod path 0o700;
    Ok ()
  with
  | Sys_error msg | Unix.Unix_error (_, _, msg) ->
    Error
      (Printf.sprintf
         "remote_ssh_control_path_unavailable: cannot create %s: %s"
         path msg)
;;

let create ?(ssh_bin = "ssh") ~base_path ~(endpoint : Exec_ssh_endpoint.t) () =
  let control_path_dir = Filename.concat base_path ".masc/run/ssh" in
  let* () = ensure_control_path_dir control_path_dir in
  Ok
    { endpoint
    ; ssh_bin
    ; identity_file = resolve_path ~base_path endpoint.identity_file
    ; known_hosts_file = resolve_path ~base_path endpoint.known_hosts_file
    ; control_path_dir
    ; host_playground_root = Filename.concat base_path ".masc/playground"
    ; shared = shared_state ~base_path endpoint
    }
;;

let ssh_argv t =
  let endpoint = t.endpoint in
  [ t.ssh_bin
  ; "-T"
  ; "-F"
  ; "none"
  ; "-o"
  ; "BatchMode=yes"
  ; "-o"
  ; "IdentitiesOnly=yes"
  ; "-i"
  ; t.identity_file
  ; "-o"
  ; "ForwardAgent=no"
  ; "-o"
  ; "ClearAllForwardings=yes"
  ; "-o"
  ; "StrictHostKeyChecking=yes"
  ; "-o"
  ; "UserKnownHostsFile=" ^ t.known_hosts_file
  ; "-o"
  ; Printf.sprintf "ConnectTimeout=%d" endpoint.connect_timeout_sec
  ; "-o"
  ; "ControlMaster=auto"
  ; "-o"
  ; "ControlPersist=120"
  ; "-o"
  ; "ControlPath=" ^ Filename.concat t.control_path_dir "%C"
  ; "-o"
  ; "ServerAliveInterval=15"
  ; "-o"
  ; "ServerAliveCountMax=2"
  ; "-p"
  ; string_of_int endpoint.port
  ; endpoint.user ^ "@" ^ endpoint.host
  ; "masc-exec-shim"
  ]
;;

let sandbox_endpoint t : Masc_exec.Sandbox_target.ssh_endpoint =
  { name = t.endpoint.name
  ; host = t.endpoint.host
  ; user = t.endpoint.user
  ; port = t.endpoint.port
  ; identity_file = t.identity_file
  ; known_hosts_file = t.known_hosts_file
  ; remote_root = t.endpoint.remote_root
  ; connect_timeout_sec = t.endpoint.connect_timeout_sec
  ; env_allowlist = t.endpoint.env_allowlist
  }
;;

let env_name entry =
  match String.index_opt entry '=' with
  | None -> Error "environment entry has no '=' separator"
  | Some 0 -> Error "environment entry has an empty name"
  | Some i ->
    Ok (String.sub entry 0 i, String.sub entry (i + 1) (String.length entry - i - 1))
;;

(* The shim re-applies this denylist and remains the authority. Dropping the
   same names here prevents values which can influence dynamic linking or
   command lookup from crossing the wire in the first place. *)
let wire_denied_env_name name =
  List.mem name
    [ "PATH"; "HOME"; "LD_PRELOAD"; "LD_LIBRARY_PATH"; "BASH_ENV"; "ENV" ]
  || String.starts_with ~prefix:"DYLD_" name
;;

let wire_env endpoint env =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
      let* name, value =
        env_name entry
        |> Result.map_error (fun detail ->
          Printf.sprintf "remote_ssh_env_invalid: %s" detail)
      in
      if wire_denied_env_name name
      then loop acc rest
      else if List.mem name endpoint.Exec_ssh_endpoint.env_allowlist
      then loop ((name, value) :: acc) rest
      else
        Error
          (Printf.sprintf
             "remote_ssh_env_not_allowlisted: endpoint %s does not allow %s"
             endpoint.name name)
  in
  loop [] (Array.to_list env)
;;

let append_error stderr error =
  if String.equal stderr ""
  then error
  else if String.ends_with ~suffix:"\n" stderr
  then stderr ^ error
  else stderr ^ "\n" ^ error
;;

let rs = Char.chr 0x1e

let split_final_trailer stderr =
  match String.rindex_opt stderr rs with
  | None -> Error "no result trailer delimiter"
  | Some close_i when close_i <> String.length stderr - 1 ->
    Error "bytes followed the final result trailer delimiter"
  | Some close_i ->
    (match String.rindex_from_opt stderr (close_i - 1) rs with
     | None -> Error "result trailer has no opening delimiter"
     | Some open_i ->
       let trailer = String.sub stderr open_i (close_i - open_i + 1) in
       let payload_stderr = String.sub stderr 0 open_i in
       Ok (payload_stderr, trailer))
;;

let trailer_tail_limit = 64 * 1024

type stderr_stream =
  { callback : (string -> unit) option
  ; mutable tail : string
  }

let stream_stderr_chunk stream chunk =
  let combined = stream.tail ^ chunk in
  let excess = String.length combined - trailer_tail_limit in
  if excess > 0
  then (
    Option.iter (fun callback -> callback (String.sub combined 0 excess)) stream.callback;
    stream.tail <- String.sub combined excess (String.length combined - excess))
  else stream.tail <- combined
;;

let flush_stderr_payload stream payload =
  if payload <> "" then Option.iter (fun callback -> callback payload) stream.callback;
  stream.tail <- ""
;;

let local_wall_budget t timeout_sec =
  (* Two seconds for the shim's TERM→KILL grace and one second for its final
     pipe drain, plus one second for the ssh channel to deliver the trailer. *)
  float_of_int t.endpoint.connect_timeout_sec +. timeout_sec +. 4.0
;;

let path_is_at_or_below ~root path =
  String.equal path root
  || String.starts_with ~prefix:(root ^ Filename.dir_sep) path
;;

let remote_cwd t cwd =
  if path_is_at_or_below ~root:t.endpoint.remote_root cwd
  then Ok cwd
  else if path_is_at_or_below ~root:t.host_playground_root cwd
  then
    let suffix =
      String.sub cwd (String.length t.host_playground_root)
        (String.length cwd - String.length t.host_playground_root)
    in
    Ok (t.endpoint.remote_root ^ suffix)
  else
    Error
      (Printf.sprintf
         "remote_ssh_path_jail_violation: endpoint %s cwd %s is outside %s"
         t.endpoint.name cwd t.host_playground_root)
;;

let runner ~timeout_sec t =
  fun ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd ->
    let endpoint_name = t.endpoint.name in
    match wire_env t.endpoint env with
    | Error error -> Unix.WEXITED 1, "", error
    | Ok env ->
      let stdin = Option.value stdin_content ~default:"" in
      let cwd = Option.value cwd ~default:t.endpoint.remote_root in
      (match remote_cwd t cwd with
       | Error error -> Unix.WEXITED 1, "", error
       | Ok cwd ->
      let request : Exec_ssh_protocol.request =
        { v = Exec_ssh_protocol.protocol_version
        ; argv
        ; env
        ; cwd
        ; timeout_sec
        ; stdin_len = Int64.of_int (String.length stdin)
        }
      in
      (match Exec_ssh_protocol.encode_request request ~stdin with
       | Error error -> Unix.WEXITED 1, "", error
       | Ok frame ->
         if Atomic.compare_and_set t.shared.first_dispatch_logged false true
         then
           Log.Keeper.info
             "remote SSH dispatch enabled endpoint=%s host=%s port=%d"
             endpoint_name t.endpoint.host t.endpoint.port;
         Eio.Switch.run (fun sw ->
           Eio.Semaphore.acquire t.shared.semaphore;
           Eio.Switch.on_release sw (fun () ->
             Eio.Semaphore.release t.shared.semaphore);
           let stderr_stream = { callback = on_stderr_chunk; tail = "" } in
           let budget = local_wall_budget t timeout_sec in
           let ssh_status, stdout, raw_stderr =
             Process_eio.run_argv_with_stdin_held_open_and_status_split
               ~timeout_sec:budget
               ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
               ?on_stdout_chunk
               ~on_stderr_chunk:(stream_stderr_chunk stderr_stream)
               ~stdin_content:frame
               (ssh_argv t)
           in
           let local_timed_out =
             Process_eio.exit_reason_of_status ssh_status = Process_eio.Timed_out
           in
           match split_final_trailer raw_stderr with
           | Error detail ->
             flush_stderr_payload stderr_stream stderr_stream.tail;
             let error =
               if local_timed_out
               then local_timeout_error endpoint_name budget
               else transport_error endpoint_name detail
             in
             Unix.WEXITED 1, stdout, append_error raw_stderr error
           | Ok (payload_stderr, trailer_bytes) ->
             let streamed_payload =
               match split_final_trailer stderr_stream.tail with
               | Ok (payload, _) -> payload
               | Error _ -> stderr_stream.tail
             in
             flush_stderr_payload stderr_stream streamed_payload;
             if ssh_status = Unix.WEXITED 255 || local_timed_out
             then
               let error =
                 if local_timed_out
                 then local_timeout_error endpoint_name budget
                 else transport_error endpoint_name "ssh client exited 255"
               in
               Unix.WEXITED 1, stdout, append_error payload_stderr error
             else
               (match Exec_ssh_protocol.parse_trailer trailer_bytes with
                | Error error ->
                  ( Unix.WEXITED 1
                  , stdout
                  , append_error payload_stderr
                      (transport_error endpoint_name error) )
                | Ok trailer
                  when trailer.timed_out && ssh_status = Unix.WEXITED 0 ->
                  ( Unix.WEXITED 1
                  , stdout
                  , append_error payload_stderr
                      (remote_timeout_error endpoint_name timeout_sec) )
                | Ok { shim_error = Some error; _ }
                  when ssh_status = Unix.WEXITED 1 ->
                  Unix.WEXITED 1, stdout, append_error payload_stderr error
                | Ok { exit = Some code; signal = None; shim_error = None; _ }
                  when ssh_status = Unix.WEXITED 0 ->
                  Unix.WEXITED code, stdout, payload_stderr
                | Ok { signal = Some signal; exit = None; shim_error = None; _ }
                  when ssh_status = Unix.WEXITED 0 ->
                  Unix.WSIGNALED signal, stdout, payload_stderr
                | Ok _ ->
                  ( Unix.WEXITED 1
                  , stdout
                  , append_error payload_stderr
                      (transport_error endpoint_name
                         "ssh status and result trailer disagree") )))))
;;
