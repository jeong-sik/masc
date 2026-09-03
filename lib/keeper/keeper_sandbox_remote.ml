(** Transport-neutral runner for the remote execution lane.

    A remote endpoint is a machine that owns the keeper's working tree and
    runs [masc-exec-shim]. The keeper side frames one request onto the shim's
    stdin ({!Exec_ssh_protocol}), streams the payload's stdout and stderr
    back, and reads the result trailer off stderr. Nothing in that exchange
    depends on how the bytes reach the shim, so the transport is a value:

    - {!Openssh}: the pinned OpenSSH argv of RFC-0395, for an endpoint
      declared in [runtime.toml];
    - {!Container_exec}: [container exec -i <guest> masc-exec-shim], for an
      Apple [container] guest that owns its tree on a named volume
      (RFC-0400). The guest runs on this host, so there is no key, no pinned
      host key and no sshd: the CLI is the channel.

    Error codes carry the lane, [remote_ssh_*] for OpenSSH and
    [microvm_remote_*] for the guest, so a log line names the transport that
    failed. Codes the shim mints on the endpoint
    ([remote_ssh_path_jail_violation], [remote_ssh_shim_config_error]) and
    the transport-neutral preflight codes ([remote_git_unavailable],
    [remote_ripgrep_unavailable], [remote_shim_version_skew],
    [remote_github_identity_missing], [remote_github_unreachable]) pass
    through unchanged. *)

let ( let* ) = Result.bind

type openssh =
  { endpoint : Exec_ssh_endpoint.t
  ; ssh_bin : string
  ; identity_file : string
  ; known_hosts_file : string
  ; control_path_dir : string
  }

type container_exec =
  { cli : string list
  ; container_name : string
  ; uid : int
  ; gid : int
  ; shim_path : string
  ; shim_config_path : string
  }

type transport =
  | Openssh of openssh
  | Container_exec of container_exec

(* The remote command is always this literal. Request data travels only in
   the framed stdin protocol, never in the transport argv. *)
let shim_command = "masc-exec-shim"
let probe_flag = "--probe"

let lane_prefix = function
  | Openssh _ -> "remote_ssh"
  | Container_exec _ -> "microvm_remote"
;;

type shared_state =
  { semaphore : Eio.Semaphore.t
  ; first_dispatch_logged : bool Atomic.t
  }

(* Runner values are rebuilt per typed dispatch, while the session ceiling
   (sshd MaxSessions for OpenSSH, a courtesy bound for a guest) is
   endpoint-scoped. Keep the admission state at that same scope. This is a
   module-global registry, so Stdlib.Mutex is the correct guard; no yielding
   work or logging happens while it is held. *)
let shared_states : (string, shared_state) Hashtbl.t = Hashtbl.create 8
let shared_states_mu = Stdlib.Mutex.create ()

let shared_state ~base_path ~name ~max_concurrent_sessions =
  let key = Printf.sprintf "%s\x00%s\x00%d" base_path name max_concurrent_sessions in
  Stdlib.Mutex.protect shared_states_mu (fun () ->
    match Hashtbl.find_opt shared_states key with
    | Some state -> state
    | None ->
      let state =
        { semaphore = Eio.Semaphore.make max_concurrent_sessions
        ; first_dispatch_logged = Atomic.make false
        }
      in
      Hashtbl.add shared_states key state;
      state)
;;

type t =
  { name : string
  ; transport : transport
  ; remote_root : string
  ; env_allowlist : string list
  ; connect_timeout_sec : int
  ; gh_config_dir : string
  ; injected_env : (string * string) list
    (* Server-authored env beyond the two every lane injects: what the
       endpoint's runtime was given and must be told about (a guest's
       config mount). Never caller-supplied, so never under the allowlist. *)
  ; base_path : string
  ; keeper_name : string
  ; shared : shared_state
  }

let name t = t.name
let remote_root t = t.remote_root
let transport t = t.transport

