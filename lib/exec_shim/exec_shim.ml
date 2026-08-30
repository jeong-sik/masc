(* Core of the masc-exec-shim remote execution shim.  See the .mli for the
   contract; normative spec: docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2. *)

(* pdeathsig is Linux-only; the C stub is a no-op elsewhere (the pgid-kill
   policy is the primary reaper there).  The signal is fixed to SIGKILL
   inside the stub: OCaml's [Sys.sig*] constants are abstract codes, not
   host OS signal numbers, so they must never reach prctl. *)
external set_pdeathsig : unit -> unit = "ocaml_prctl_set_pdeathsig"

(* OCaml's [Sys.sig*] constants and the signal in [Unix.WSIGNALED] are
   portable abstract codes (negative ints), not host OS signal numbers.
   The wire trailer carries the host number, so convert through the
   runtime's own table. *)
external host_signal_number : int -> int = "ocaml_shim_host_signal_number"

let jail_error_code = "remote_ssh_path_jail_violation"
let config_error_code = "remote_ssh_shim_config_error"
let shim_error_code = "remote_ssh_shim_error"

(* {1 Environment synthesis} *)

let default_base_path = "/usr/local/bin:/usr/bin:/bin"

let denylist_exact =
  [ "PATH"; "HOME"; "LD_PRELOAD"; "LD_LIBRARY_PATH"; "BASH_ENV"; "ENV" ]

let denylisted_env_name name =
  List.mem name denylist_exact || String.starts_with ~prefix:"DYLD_" name

(* These names are authored by the SSH runner for every request. They do not
   belong to the endpoint's caller-controlled env allowlist: without them the
   preflight can prove a Keeper identity that the payload can never use. *)
let runtime_env_allowlist = [ "GH_CONFIG_DIR"; "GIT_TERMINAL_PROMPT" ]

let env_of_process () =
  Array.to_list (Unix.environment ())
  |> List.filter_map (fun kv ->
      match String.index_opt kv '=' with
      | Some i ->
        Some (String.sub kv 0 i, String.sub kv (i + 1) (String.length kv - i - 1))
      | None -> None)

let synthesize_env ~base_env ~allowlist ~request_env =
  let shim_env = base_env in
  let lookup key default =
    match List.assoc_opt key shim_env with
    | Some v -> v
    | None -> default in
  let base = [ ("PATH", default_base_path)
             ; ("HOME", lookup "HOME" "/tmp")
             ; ("USER", lookup "USER" "masc")
             ; ("TMPDIR", lookup "TMPDIR" "/tmp") ] in
  let upsert env (k, v) =
    if (List.mem k runtime_env_allowlist || List.mem k allowlist)
       && not (denylisted_env_name k)
    then (k, v) :: List.remove_assoc k env
    else env in
  List.fold_left upsert base request_env

(* {1 Kill policy} *)

let kill_grace_sec = 2.0

type kill_trigger =
  | On_eof
  | On_timeout
  | On_child_exit

type kill_action =
  | Sigterm_pgid
  | Wait_grace of float
  | Sigkill_pgid

let kill_policy ?(grace_sec = kill_grace_sec) = function
  | On_eof | On_timeout -> [ Sigterm_pgid; Wait_grace grace_sec; Sigkill_pgid ]
  | On_child_exit -> [ Sigkill_pgid ]

(* {1 Waitpid status -> trailer} *)

let trailer_of_status ~timed_out status : Exec_ssh_protocol.trailer =
  match status with
  | Unix.WEXITED n ->
    Exec_ssh_protocol.{ v = protocol_version
                      ; exit = Some n
                      ; signal = None
                      ; timed_out
                      ; shim_error = None }
  | Unix.WSIGNALED n | Unix.WSTOPPED n ->
    (* WSTOPPED is unreachable (waitpid without WUNTRACED); map it like
       WSIGNALED defensively rather than fabricating an exit code.  The
       trailer carries the host OS signal number, not OCaml's abstract
       code. *)
    Exec_ssh_protocol.{ v = protocol_version
                      ; exit = None
                      ; signal = Some (host_signal_number n)
                      ; timed_out
                      ; shim_error = None }

(* {1 Path jail} *)

(* Both jail checks are containment, so they are one function; what differs is
   which mistake the caller has to name. *)
let resolve_within ~root ~path =
  try
    let rroot = Unix.realpath root in
    let rpath = Unix.realpath path in
    if rpath = rroot || String.starts_with ~prefix:(rroot ^ "/") rpath
    then Ok ()
    else Error (`Escapes (rpath, rroot))
  with
  | Unix.Unix_error (e, _, _) -> Error (`Unresolvable (Unix.error_message e))

let check_cwd_jail ~root ~cwd =
  match resolve_within ~root ~path:cwd with
  | Ok () -> Ok ()
  | Error (`Escapes (rcwd, rroot)) ->
    Error
      (Printf.sprintf "%s: cwd %s (resolved %s) escapes remote_root %s"
         jail_error_code cwd rcwd rroot)
  | Error (`Unresolvable message) ->
    Error
      (Printf.sprintf "%s: cannot resolve cwd %s: %s" jail_error_code cwd message)

(* The config states the widest root this host will ever hand out; the request
   names the one it wants for this call. Checking the second inside the first
   is what lets one host serve endpoints whose roots differ -- and keeps a
   request from choosing its own jail, which would be no jail at all. *)
let check_request_root_jail ~config_root ~request_root =
  match resolve_within ~root:config_root ~path:request_root with
  | Ok () -> Ok ()
  | Error (`Escapes (rrequest, rconfig)) ->
    Error
      (Printf.sprintf
         "%s: request remote_root %s (resolved %s) escapes this host's \
          remote_root %s"
         jail_error_code request_root rrequest rconfig)
  | Error (`Unresolvable message) ->
    Error
      (Printf.sprintf "%s: cannot resolve request remote_root %s: %s"
         jail_error_code request_root message)

(* {1 Config file} *)

type config =
  { remote_root : string
  ; env_allowlist : string list
  }

let config_env_var = "MASC_EXEC_SHIM_CONFIG"
let default_config_path = "/etc/masc-exec-shim.conf"

let parse_config content =
  let err fmt = Printf.ksprintf (fun m -> Error (config_error_code ^ ": " ^ m)) fmt in
  let parse_line n line acc =
    let line = String.trim line in
    if line = "" || String.starts_with ~prefix:"#" line
    then Ok acc
    else
      match String.index_opt line '=' with
      | None -> err "line %d is not key=value: %S" (n + 1) line
      | Some i ->
        let key = String.trim (String.sub line 0 i) in
        let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
        if List.mem_assoc key acc
        then err "duplicate key %S (line %d)" key (n + 1)
        else Ok ((key, value) :: acc) in
  match
    List.fold_left
      (fun acc (n, line) -> Result.bind acc (parse_line n line))
      (Ok [])
      (List.mapi (fun i l -> (i, l)) (String.split_on_char '\n' content))
  with
  | Error _ as e -> e
  | Ok entries ->
    let unknown =
      List.filter_map
        (fun (k, _) ->
           if k = "remote_root" || k = "env_allowlist" then None else Some k)
        entries in
    (match unknown with
     | k :: _ -> err "unknown key %S" k
     | [] ->
       (match List.assoc_opt "remote_root" entries with
        | None -> err "missing required key \"remote_root\""
        | Some "" -> err "remote_root must not be empty"
        | Some root when not (String.starts_with ~prefix:"/" root) ->
          err "remote_root must be an absolute path, got %S" root
        | Some root ->
          let env_allowlist =
            match List.assoc_opt "env_allowlist" entries with
            | None -> []
            | Some v ->
              String.split_on_char ',' v
              |> List.map String.trim
              |> List.filter (fun s -> s <> "") in
          Ok { remote_root = root; env_allowlist }))

(* Read here rather than through Env_config_core: the shim is a standalone
   binary deployed to the remote host, where masc's config layer does not
   exist. Its dune stanza names exec_ssh_protocol and unix and nothing else,
   and pulling the config library across would ship that whole layer to every
   exec host. The env-read ratchet counts this site for that reason. *)
let config_path () =
  match Sys.getenv_opt config_env_var with
  | Some p when p <> "" -> p
  | _ -> default_config_path

let load_config () =
  let path = config_path () in
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic) |> parse_config)
  with
  | Sys_error _ ->
    Error
      (Printf.sprintf "%s: cannot read config file %s" config_error_code path)