let keeper_root ~remote_root ~keeper_name =
  Filename.concat remote_root (Playground_paths.sanitize_keeper_name keeper_name)
;;

let remote_keeper_root t = keeper_root ~remote_root:t.remote_root ~keeper_name:t.keeper_name
let gh_config_dir t = t.gh_config_dir

let of_openssh ~base_path ~keeper_name (o : openssh) =
  let remote_root = o.endpoint.remote_root in
  { name = o.endpoint.name
  ; transport = Openssh o
  ; remote_root
  ; env_allowlist = o.endpoint.env_allowlist
  ; connect_timeout_sec = o.endpoint.connect_timeout_sec
  ; gh_config_dir = Filename.concat (keeper_root ~remote_root ~keeper_name) ".config/gh"
  ; injected_env = []
  ; base_path
  ; keeper_name
  ; shared =
      shared_state ~base_path ~name:o.endpoint.name
        ~max_concurrent_sessions:o.endpoint.max_concurrent_sessions
  }
;;

let of_container_exec
      ~base_path
      ~keeper_name
      ~remote_root
      ~gh_config_dir
      ~injected_env
      ~env_allowlist
      ~connect_timeout_sec
      ~max_concurrent_sessions
      (c : container_exec)
  =
  { name = c.container_name
  ; transport = Container_exec c
  ; remote_root
  ; env_allowlist
  ; connect_timeout_sec
  ; gh_config_dir
  ; injected_env
  ; base_path
  ; keeper_name
  ; shared = shared_state ~base_path ~name:c.container_name ~max_concurrent_sessions
  }
;;

(* ── Transport argv ──────────────────────────────────────────────────── *)

let openssh_prefix (o : openssh) =
  let endpoint = o.endpoint in
  [ o.ssh_bin
  ; "-T"
  ; "-F"
  ; "none"
  ; "-o"
  ; "BatchMode=yes"
  ; "-o"
  ; "IdentitiesOnly=yes"
  ; "-i"
  ; o.identity_file
  ; "-o"
  ; "ForwardAgent=no"
  ; "-o"
  ; "ClearAllForwardings=yes"
  ; "-o"
  ; "StrictHostKeyChecking=yes"
  ; "-o"
  ; "UserKnownHostsFile=" ^ o.known_hosts_file
  ; "-o"
  ; Printf.sprintf "ConnectTimeout=%d" endpoint.connect_timeout_sec
  ; "-o"
  ; "ControlMaster=auto"
  ; "-o"
  ; "ControlPersist=120"
  ; "-o"
  ; "ControlPath=" ^ Filename.concat o.control_path_dir "%C"
  ; "-o"
  ; "ServerAliveInterval=15"
  ; "-o"
  ; "ServerAliveCountMax=2"
  ; "-p"
  ; string_of_int endpoint.port
  ; endpoint.user ^ "@" ^ endpoint.host
  ]
;;

(* [-w] is only the initial directory of the exec'd process; the shim moves
   to the request cwd itself and jails it under the config root. The shim
   config location is the one environment entry the shim reads for itself
   ([Exec_ssh_protocol.shim_config_env_var]); payload env never travels this
   way. *)
let container_exec_prefix (c : container_exec) ~remote_root =
  c.cli
  @ [ "exec"
    ; "-i"
    ; "--user"
    ; Printf.sprintf "%d:%d" c.uid c.gid
    ; "-w"
    ; remote_root
    ; "--env"
    ; Exec_ssh_protocol.shim_config_env_var ^ "=" ^ c.shim_config_path
    ; c.container_name
    ]
;;

let transport_argv t =
  match t.transport with
  | Openssh o -> openssh_prefix o @ [ shim_command ]
  | Container_exec c -> container_exec_prefix c ~remote_root:t.remote_root @ [ c.shim_path ]
;;

(* OpenSSH hands the remote command to a shell, so the probe is one word;
   [container exec] takes an argv, so the flag is its own element. *)
let probe_argv t =
  match t.transport with
  | Openssh o -> openssh_prefix o @ [ shim_command ^ " " ^ probe_flag ]
  | Container_exec c ->
    container_exec_prefix c ~remote_root:t.remote_root @ [ c.shim_path; probe_flag ]
;;

let host_label t =
  match t.transport with
  | Openssh o -> o.endpoint.host
  | Container_exec c -> c.container_name
;;

(* ── Error codes ─────────────────────────────────────────────────────── *)

let code t suffix = lane_prefix t.transport ^ "_" ^ suffix

let transport_error t detail =
  Printf.sprintf "%s: endpoint %s: %s" (code t "transport_error") t.name detail
;;

let local_timeout_error t budget =
  Printf.sprintf
    "%s: endpoint %s exceeded local wall-clock budget %.2fs"
    (code t "local_timeout") t.name budget
;;

let remote_timeout_error t timeout_sec =
  Printf.sprintf
    "%s: endpoint %s payload exceeded remote timeout %.2fs"
    (code t "remote_timeout") t.name timeout_sec
;;

(* ── Wire environment ────────────────────────────────────────────────── *)

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

let wire_env t env =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
      let* name, value =
        env_name entry
        |> Result.map_error (fun detail ->
          Printf.sprintf "%s: %s" (code t "env_invalid") detail)
      in
      if wire_denied_env_name name
      then loop acc rest
      else if List.mem name t.env_allowlist
      then loop ((name, value) :: acc) rest
      else
        Error
          (Printf.sprintf
             "%s: endpoint %s does not allow %s"
             (code t "env_not_allowlisted") t.name name)
  in
  loop [] (Array.to_list env)
;;

(* Server-authored env for every exec frame, deliberately outside the
   endpoint env_allowlist (which governs caller-supplied values).
   GH_CONFIG_DIR names the endpoint-resident identity preflight already
   proved (remote_github_identity_missing); without it every gh/git call in
   a frame runs identity-blind. A frame has no tty, so a git that wants to
   prompt for credentials must fail instead of hanging the call. *)
let injected_env t =
  let lane = [ "GH_CONFIG_DIR", t.gh_config_dir; "GIT_TERMINAL_PROMPT", "0" ] in
  lane @ List.filter (fun (name, _) -> not (List.mem_assoc name lane)) t.injected_env
;;

(* ── Result trailer ──────────────────────────────────────────────────── *)

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

(* The trailer is the final RS-delimited frame, so its opening delimiter is the
   second-to-last RS of the completed stream, and every byte before that RS is
   payload no matter what arrives next. Returns how much of [text] can be handed
   to the caller now. Holding the whole tail back instead would delay a stderr
   line until the process exits, and [gh auth login] writes its one-time code to
   stderr and then waits for the browser: a code delivered at exit arrives after
   the login it was needed for has already timed out. *)
let releasable_prefix_len text =
  match String.rindex_opt text rs with
  | None -> String.length text
  | Some last ->
    (match String.rindex_from_opt text (last - 1) rs with
     | None -> last
     | Some second_last -> second_last)
;;

let stream_stderr_chunk stream chunk =
  let combined = stream.tail ^ chunk in
  (* The tail limit still bounds the retained region when payload bytes carry an
     RS of their own; a trailer is orders of magnitude below it. *)
  let release =
    max (releasable_prefix_len combined) (String.length combined - trailer_tail_limit)
  in
  if release > 0
  then (
    Option.iter
      (fun callback -> callback (String.sub combined 0 release))
      stream.callback;
    stream.tail <- String.sub combined release (String.length combined - release))
  else stream.tail <- combined
;;

let flush_stderr_payload stream payload =
  if payload <> "" then Option.iter (fun callback -> callback payload) stream.callback;
  stream.tail <- ""
;;

(* ── Runner ──────────────────────────────────────────────────────────── *)