(* {1 Nonblocking drain} *)

type drain_result =
  | Drain_bytes of int
  | Drain_eof
  | Drain_again

let drain_fd fd buf =
  let chunk = Bytes.create 65536 in
  let rec loop total =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> if total > 0 then Drain_bytes total else Drain_eof
    | n ->
      Buffer.add_subbytes buf chunk 0 n;
      loop (total + n)
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
      if total > 0 then Drain_bytes total else Drain_again
  in
  loop 0

(* {1 Framing} *)

let max_frame_bytes = Int64.of_int (256 * 1024 * 1024)

exception Short_read

let read_fully fd len =
  let buf = Bytes.create len in
  let rec loop off =
    if off < len
    then (
      let n = Unix.read fd buf off (len - off) in
      if n = 0 then raise Short_read;
      loop (off + n)) in
  loop 0;
  Bytes.unsafe_to_string buf

let read_frame fd =
  try
    let hdr = read_fully fd 8 in
    let len = Bytes.get_int64_be (Bytes.unsafe_of_string hdr) 0 in
    if Int64.compare len 0L < 0 || Int64.compare len max_frame_bytes > 0
    then
      Error
        (Printf.sprintf
           "remote_ssh_transport_error: frame length %Ld bytes is out of bounds"
           len)
    else (
      let body = read_fully fd (Int64.to_int len) in
      match Exec_ssh_protocol.decode_request (hdr ^ body) with
      | Error _ as e -> e
      | Ok (req, stdin_payload) -> Ok (req, stdin_payload))
  with
  | Short_read ->
    Error "remote_ssh_transport_error: truncated frame on shim stdin"