let local_wall_budget t timeout_sec =
  (* Two seconds for the shim's TERM→KILL grace and one second for its final
     pipe drain, plus one second for the channel to deliver the trailer. *)
  float_of_int t.connect_timeout_sec +. timeout_sec +. 4.0
;;

let remote_cwd t cwd =
  (* Both strings name paths on the endpoint, so cleanup is lexical only:
     resolving them against the host filesystem substitutes host symlinks and
     macOS firmlinks into a cwd the shim then cannot enter (see
     Keeper_remote_path.normalize_remote). *)
  let normalized = Keeper_remote_path.normalize_remote cwd in
  let endpoint_root = Keeper_remote_path.normalize_remote t.remote_root in
  if String.equal normalized endpoint_root
  then Ok endpoint_root
  else
    Keeper_remote_path.host_to_remote ~base_path:t.base_path
      ~remote_root:t.remote_root ~keeper:t.keeper_name cwd
;;

(* A transport that failed on its own, before or instead of the shim. OpenSSH
   reserves exit 255 for the client. [container exec] exits 1 for its own
   faults, the same code a shim-level failure uses, so the guest lane tells
   the two apart by the trailer alone: a shim failure always writes one, a
   CLI fault never does. *)
let transport_failure t status =
  match t.transport, status with
  | Openssh _, Unix.WEXITED 255 -> Some "ssh client exited 255"
  | (Openssh _ | Container_exec _), _ -> None
;;

let log_first_dispatch t =
  match t.transport with
  | Openssh o ->
    Log.Keeper.info
      "remote SSH dispatch enabled endpoint=%s host=%s port=%d"
      t.name o.endpoint.host o.endpoint.port
  | Container_exec c ->
    Log.Keeper.info
      "remote microvm dispatch enabled container=%s shim=%s"
      c.container_name c.shim_path
;;