(* {1 Supervision loop} *)

let rec write_all fd s off len =
  if len > 0
  then
    match Unix.write fd (Bytes.unsafe_of_string s) off len with
    | n -> write_all fd s (off + n) (len - n)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd s off len

let spawn ~argv ~env ~cwd =
  let (stdin_r, stdin_w) = Unix.pipe () in
  let (stdout_r, stdout_w) = Unix.pipe () in
  let (stderr_r, stderr_w) = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    (* Child: own session + process group (pgid = pid), pdeathsig set
       pre-exec, pipes wired to 0/1/2, then exec.  Any failure is reported
       on the child's stderr (which the parent streams) and exits 127. *)
    (try
       ignore (Unix.setsid ());
       set_pdeathsig ();
       (* The shim ignores SIGPIPE (see [main]); ignored dispositions
          survive exec, so re-arm the default or payloads would inherit
          non-standard SIGPIPE semantics. *)
       Sys.set_signal Sys.sigpipe Sys.Signal_default;
       (* Race: the parent may have died between fork and prctl. *)
       if Unix.getppid () = 1 then exit 127;
       Unix.dup2 stdin_r Unix.stdin;
       Unix.dup2 stdout_w Unix.stdout;
       Unix.dup2 stderr_w Unix.stderr;
       List.iter Unix.close
         [ stdin_r; stdin_w; stdout_r; stdout_w; stderr_r; stderr_w ];
       Unix.chdir cwd;
       Unix.execvpe (List.hd argv) (Array.of_list argv)
         (Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) env))
     with
     | exn ->
       (try
          output_string stderr
            ("masc-exec-shim: " ^ Printexc.to_string exn ^ "\n");
          flush stderr
        with
       | _ -> ());
       exit 127)
  | pid ->
    Unix.close stdin_r;
    Unix.close stdout_w;
    Unix.close stderr_w;
    Unix.set_nonblock stdout_r;
    Unix.set_nonblock stderr_r;
    Unix.set_nonblock stdin_w;
    (pid, stdin_w, stdout_r, stderr_r)

let supervise ~pid ~stdin_w ~stdout_r ~stderr_r ~stdin_payload ~timeout_sec =
  let deadline = Unix.gettimeofday () +. timeout_sec in
  let payload_off = ref 0 in
  let payload_len = String.length stdin_payload in
  let stdin_open = ref (payload_len > 0) in
  if payload_len = 0 then Unix.close stdin_w;
  let out_open = ref true and err_open = ref true in
  let chan_eof = ref false in
  let out_dead = ref false and err_dead = ref false in
  let status = ref None in
  let timed_out = ref false in
  let kill_started = ref false in
  let kill_remaining = ref [] in
  let grace_until = ref None in
  let reaped_at = ref None in
  (* After the payload is reaped, pipes are drained until EOF, bounded by
     this grace so an escaped daemon (double-fork + setsid defeats pgid
     kills by design) holding the pipes open cannot hang the shim. *)
  let drain_grace_sec = 1.0 in
  let send_to_pgid sig_ =
    try Unix.kill (-pid) sig_ with
    | Unix.Unix_error _ -> () in
  (* Interpret the kill-policy decision list: signal actions run
     immediately, [Wait_grace] blocks further steps until it expires. *)
  let rec step_kill now =
    match !kill_remaining with
    | Sigterm_pgid :: tl ->
      send_to_pgid Sys.sigterm;
      kill_remaining := tl;
      step_kill now
    | Sigkill_pgid :: tl ->
      send_to_pgid Sys.sigkill;
      kill_remaining := tl;
      step_kill now
    | Wait_grace g :: _ ->
      (match !grace_until with
       | None -> grace_until := Some (now +. g)
       | Some t when now >= t ->
         grace_until := None;
         kill_remaining := List.tl !kill_remaining;
         step_kill now
       | Some _ -> ())
    | [] -> () in
  let start_kill trigger =
    if !status = None && not !kill_started
    then (
      kill_started := true;
      kill_remaining := kill_policy trigger;
      step_kill (Unix.gettimeofday ())) in
  let poll_child () =
    match !status with
    | Some _ -> ()
    | None ->
      (match Unix.waitpid [ Unix.WNOHANG ] pid with
       | 0, _ -> ()
       | _, st ->
         status := Some st;
         reaped_at := Some (Unix.gettimeofday ())) in
  (* Forward drained child output to our own stdout/stderr.  If the peer
     went away (EPIPE) keep draining so the child cannot block on a full
     pipe, drop the bytes, and apply the channel-EOF kill policy. *)
  let forward ~dst_dead dst_fd data =
    if data <> "" && not !dst_dead
    then
      try write_all dst_fd data 0 (String.length data) with
      | Unix.Unix_error (Unix.EPIPE, _, _) ->
        dst_dead := true;
        start_kill On_eof in
  (* Drain available bytes from [pipe_fd]; returns [false] on EOF (pipe
     closed here so the fd is never reused under us). *)
  let pump ~dst_dead pipe_fd dst_fd =
    let buf = Buffer.create 65536 in
    match drain_fd pipe_fd buf with
    | Drain_again -> true
    | Drain_bytes _ ->
      forward ~dst_dead dst_fd (Buffer.contents buf);
      true
    | Drain_eof ->
      Unix.close pipe_fd;
      false in
  while !status = None || !out_open || !err_open do
    let now = Unix.gettimeofday () in
    if !status = None && (not !kill_started) && now >= deadline
    then (
      (* Only attribute [timed_out] when the deadline is what started the
         kill; a deadline expiring during an in-flight EOF-cancel kill must
         not rewrite the cause. *)
      timed_out := true;
      start_kill On_timeout);
    step_kill now;
    poll_child ();
    (* Drain grace after reap: close any pipes an escaped daemon keeps
       open so the loop is guaranteed to terminate. *)
    (match !reaped_at with
     | Some t when now -. t > drain_grace_sec ->
       if !out_open
       then (
         (try Unix.close stdout_r with
          | Unix.Unix_error _ -> ());
         out_open := false);
       if !err_open
       then (
         (try Unix.close stderr_r with
          | Unix.Unix_error _ -> ());
         err_open := false)
     | _ -> ());
    let readfds =
      (if !out_open then [ stdout_r ] else [])
      @ (if !err_open then [ stderr_r ] else [])
      @ if !chan_eof then [] else [ Unix.stdin ] in
    let writefds = if !stdin_open then [ stdin_w ] else [] in
    let select_timeout =
      let quantum = 0.2 in
      (* Deadline counts only before it fires; after [timed_out] is set the
         past deadline must not clamp the sleep to 0 (busy spin). *)
      let t =
        match !status, !timed_out with
        | None, false -> min quantum (max 0.0 (deadline -. now))
        | _ -> quantum in
      match !grace_until with
      | Some g -> min t (max 0.0 (g -. now))
      | None -> t in
    let rec select_retry () =
      try Unix.select readfds writefds [] select_timeout with
      | Unix.Unix_error (Unix.EINTR, _, _) -> select_retry () in
    let (rdy_r, rdy_w, _) = select_retry () in
    if !out_open && List.memq stdout_r rdy_r
    then out_open := pump ~dst_dead:out_dead stdout_r Unix.stdout;
    if !err_open && List.memq stderr_r rdy_r
    then err_open := pump ~dst_dead:err_dead stderr_r Unix.stderr;
    if (not !chan_eof) && List.memq Unix.stdin rdy_r
    then (
      (* After the frame, stdin carries no more data; readability means
         either junk bytes (discarded) or EOF (channel closed = cancel). *)
      let junk = Bytes.create 4096 in
      match Unix.read Unix.stdin junk 0 (Bytes.length junk) with
      | 0 ->
        chan_eof := true;
        start_kill On_eof
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
    if !stdin_open && List.memq stdin_w rdy_w
    then (
      match
        Unix.write stdin_w
          (Bytes.unsafe_of_string stdin_payload)
          !payload_off (payload_len - !payload_off)
      with
      | n ->
        payload_off := !payload_off + n;
        if !payload_off >= payload_len
        then (
          Unix.close stdin_w;
          stdin_open := false)
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception Unix.Unix_error (Unix.EPIPE, _, _) ->
        (* Child is not reading stdin (already exited or closed it). *)
        (try Unix.close stdin_w with
         | Unix.Unix_error _ -> ());
        stdin_open := false);
    (* Once the child is reaped, keep draining opportunistically: pipes hit
       EOF only after every writer (including grandchildren) is gone. *)
    if !status <> None
    then (
      if !out_open then out_open := pump ~dst_dead:out_dead stdout_r Unix.stdout;
      if !err_open then err_open := pump ~dst_dead:err_dead stderr_r Unix.stderr)
  done;
  if !stdin_open
  then (try Unix.close stdin_w with
        | Unix.Unix_error _ -> ());
  let st = match !status with
    | Some st -> st
    | None ->
      (* Unreachable: the loop exits only after the child was reaped. *)
      snd (Unix.waitpid [] pid) in
  (* Reap leftover process-group members (grandchildren) per policy.  No
     liveness recheck between reap and this SIGKILL: the pgid could only
     have been recycled by a pid-space wraparound inside the drain window
     — negligible on Linux, acknowledged. *)
  List.iter
    (function
      | Sigterm_pgid -> send_to_pgid Sys.sigterm
      | Sigkill_pgid -> send_to_pgid Sys.sigkill
      | Wait_grace _ -> ())
    (kill_policy On_child_exit);
  trailer_of_status ~timed_out:!timed_out st

let emit_trailer_stderr (t : Exec_ssh_protocol.trailer) =
  let s = Exec_ssh_protocol.render_trailer t in
  try write_all Unix.stderr s 0 (String.length s) with
  | Unix.Unix_error (Unix.EPIPE, _, _) -> ()

let shim_fail msg =
  (* Trailer to our stderr, then exit 1: a shim failure must never be
     indistinguishable from a payload exit 0. *)
  emit_trailer_stderr
    Exec_ssh_protocol.{ v = protocol_version
                      ; exit = None
                      ; signal = None
                      ; timed_out = false
                      ; shim_error = Some msg };
  exit 1

(* The jail this one call runs in, decided from what the host allows and what
   the request asked for.

   Named and reachable rather than inline in [run]: the two checks it composes
   each had a passing unit test while the dispatcher still handed
   [check_cwd_jail] the config's root, so every endpoint but one read as an
   escape. A decision only reachable through stdin is a decision no test
   pins. *)
let jail_for_request ~(config : config) ~(request : Exec_ssh_protocol.request) =
  Result.bind
    (check_request_root_jail ~config_root:config.remote_root
       ~request_root:request.Exec_ssh_protocol.remote_root)
    (fun () ->
      check_cwd_jail ~root:request.Exec_ssh_protocol.remote_root
        ~cwd:request.Exec_ssh_protocol.cwd)
;;

let run () =
  match read_frame Unix.stdin with
  | Error e -> shim_fail e
  | Ok (req, stdin_payload) ->
    (match load_config () with
     | Error e -> shim_fail e
     | Ok config ->
       (match jail_for_request ~config ~request:req with
        | Error e -> shim_fail e
        | Ok () ->
          (match req.Exec_ssh_protocol.argv with
           | [] -> shim_fail (shim_error_code ^ ": empty argv")
           | argv ->
             let cwd = Unix.realpath req.Exec_ssh_protocol.cwd in
             let env =
               synthesize_env ~base_env:(env_of_process ())
                 ~allowlist:config.env_allowlist
                 ~request_env:req.Exec_ssh_protocol.env in
             let (pid, stdin_w, stdout_r, stderr_r) =
               try spawn ~argv ~env ~cwd with
               | exn ->
                 shim_fail
                   (Printf.sprintf "%s: spawn failed: %s" shim_error_code
                      (Printexc.to_string exn)) in
             let trailer =
               supervise ~pid ~stdin_w ~stdout_r ~stderr_r ~stdin_payload
                 ~timeout_sec:req.Exec_ssh_protocol.timeout_sec in
             emit_trailer_stderr trailer;
             exit 0)))

let probe =
  Exec_ssh_protocol.
    { name = "masc-exec-shim"
    ; version = Printf.sprintf "%d.0.0" protocol_version
    ; capabilities = []
    }

let main () =
  (* OCaml does NOT ignore SIGPIPE by default; an undelivered SIGPIPE would
     kill the shim outright (signal 13) where the code expects EPIPE
     exceptions — the ssh channel going away mid-stream is a cancel path,
     handled via the On_eof kill policy.  Ignore it here; the payload child
     re-arms the default disposition pre-exec. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  match Array.to_list Sys.argv with
  | [ _; "--probe" ] -> print_endline (Exec_ssh_protocol.render_probe probe)
  | [ _ ] -> run ()
  | _ ->
    prerr_endline "usage: masc-exec-shim [--probe]";
    exit 2