let runner ~timeout_sec t =
  fun ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd ->
    match wire_env t env with
    | Error error -> Unix.WEXITED 1, "", error
    | Ok env ->
      let injected = injected_env t in
      let env =
        (* Injected values are the only writers of their names: an
           allowlisted caller copy would otherwise depend on libc getenv
           duplicate order. *)
        injected
        @ List.filter (fun (name, _) -> not (List.mem_assoc name injected)) env
      in
      let stdin = Option.value stdin_content ~default:"" in
      let cwd = Option.value cwd ~default:t.remote_root in
      (match remote_cwd t cwd with
       | Error error -> Unix.WEXITED 1, "", error
       | Ok cwd ->
      let request : Exec_ssh_protocol.request =
        { v = Exec_ssh_protocol.protocol_version
        ; argv
        ; env
        ; cwd
        ; remote_root = t.remote_root
        ; timeout_sec
        ; stdin_len = Int64.of_int (String.length stdin)
        }
      in
      (match Exec_ssh_protocol.encode_request request ~stdin with
       | Error error -> Unix.WEXITED 1, "", error
       | Ok frame ->
         if Atomic.compare_and_set t.shared.first_dispatch_logged false true
         then log_first_dispatch t;
         Eio.Switch.run (fun sw ->
           Eio.Semaphore.acquire t.shared.semaphore;
           Eio.Switch.on_release sw (fun () ->
             Eio.Semaphore.release t.shared.semaphore);
           let path_stream emit =
             Keeper_remote_path.stream ~base_path:t.base_path
               ~remote_root:t.remote_root ~keeper:t.keeper_name ~emit
           in
           let stdout_path_stream = Option.map path_stream on_stdout_chunk in
           let stderr_path_stream = Option.map path_stream on_stderr_chunk in
           let stderr_stream =
             { callback =
                 Option.map Keeper_remote_path.rewrite_stream_chunk
                   stderr_path_stream
             ; tail = ""
             }
           in
           let rewrite text =
             Keeper_remote_path.rewrite_output ~base_path:t.base_path
               ~remote_root:t.remote_root ~keeper:t.keeper_name text
           in
           let budget = local_wall_budget t timeout_sec in
           let status, stdout, raw_stderr =
             Process_eio.run_argv_with_stdin_held_open_and_status_split
               ~timeout_sec:budget
               ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
               ?on_stdout_chunk:
                 (Option.map Keeper_remote_path.rewrite_stream_chunk
                    stdout_path_stream)
               ~on_stderr_chunk:(stream_stderr_chunk stderr_stream)
               ~stdin_content:frame
               (transport_argv t)
           in
           Option.iter Keeper_remote_path.finish_stream stdout_path_stream;
           let local_timed_out =
             Process_eio.exit_reason_of_status status = Process_eio.Timed_out
           in
           match split_final_trailer raw_stderr with
           | Error detail ->
             flush_stderr_payload stderr_stream stderr_stream.tail;
             Option.iter Keeper_remote_path.finish_stream stderr_path_stream;
             let error =
               if local_timed_out
               then local_timeout_error t budget
               else transport_error t detail
             in
             Unix.WEXITED 1, rewrite stdout, append_error (rewrite raw_stderr) error
           | Ok (payload_stderr, trailer_bytes) ->
             let streamed_payload =
               match split_final_trailer stderr_stream.tail with
               | Ok (payload, _) -> payload
               | Error _ -> stderr_stream.tail
             in
             flush_stderr_payload stderr_stream streamed_payload;
             Option.iter Keeper_remote_path.finish_stream stderr_path_stream;
             let stdout = rewrite stdout in
             let payload_stderr = rewrite payload_stderr in
             (match local_timed_out, transport_failure t status with
              | true, _ ->
                ( Unix.WEXITED 1
                , stdout
                , append_error payload_stderr (local_timeout_error t budget) )
              | false, Some detail ->
                ( Unix.WEXITED 1
                , stdout
                , append_error payload_stderr (transport_error t detail) )
              | false, None ->
                (match Exec_ssh_protocol.parse_trailer trailer_bytes with
                 | Error error ->
                   ( Unix.WEXITED 1
                   , stdout
                   , append_error payload_stderr (transport_error t error) )
                 | Ok trailer
                   when trailer.timed_out && status = Unix.WEXITED 0 ->
                   ( Unix.WEXITED 1
                   , stdout
                   , append_error payload_stderr
                       (remote_timeout_error t timeout_sec) )
                 | Ok { shim_error = Some error; _ }
                   when status = Unix.WEXITED 1 ->
                   Unix.WEXITED 1, stdout, append_error payload_stderr error
                 | Ok { exit = Some code; signal = None; shim_error = None; _ }
                   when status = Unix.WEXITED 0 ->
                   Unix.WEXITED code, stdout, payload_stderr
                 | Ok { signal = Some signal; exit = None; shim_error = None; _ }
                   when status = Unix.WEXITED 0 ->
                   Unix.WSIGNALED signal, stdout, payload_stderr
                 | Ok _ ->
                   ( Unix.WEXITED 1
                   , stdout
                   , append_error payload_stderr
                       (transport_error t
                          "transport status and result trailer disagree") ))))))
;;

(* ── Preflight ───────────────────────────────────────────────────────── *)

type preflight_cache_entry =
  { checked_at : float
  ; result : (unit, string) result
  }

let preflight_cache : (string, preflight_cache_entry) Hashtbl.t = Hashtbl.create 8
let preflight_cache_mu = Stdlib.Mutex.create ()

let transport_key t =
  match t.transport with
  | Openssh o -> o.ssh_bin
  | Container_exec c -> c.container_name
;;

let preflight_cache_key t =
  Printf.sprintf "%s\x00%s\x00%s\x00%s" t.base_path t.name t.keeper_name (transport_key t)
;;

let cached_preflight ~now t =
  let ttl = float_of_int (Env_config_sandbox.Preflight.ssh_ttl_sec ()) in
  if ttl <= 0.0
  then None
  else
    Stdlib.Mutex.protect preflight_cache_mu (fun () ->
      match Hashtbl.find_opt preflight_cache (preflight_cache_key t) with
      | Some entry when now -. entry.checked_at < ttl -> Some entry.result
      | Some _ | None -> None)
;;

let store_preflight ~now t result =
  Stdlib.Mutex.protect preflight_cache_mu (fun () ->
    Hashtbl.replace preflight_cache (preflight_cache_key t)
      { checked_at = now; result })
;;

let preflight_timeout_sec t = float_of_int t.connect_timeout_sec +. 5.0

let run_probe t =
  let status, stdout, stderr =
    Process_eio.run_argv_with_status_split
      ~timeout_sec:(preflight_timeout_sec t)
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      (probe_argv t)
  in
  match status with
  | Unix.WEXITED 0 ->
    (match Exec_ssh_protocol.parse_probe (String.trim stdout) with
     | Error error ->
       Error
         (Printf.sprintf "%s: endpoint %s: %s" (code t "probe_invalid") t.name error)
     | Ok probe ->
       let want = string_of_int Exec_ssh_protocol.protocol_version in
       if Exec_ssh_protocol.probe_major_compatible ~want probe.version
       then Ok ()
       else
         Error
           (Printf.sprintf
              "remote_shim_version_skew: endpoint %s requires major %s but remote reports %s"
              t.name want probe.version))
  | Unix.WEXITED exit_code ->
    Error
      (Printf.sprintf
         "%s: endpoint %s host %s exited %d: %s"
         (code t "endpoint_unreachable") t.name (host_label t) exit_code
         (Exec_policy.truncate_for_log stderr))
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Error
      (Printf.sprintf
         "%s: endpoint %s host %s signal %d"
         (code t "endpoint_unreachable") t.name (host_label t) signal)
;;

(* [test -d] writes nothing to stderr: it answers by exit code alone. A
   failure reported as "exit=1 stderr=" therefore says a check failed without
   saying what it looked at, and the operator cannot act on it. The argv is
   what was actually run, so it carries the path the check was about.

   Every preflight argv is a fixed shape built in [perform_preflight] --
   git --version, rg --version, two test -d, df -Pk, gh auth status -- and
   carries paths rather than credentials. A future preflight that needs a
   secret has to keep it out of argv, the same rule the runner already
   follows. *)
let preflight_argv_for_log argv =
  Exec_policy.truncate_for_log (String.concat " " argv)
;;

let run_preflight_command t ~error_code argv =
  let run = runner ~timeout_sec:(preflight_timeout_sec t) t in
  let status, stdout, stderr =
    run ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
      ~argv ~env:[||] ~cwd:(Some t.remote_root)
  in
  match status with
  | Unix.WEXITED 0 -> Ok stdout
  | Unix.WEXITED exit_code ->
    Error
      (Printf.sprintf "%s: endpoint %s ran [%s] exit=%d stderr=%s"
         error_code t.name (preflight_argv_for_log argv) exit_code
         (Exec_policy.truncate_for_log stderr))
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Error
      (Printf.sprintf "%s: endpoint %s ran [%s] signal=%d stderr=%s"
         error_code t.name (preflight_argv_for_log argv) signal
         (Exec_policy.truncate_for_log stderr))
;;

(* A failed [gh auth status] is not an identity verdict by itself. With the
   endpoint off the network -- microvm [network_mode = "none"], measured
   2026-09-02 on pr-updater -- gh cannot reach api.github.com and folds that
   transport failure into "The token ... is invalid.", so the preflight
   reported remote_github_identity_missing for a token that was valid on the
   host and byte-identical in the guest, and the keeper idled on a blocker
   that did not exist. Ask the endpoint whether the API answers at all
   before repeating gh's verdict: an unreachable API withholds it. curl
   absent (127) keeps the old classification rather than inventing a verdict
   this probe cannot make. No [-f]: any HTTP answer, including an error
   status, proves the transport. *)
type github_transport =
  | Api_reachable
  | Api_unreachable of string
  | Probe_absent

let github_api_probe_argv =
  [ "curl"; "-sS"; "-o"; "/dev/null"; "--max-time"; "8"; "https://api.github.com" ]

let github_transport t =
  let run = runner ~timeout_sec:(preflight_timeout_sec t) t in
  let status, _stdout, _stderr =
    run ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
      ~argv:github_api_probe_argv ~env:[||] ~cwd:(Some t.remote_root)
  in
  match status with
  | Unix.WEXITED 0 -> Api_reachable
  | Unix.WEXITED 127 -> Probe_absent
  | Unix.WEXITED code -> Api_unreachable (Printf.sprintf "exit=%d" code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Api_unreachable (Printf.sprintf "signal=%d" signal)
;;

let whitespace_tokens line =
  line
  |> String.split_on_char ' '
  |> List.concat_map (String.split_on_char '\t')
  |> List.filter (fun token -> token <> "")
;;

let available_kib output =
  output
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
  |> List.rev
  |> List.find_map (fun line ->
    match whitespace_tokens line with
    | _filesystem :: _blocks :: _used :: available :: _ ->
      int_of_string_opt available
    | _ -> None)
;;

let perform_preflight t =
  let* () = run_probe t in
  let* _ =
    run_preflight_command t ~error_code:"remote_git_unavailable"
      [ "git"; "--version" ]
  in
  let* _ =
    run_preflight_command t ~error_code:"remote_ripgrep_unavailable"
      [ "rg"; "--version" ]
  in
  let* _ =
    run_preflight_command t ~error_code:(code t "root_missing")
      [ "test"; "-d"; t.remote_root ]
  in
  let* _ =
    run_preflight_command t ~error_code:(code t "keeper_root_missing")
      [ "test"; "-d"; remote_keeper_root t ]
  in
  let* disk =
    run_preflight_command t ~error_code:(code t "disk_probe_failed")
      [ "df"; "-Pk"; t.remote_root ]
  in
  let minimum = Env_config_sandbox.Preflight.ssh_disk_free_min_kib () in
  let* () =
    match available_kib disk with
    | Some available when available >= minimum -> Ok ()
    | Some available ->
      Error
        (Printf.sprintf
           "%s: endpoint %s available_kib=%d minimum_kib=%d"
           (code t "disk_low") t.name available minimum)
    | None ->
      Error
        (Printf.sprintf
           "%s: endpoint %s returned unparseable df output"
           (code t "disk_probe_failed") t.name)
  in
  let* () =
    match
      run_preflight_command t ~error_code:"remote_github_identity_missing"
        [ "env"; "GH_CONFIG_DIR=" ^ t.gh_config_dir; "gh"; "auth"; "status" ]
    with
    | Ok _ -> Ok ()
    | Error identity_error ->
      (match github_transport t with
       | Api_reachable | Probe_absent -> Error identity_error
       | Api_unreachable cause ->
         Error
           (Printf.sprintf
              "remote_github_unreachable: endpoint %s cannot reach \
               https://api.github.com (curl %s), identity verdict withheld -- %s"
              t.name cause identity_error))
  in
  Ok ()
;;

let check_preflight ?(force = false) t =
  (* NDT-OK: wall time controls only readiness-cache freshness; it is neither
     persisted authority nor a policy decision. *)
  let now = Unix.gettimeofday () in
  match if force then None else cached_preflight ~now t with
  | Some result -> result
  | None ->
    let result = perform_preflight t in
    store_preflight ~now t result;
    result
;;

module For_testing = struct
  let clear_preflight_cache () =
    Stdlib.Mutex.protect preflight_cache_mu (fun () -> Hashtbl.clear preflight_cache)
end
