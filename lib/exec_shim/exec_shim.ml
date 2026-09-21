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

(* The box (RFC-0422). [observe_support_abi] is the Landlock ABI the kernel
   enforces, 0 where the shim cannot box a payload (no Landlock, no seccomp,
   or not Linux). [restrict_self scratch deny_fs deny_net] is applied in the
   child right before exec; see observe_stub.c for what each flag denies. *)
external observe_support_abi : unit -> int = "ocaml_shim_observe_support"
external restrict_self : string -> bool -> bool -> bytes -> int
  = "ocaml_shim_restrict_self"

let observe_supported () = observe_support_abi () >= 1

(* Capability probe only (task-1568, PR #36032 review 5192723206): whether
   this kernel would accept SECCOMP_FILTER_FLAG_NEW_LISTENER at all.
   [probe] below reports it as a capability (review 5195604213's lesson:
   an unreferenced surface in this lineage gets rejected as dead code, so
   this is read on the wire from its first commit rather than left
   declared-only). [deny_sockets] itself still answers socket(2) with
   EPERM straight from the filter, and [decide_after_observation] still
   defers every [Observed_refused] to the judge regardless of what this
   reports — advertising a capability is not a policy the gate reads.
   Acting on it needs a listener fd carried from the child to the parent
   (a plain pipe cannot carry a file descriptor: a new SCM_RIGHTS stub)
   and a supervisor loop that reads/decodes/responds to notifications —
   deferred to the PR that adds that loop. *)
external user_notif_supported : unit -> bool = "ocaml_shim_user_notif_supported"

(* task-1575 (phase 3, observe drain wiring). The fd passing primitive is
   shim_fdpass; install_observe_sockets does the seccomp side from the
   child and sends the listener fd over [sock].  [drain_one] is the parent
   side: receive one notification, answer EPERM, and return the recorded
   syscall number as the wired surface — distinct from the N/W ack
   because it answers "what did the payload try?" not "did the box
   apply?". *)
external observe_install : Unix.file_descr -> bool = "ocaml_shim_observe_install"
external drain_one : Unix.file_descr -> int = "ocaml_shim_user_notif_drain_one"

let observe_unsupported_code = "observe_unsupported"
let observe_scratch_code = "observe_scratch_error"

let jail_error_code = "remote_ssh_path_jail_violation"
let config_error_code = "remote_ssh_shim_config_error"
let shim_error_code = "remote_ssh_shim_error"

(* {1 Environment synthesis} *)

let default_base_path = "/usr/local/bin:/usr/bin:/bin"
let default_payload_path = String.split_on_char ':' default_base_path

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

(* What the endpoint's operator declares every payload runs with ([env_file=]):
   the environment a person logged in on that host has and a fixed PATH plus
   HOME/USER/TMPDIR does not -- a venv's VIRTUAL_ENV, a CUDA LD_LIBRARY_PATH,
   the address of a service the host runs. The denylist is not applied here.
   It keeps the wire away from the loader and the lookup; this file is
   endpoint-resident, the operator's statement like [path=]. PATH is the one
   name refused, because [path=] is also the list [resolve_program] searches,
   and a second PATH would put the payload's PATH and that search out of
   step. *)
type endpoint_env = (string * string) list

let no_endpoint_env = []

let env_name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _ -> false

let is_env_name name =
  name <> ""
  && (match name.[0] with '0' .. '9' -> false | _ -> true)
  && String.for_all env_name_char name

(* docker's --env-file grammar without its host-lookup form: NAME=VALUE, the
   value is the rest of the line byte for byte, blank lines and lines whose
   first non-blank character is '#' are skipped. docker reads lines with
   bufio.ScanLines, which drops one '\r' before the line end, so a file saved
   with CRLF endings means the same values here. A line holding only a name
   would take the value from the reading process, which here is an sshd
   session's -- not something the operator wrote -- so it is refused.

   An error names the file and the line number and says what is wrong, never
   the line's text: a malformed line may be a secret value. *)
let parse_env_file ~path content =
  let err n fmt =
    Printf.ksprintf
      (fun m ->
        Error (Printf.sprintf "%s: env_file %s line %d: %s" config_error_code path n m))
      fmt in
  let first_line_of_name = Hashtbl.create 16 in
  let declare declared (n, line) =
    Result.bind declared (fun declared ->
        let line =
          if String.ends_with ~suffix:"\r" line
          then String.sub line 0 (String.length line - 1)
          else line in
        let body = String.trim line in
        if body = "" || body.[0] = '#'
        then Ok declared
        else
          match String.index_opt line '=' with
          | None -> err n "not NAME=VALUE"
          | Some i ->
            let name = String.sub line 0 i in
            let value = String.sub line (i + 1) (String.length line - i - 1) in
            if not (is_env_name name)
            then err n "the text before '=' is not an environment variable name"
            else if name = "PATH"
            then err n "PATH comes from path=, the directories programs are looked up in"
            else if List.mem name Exec_ssh_protocol.github_token_env_names
            then
              err n "%s would make every keeper on this endpoint one GitHub identity; \
                     each keeper's own login is its GH_CONFIG_DIR" name
            else if List.mem name runtime_env_allowlist
            then err n "%s is set by the masc runner for each request" name
            else if String.contains value '\000'
            then err n "the value holds a NUL byte, which exec cannot pass"
            else
              match Hashtbl.find_opt first_line_of_name name with
              | Some first -> err n "a name is declared twice, on lines %d and %d" first n
              | None ->
                Hashtbl.add first_line_of_name name n;
                Ok ((name, value) :: declared)) in
  List.fold_left declare (Ok no_endpoint_env)
    (List.mapi (fun i line -> (i + 1, line)) (String.split_on_char '\n' content))

let synthesize_env ~path ~endpoint_env ~base_env ~allowlist ~request_env =
  let shim_env = base_env in
  let lookup key default =
    match List.assoc_opt key shim_env with
    | Some v -> v
    | None -> default in
  let base = [ ("PATH", path)
             ; ("HOME", lookup "HOME" "/tmp")
             ; ("USER", lookup "USER" "masc")
             ; ("TMPDIR", lookup "TMPDIR" "/tmp") ] in
  let set env (k, v) = (k, v) :: List.remove_assoc k env in
  let upsert env (k, v) =
    if (List.mem k runtime_env_allowlist || List.mem k allowlist)
       && not (denylisted_env_name k)
    then set env (k, v)
    else env in
  List.fold_left upsert (List.fold_left set base endpoint_env) request_env

(* {1 Program lookup} *)

(* Unix.execvpe searches the PATH of the calling process, not the PATH in the
   environment it is handed (measured on OCaml 5.5 with glibc, musl and macOS
   libc: a program only in the given env PATH fails with ENOENT). The shim's
   own PATH is whatever started it -- an sshd session's -- so [path=] reached
   the payload's environment but never the lookup of the program the request
   names. The lookup is done here against the payload path instead, and the
   program handed to execvpe carries a slash, which makes libc exec it without
   searching. *)
let is_executable_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (try
       Unix.access path [ Unix.X_OK ];
       true
     with
     | Unix.Unix_error _ -> false)
  | _ -> false
  | exception Unix.Unix_error _ -> false

let resolve_program ~payload_path ~is_executable name =
  if String.contains name '/'
  then Some name
  else
    List.find_map
      (fun dir ->
        let candidate = Filename.concat dir name in
        if is_executable candidate then Some candidate else None)
      payload_path

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

(* [v] is the request's own major, echoed: a v2 server reads a v2 trailer,
   and a v3 one a v3, so the shim never answers in a version its caller did
   not speak to it in. *)
let trailer_of_status ?(observed_syscalls = []) ~v ~timed_out status
  : Exec_ssh_protocol.trailer =
  match status with
  | Unix.WEXITED n ->
    Exec_ssh_protocol.{ v
                      ; exit = Some n
                      ; signal = None
                      ; timed_out
                      ; shim_error = None
                      ; observed_syscalls }
  | Unix.WSIGNALED n | Unix.WSTOPPED n ->
    (* WSTOPPED is unreachable (waitpid without WUNTRACED); map it like
       WSIGNALED defensively rather than fabricating an exit code.  The
       trailer carries the host OS signal number, not OCaml's abstract
       code. *)
    Exec_ssh_protocol.{ v
                      ; exit = None
                      ; signal = Some (host_signal_number n)
                      ; timed_out
                      ; shim_error = None
                      ; observed_syscalls }

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
  ; payload_path : string list
  ; env_file : string option
  ; scratch_root : string
  }

let config_env_var = Exec_ssh_protocol.shim_config_env_var
let default_config_path = "/etc/masc-exec-shim.conf"

let config_keys = [ "remote_root"; "env_allowlist"; "path"; "env_file"; "scratch_root" ]

(* An error names the key or the line number and says what is wrong, never
   text from the file: a line or a value in the wrong place may be a secret.
   The one key an error prints is a known one, a fixed name. *)
let parse_config content =
  let ( let* ) = Result.bind in
  let err fmt = Printf.ksprintf (fun m -> Error (config_error_code ^ ": " ^ m)) fmt in
  let absolute_path key = function
    | "" -> err "%s must not be empty" key
    | value when not (String.starts_with ~prefix:"/" value) ->
      err "%s must be an absolute path" key
    | value -> Ok value in
  (* [path] replaces the payload PATH outright, so every entry has to stand
     on its own: an empty entry would be the current directory to execvp,
     and a relative one would resolve against the payload cwd -- the jail's
     inside. Both are the kind of lookup the fixed default exists to rule
     out. The config is endpoint-resident, so this is the endpoint operator's
     statement, never the wire's. *)
  let payload_path_of value =
    match String.split_on_char ':' value with
    | [] | [ "" ] -> err "path must name at least one directory"
    | entries ->
      (match List.find_opt (fun entry -> not (String.starts_with ~prefix:"/" entry)) entries with
       | Some "" -> err "path has an empty entry"
       | Some _ -> err "path entries must be absolute"
       | None -> Ok entries) in
  (* A key is judged on its own line, so an unknown one is reported by that
     line's number and a duplicate is always a known key. *)
  let parse_line n line acc =
    let line = String.trim line in
    if line = "" || String.starts_with ~prefix:"#" line
    then Ok acc
    else
      match String.index_opt line '=' with
      | None -> err "line %d is not key=value" (n + 1)
      | Some i ->
        let key = String.trim (String.sub line 0 i) in
        let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
        if not (List.mem key config_keys)
        then err "line %d has an unknown key" (n + 1)
        else if List.mem_assoc key acc
        then err "duplicate key %S (line %d)" key (n + 1)
        else Ok ((key, value) :: acc) in
  let* entries =
    List.fold_left
      (fun acc (n, line) -> Result.bind acc (parse_line n line))
      (Ok [])
      (List.mapi (fun i l -> (i, l)) (String.split_on_char '\n' content)) in
  let* remote_root =
    match List.assoc_opt "remote_root" entries with
    | None -> err "missing required key \"remote_root\""
    | Some root -> absolute_path "remote_root" root in
  let env_allowlist =
    match List.assoc_opt "env_allowlist" entries with
    | None -> []
    | Some v ->
      String.split_on_char ',' v
      |> List.map String.trim
      |> List.filter (fun s -> s <> "") in
  let* payload_path =
    match List.assoc_opt "path" entries with
    | None -> Ok default_payload_path
    | Some value -> payload_path_of value in
  let* env_file =
    match List.assoc_opt "env_file" entries with
    | None -> Ok None
    | Some file -> Result.map Option.some (absolute_path "env_file" file) in
  let* scratch_root =
    match List.assoc_opt "scratch_root" entries with
    | None -> Ok Exec_ssh_protocol.default_scratch_root
    | Some root -> absolute_path "scratch_root" root in
  Ok { remote_root; env_allowlist; payload_path; env_file; scratch_root }

(* Read here rather than through Env_config_core: the shim is a standalone
   binary deployed to the remote host, where masc's config layer does not
   exist. Its dune stanza names exec_ssh_protocol and unix and nothing else,
   and pulling the config library across would ship that whole layer to every
   exec host. The env-read ratchet counts this site for that reason. *)
let config_path () =
  match Sys.getenv_opt config_env_var with
  | Some p when p <> "" -> p
  | _ -> default_config_path

let root_uid = 0
let group_write_bit = 0o020
let other_write_bit = 0o002

type endpoint_file_writers =
  | Its_group
  | Every_user
  | Its_group_and_every_user

type endpoint_file_refusal =
  | Owned_by of int
  | Writable_by of endpoint_file_writers

(* Whoever can write the config names the payload PATH and the env file, and
   whoever can write the env file sets the environment of every payload on the
   host, the loader path included. The rule for both is sshd's StrictModes for
   an authorized_keys file: owned by root or by the account reading it, and
   written by no one else. The shim's own account is accepted, but it is also
   the account that runs the payloads, and a payload can rewrite a file its
   account owns; a root-owned 0644 file is the one a payload cannot change. *)
let refuse_endpoint_file ~euid ~owner ~perm =
  if owner <> root_uid && owner <> euid
  then Some (Owned_by owner)
  else
    match perm land group_write_bit <> 0, perm land other_write_bit <> 0 with
    | false, false -> None
    | true, false -> Some (Writable_by Its_group)
    | false, true -> Some (Writable_by Every_user)
    | true, true -> Some (Writable_by Its_group_and_every_user)

let endpoint_file_writers_text = function
  | Its_group -> "its group"
  | Every_user -> "every user"
  | Its_group_and_every_user -> "its group and every user"

(* Only a regular file is read, and whether the path is one is decided before a
   byte is read. The open is nonblocking, so a FIFO nobody writes to does not
   hang it; the kind then comes from the descriptor, and a FIFO, a device or a
   directory is refused. The owner and mode are judged from the same metadata,
   also before the read, so a refused file is never read. Metadata and bytes
   come from one descriptor, so the verdict is about the same file as the
   content even when the path is replaced in between. The bytes are read to end
   of file rather than to a length taken first, which a file still being written
   would make stale. Until the channel exists the descriptor is closed directly;
   once it exists the channel owns the descriptor and [close_in_noerr] is its
   only close, as Unix.in_channel_of_descr asks. *)
let read_endpoint_file ~what path =
  let cannot_read () =
    Error (Printf.sprintf "%s: cannot read %s %s" config_error_code what path) in
  let close_descriptor fd = try Unix.close fd with Unix.Unix_error _ -> () in
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error _ -> cannot_read ()
  | fd ->
    let euid = Unix.geteuid () in
    let verdict =
      match Unix.fstat fd with
      | exception Unix.Unix_error _ -> cannot_read ()
      | { Unix.st_kind = Unix.S_REG; st_uid; st_perm; _ } ->
        (match refuse_endpoint_file ~euid ~owner:st_uid ~perm:st_perm with
         | None -> Ok ()
         | Some (Owned_by owner) ->
           Error
             (Printf.sprintf
                "%s: %s %s is owned by uid %d; only root or the shim's own uid (%d) \
                 may own it"
                config_error_code what path owner euid)
         | Some (Writable_by writers) ->
           Error
             (Printf.sprintf
                "%s: %s %s is writable by %s (mode %04o); only its owner may write it"
                config_error_code what path (endpoint_file_writers_text writers) st_perm))
      (* [openfile] follows a symbolic link, so [fstat] never reports [S_LNK];
         the kind is listed so the match stays exhaustive. *)
      | { Unix.st_kind =
            ( Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
            | Unix.S_SOCK )
        ; _
        } ->
        Error (Printf.sprintf "%s: %s %s is not a regular file" config_error_code what path)
    in
    match verdict with
    | Error _ as refused ->
      close_descriptor fd;
      refused
    | Ok () ->
      (match
         Unix.clear_nonblock fd;
         Unix.in_channel_of_descr fd
       with
       | exception Unix.Unix_error _ ->
         close_descriptor fd;
         cannot_read ()
       | channel ->
         Fun.protect
           ~finally:(fun () -> close_in_noerr channel)
           (fun () ->
             match In_channel.input_all channel with
             | content -> Ok content
             | exception Sys_error _ -> cannot_read ()))

let read_config_file path =
  Result.bind (read_endpoint_file ~what:"config file" path) parse_config

let load_config () = read_config_file (config_path ())

let read_env_file = function
  | None -> Ok no_endpoint_env
  | Some path ->
    Result.bind (read_endpoint_file ~what:"env_file" path) (parse_env_file ~path)

(* Named and reachable for the same reason as [jail_for_request]: the config
   naming an env file, reading it and layering it under the wire are three
   steps, and a composition only reachable through stdin is one no test pins. *)
let payload_env ~(config : config) ~base_env ~request_env =
  Result.map
    (fun endpoint_env ->
      synthesize_env
        ~path:(String.concat ":" config.payload_path)
        ~endpoint_env ~base_env ~allowlist:config.env_allowlist ~request_env)
    (read_env_file config.env_file)

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

(* {1 Execution plan (RFC-0422)} *)

type execution_plan =
  | Run_effect
  | Run_boxed of
      { deny_fs : bool
      ; deny_net : bool
      }
  | Refuse_observe_unsupported

(* Decided from the request's mode and this kernel's answer, and nowhere
   else: a box the kernel cannot build is a refusal, never a quiet fall
   back to running unboxed. *)
let plan_for_mode ~supported = function
  | Exec_ssh_protocol.Effect -> Run_effect
  | Exec_ssh_protocol.Observe ->
    if supported then Run_boxed { deny_fs = true; deny_net = true }
    else Refuse_observe_unsupported
  | Exec_ssh_protocol.Guest_local ->
    if supported then Run_boxed { deny_fs = false; deny_net = true }
    else Refuse_observe_unsupported

(* One directory per boxed run, the only place a boxed payload may write.
   It is also the payload's HOME and TMPDIR so tools that cache (gh) or
   need a temp file find somewhere that exists; it is removed after the
   run, so nothing written there outlives the call. *)
let make_scratch ~root =
  let name =
    Printf.sprintf "masc-observe-%d-%08x" (Unix.getpid ())
      (Random.State.bits (Random.State.make_self_init ()) land 0xffffffff) in
  let path = Filename.concat root name in
  match Unix.mkdir path 0o700 with
  | () -> Ok path
  | exception Unix.Unix_error (code, call, arg) ->
    Error
      (Printf.sprintf "%s: cannot create scratch under %s: %s(%s): %s"
         observe_scratch_code root call arg (Unix.error_message code))

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

(* RFC-0422 diagnosis: one line per request on the guest's tmpfs, so the
   mode a request was framed with and the plan it actually got are readable
   from the host after the fact. Best-effort by construction -- a trace that
   could fail a dispatch would measure the trace, not the box. Capped so a
   guest whose tmpfs hosts the trace can never be filled by it. *)
let request_trace_path = "/tmp/masc-shim-requests.log"

let request_trace_byte_cap = 4 * 1024 * 1024

let trace_request ~mode ~plan argv =
  try
    (* An absent trace has size zero, not an exception -- otherwise the
       guard would swallow the very first write. *)
    let size =
      match Unix.stat request_trace_path with
      | { Unix.st_size; _ } -> st_size
      | exception Unix.Unix_error _ -> 0
    in
    if size <= request_trace_byte_cap then begin
      let fd =
        Unix.openfile request_trace_path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
          0o644
      in
      let line =
        Printf.sprintf "%d v=%s mode=%s plan=%s argv0=%s\n"
          (int_of_float (Unix.time ()))
          (string_of_int Exec_ssh_protocol.protocol_version ^ Shim_build_id.suffix)
          (Exec_ssh_protocol.mode_to_string mode) plan
          (match argv with arg0 :: _ -> arg0 | [] -> "-")
      in
      (* fire-and-forget: a short write only shortens one trace line *)
      ignore (Unix.write_substring fd line 0 (String.length line));
      Unix.close fd
    end
  with Unix.Unix_error _ -> ()
;;

let scratch_env ~scratch env =
  let upsert (k, v) env = (k, v) :: List.remove_assoc k env in
  env |> upsert ("HOME", scratch) |> upsert ("TMPDIR", scratch)

(* Setup can be refused by one of the child's own two rules. The
   acknowledgement channel is typed, so the refusal crosses as its rule's
   name, not as prose the parent would have to re-read out of stderr. *)
exception Sandbox_refused_socket
exception Sandbox_refused_write

(* The C stub writes the rule name into a fixed 8-byte buffer and leaves the
   rest zeroed, so the raw bytes are never equal to the bare tag. Trim the
   NUL padding by content -- a hardcoded length is exactly how the "N"/"W"
   path went dead once (review 5192723206). Pure, so the emission mapping is
   testable without a real seccomp/Landlock refusal. *)
let refusal_of_rule_bytes (rule : bytes) =
  let n = Bytes.length rule in
  let rec last_non_nul i =
    if i < 0 then 0
    else if Bytes.get rule i = '\000' then last_non_nul (i - 1)
    else i + 1
  in
  match Bytes.sub_string rule 0 (last_non_nul (n - 1)) with
  | "socket" -> Sandbox_refused_socket
  | "write" -> Sandbox_refused_write
  | padded -> failwith ("box setup refused by unknown rule: " ^ padded)
;;

let spawn ?(before_exec = fun () -> ()) ?observe_sock
    ~program ~argv ~env ~cwd ()
  =
  let opened = ref [] in
  let pipe ?(cloexec = false) () =
    match Unix.pipe ~cloexec () with
    | (read_fd, write_fd) as pair ->
      opened := read_fd :: write_fd :: !opened;
      pair
    | exception exn -> List.iter Unix.close !opened; raise exn
  in
  let (stdin_r, stdin_w) = pipe () in
  let (stdout_r, stdout_w) = pipe () in
  let (stderr_r, stderr_w) = pipe () in
  let (boundary_r, boundary_w) = pipe ~cloexec:true () in
  match Unix.fork () with
  | exception exn -> List.iter Unix.close !opened; raise exn
  | 0 ->
    (* Child: own session + process group (pgid = pid), pdeathsig set
       pre-exec, pipes wired to 0/1/2, then exec.  Any failure is reported
       on the child's stderr (which the parent streams) and exits 127. *)
    Unix.close boundary_r;
    let sandbox_applied = ref false in
    let acknowledge byte =
      try write_all boundary_w byte 0 1 with Unix.Unix_error _ -> ()
    in
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
       (* The box goes on last, after every path the shim itself needs is
          resolved, and before the payload has run one instruction. *)
       before_exec ();
       (* task-1575 phase 3: install the observe filter and hand the
          listener fd to the parent over the socketpair's child end. The
          filter must be installed here (after prctl, before execvpe), so
          the listener fd is valid for the whole lifetime of the payload.
          The child's copy of the parent's end is closed first: a
          socketpair has two ends, one per side, and a child that kept
          both would be sending itself a message nobody reads (verified:
          this was exactly the earlier bug -- both sides using the same
          fd meant the parent's [recv_fd] blocked forever on a message
          the child never actually delivered to it). *)
       (match observe_sock with
        | Some (child_end, parent_end) ->
          (try Unix.close parent_end with
           | Unix.Unix_error _ -> ());
          let installed = observe_install child_end in
          Unix.close child_end;
          if not installed then exit 127
        | None -> ());
       (* This private pipe carries at most two bytes and never payload text.
          Only the child can acknowledge applied restrictions. The write end
          closes on exec; no acknowledgement is not evidence of success. *)
       acknowledge "A";
       sandbox_applied := true;
       (* [program] is argv's program resolved against the payload path
          (resolve_program); none found reads as the ENOENT execvpe reported
          before, through the same exit-127 path below. *)
       let program =
         match program with
         | Some path -> path
         | None -> raise (Unix.Unix_error (Unix.ENOENT, "execvpe", List.hd argv))
       in
       Unix.execvpe program (Array.of_list argv)
         (Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) env))
     with
     | Sandbox_refused_socket ->
       acknowledge "N";
       Unix.close boundary_w;
       exit 127
     | Sandbox_refused_write ->
       acknowledge "W";
       Unix.close boundary_w;
       exit 127
     | exn ->
       acknowledge (if !sandbox_applied then "E" else "S");
       Unix.close boundary_w;
       (try
          output_string stderr
            ("masc-exec-shim: " ^ Printexc.to_string exn ^ "\n");
          flush stderr
        with
        (* output_string and flush raise Sys_error; this is not a catch-all, so
           anything else -- including an exception this library cannot name --
           leaves untouched. *)
        | Sys_error _ -> ());
       exit 127)
  | pid ->
    let prepared = ref false in
    Fun.protect
      ~finally:(fun () ->
        if not !prepared then
          (* fork succeeded, so descriptor preparation failure is not proof
             the child refused to run. Reap before dropping its handles. *)
          Fun.protect
            ~finally:(fun () ->
              List.iter
                (fun fd -> try Unix.close fd with
                  | Unix.Unix_error (Unix.EBADF, _, _) -> ())
                !opened)
            (fun () ->
              let kill target =
                try Unix.kill target Sys.sigkill with
                | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
              in
              kill (-pid);
              kill pid;
              let rec reap () =
                match Unix.waitpid [] pid with
                | _ -> ()
                | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
              in
              reap ()))
      (fun () ->
        Unix.close boundary_w;
        Unix.close stdin_r;
        Unix.close stdout_w;
        Unix.close stderr_w;
        Unix.set_nonblock stdout_r;
        Unix.set_nonblock stderr_r;
        Unix.set_nonblock stdin_w;
        Unix.set_nonblock boundary_r;
        (* task-1575: receive the listener fd the child just sent over the
           socketpair's parent end. [None] is "observe mode was not
           requested". The parent's own copy of the child's end is closed
           first -- keeping it open would not corrupt this single
           exchange, but it would leave an extra live reference on the
           end the child uses, and a fd this process has no business
           holding once the handoff is done. The fd is non-blocking so
           the supervise select loop can treat readable == one available
           notification. *)
        let listener_fd =
          match observe_sock with
          | None -> Unix.stdin
          | Some (child_end, parent_end) ->
            (try Unix.close child_end with
             | Unix.Unix_error _ -> ());
            let fd = Shim_fdpass.recv_fd parent_end in
            Unix.close parent_end;
            Unix.set_nonblock fd;
            fd
        in
        let handles =
          (pid, stdin_w, stdout_r, stderr_r, boundary_r, listener_fd)
        in
        prepared := true;
        handles)

let child_boundary_of_ack = function
  | "A" -> Exec_ssh_protocol.Sandbox_applied
  | "AE" -> Exec_failed
  | "S" -> Setup_failed
  (* "N"/"W" are the child attributing a setup refusal to its own rule:
     "N" is the seccomp socket filter, "W" the Landlock write ruleset. The
     child knows this from the syscall that failed, never from anything
     the payload printed. *)
  | "N" -> Exec_ssh_protocol.Refused_socket
  | "W" -> Exec_ssh_protocol.Refused_write
  | _ -> Child_ack_unavailable

let read_child_boundary fd =
  let bytes = Bytes.create 3 in
  let rec read count =
    if count = Bytes.length bytes then count
    else
      match Unix.read fd bytes count (Bytes.length bytes - count) with
      | 0 -> count
      | n -> read (count + n)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> read count
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> count
  in
  child_boundary_of_ack (Bytes.sub_string bytes 0 (read 0))

(* Every instant in this loop is an interval's endpoint -- the timeout, the
   SIGKILL grace, the post-reap drain -- and none is reported as a time. So
   they are read off a clock no correction moves; see [Shim_clock]. *)
let supervise ~v ~pid ~stdin_w ~stdout_r ~stderr_r ~stdin_payload
    ~listener_fd ~timeout_sec =
  let observe_active = ref (listener_fd <> Unix.stdin) in
  let observed = ref [] in
  let deadline = Shim_clock.elapsed_seconds () +. timeout_sec in
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
      step_kill (Shim_clock.elapsed_seconds ())) in
  let poll_child () =
    match !status with
    | Some _ -> ()
    | None ->
      (match Unix.waitpid [ Unix.WNOHANG ] pid with
       | 0, _ -> ()
       | _, st ->
         status := Some st;
         reaped_at := Some (Shim_clock.elapsed_seconds ())) in
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
    let now = Shim_clock.elapsed_seconds () in
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
      @ (if !observe_active then [ listener_fd ] else [])
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
    (* task-1575 phase 3: drain every pending notification, reply EPERM,
       record the syscall number. Loop on EAGAIN — the listener is
       non-blocking so readable could mean one or more. Stop on ENOTCONN /
       EBADF (peer closed = child exited) or when the C-side send fails:
       the reviewer's concern about draining beyond [seen > 64] in the old
       loop is addressed by reading until the queue is empty, not by a
       magic ceiling. *)
    if !observe_active && List.memq listener_fd rdy_r
    then (
      let rec drain_loop () =
        match drain_one listener_fd with
        | -2 ->
          (* Queue empty (EAGAIN): the listener is non-blocking, so this is
             the normal end of a drain burst. Keep observing — the select
             loop calls back when the next notification arrives. *)
          ()
        | -1 ->
          (* RECV failed with ENOTCONN/EBADF (child gone) or SEND failed
             (payload side broken). Stop observing and release the fd. *)
          (observe_active := false;
           Unix.close listener_fd)
        | syscall_no ->
          (observed := syscall_no :: !observed;
           drain_loop ())
      in
      drain_loop ()
    );
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
  (* task-1575 phase 3: the observed-attempts accumulator rides in the
     trailer's own [observed_syscalls] field -- a type distinct from the
     exit/signal/shim_error ack, not a side-channel stderr text line (the
     shape a completion verdict rejected: vrf-75b5116cabdef13de98a595b19a8295d). *)
  trailer_of_status ~v ~timed_out:!timed_out ~observed_syscalls:(List.rev !observed) st

let emit_trailer_stderr ?execution_receipt (t : Exec_ssh_protocol.trailer) =
  let s = Exec_ssh_protocol.render_trailer ?execution_receipt t in
  try write_all Unix.stderr s 0 (String.length s) with
  | Unix.Unix_error (Unix.EPIPE, _, _) -> ()

(* [v] is the request's major once a request has been read; before that --
   a frame that did not decode -- there is no caller version to echo, and
   the newest one this build speaks is the only honest answer. *)
let shim_fail ?(v = Exec_ssh_protocol.newest) ?execution_receipt msg =
  (* Trailer to our stderr, then exit 1: a shim failure must never be
     indistinguishable from a payload exit 0. *)
  emit_trailer_stderr ?execution_receipt
    Exec_ssh_protocol.{ v
                      ; exit = None
                      ; signal = None
                      ; timed_out = false
                      ; shim_error = Some msg
                      ; observed_syscalls = [] };
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
    let v = req.Exec_ssh_protocol.v in
    let receipt boundary : Exec_ssh_protocol.execution_receipt =
      { mode = req.Exec_ssh_protocol.mode; boundary }
    in
    let shim_fail ?(boundary = Exec_ssh_protocol.Refused) msg =
      shim_fail ~v ~execution_receipt:(receipt boundary) msg
    in
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
               match
                 payload_env ~config ~base_env:(env_of_process ())
                   ~request_env:req.Exec_ssh_protocol.env
               with
               | Ok env -> env
               | Error e -> shim_fail e in
             (* task-1575: whether this run's socket(2) will be observed via
                the SECCOMP_FILTER_FLAG_NEW_LISTENER filter installed below.
                Two seccomp filters on the same syscall do not layer: the
                kernel takes the highest-priority action among all matching
                filters, and SECCOMP_RET_ERRNO outranks SECCOMP_RET_USER_NOTIF
                (verified empirically -- installing both, the static ERRNO
                filter's EPERM always wins and the listener never sees a
                notification). So when the observe filter is going to own
                socket(2), the static deny_sockets() filter below must not
                also claim it -- deny_net here would silently make the
                observe path permanently inert. *)
             let observe_notif_active =
               match req.Exec_ssh_protocol.mode with
               | Exec_ssh_protocol.Observe -> user_notif_supported ()
               | Exec_ssh_protocol.Effect | Exec_ssh_protocol.Guest_local -> false
             in
             let box =
               match
                 plan_for_mode ~supported:(observe_supported ())
                   req.Exec_ssh_protocol.mode
               with
               | Refuse_observe_unsupported ->
                 trace_request
                   ~mode:req.Exec_ssh_protocol.mode
                   ~plan:"refused_unsupported"
                   argv;
                 shim_fail
                   (Printf.sprintf
                      "%s: this host cannot box a payload (Landlock ABI %d); \
                       the request asked for %s"
                      observe_unsupported_code (observe_support_abi ())
                      (Exec_ssh_protocol.mode_to_string req.Exec_ssh_protocol.mode))
               | Run_effect ->
                 trace_request ~mode:req.Exec_ssh_protocol.mode ~plan:"effect" argv;
                 None
               | Run_boxed { deny_fs; deny_net } ->
                 trace_request ~mode:req.Exec_ssh_protocol.mode ~plan:"boxed" argv;
                 let scratch =
                   match make_scratch ~root:config.scratch_root with
                   | Ok path -> path
                   | Error message -> shim_fail message in
                 let deny_net = deny_net && not observe_notif_active in
                 Some (deny_fs, deny_net, scratch) in
             let env, before_exec, cleanup =
               match box with
               | None -> env, (fun () -> ()), (fun () -> ())
               | Some (deny_fs, deny_net, scratch) ->
                 let refusing_rule = Bytes.make 8 '\000' in
                 ( scratch_env ~scratch env
                 , (fun () ->
                       (* The child knows which of its own rules refused
                          from the syscall that failed -- the parent never
                          guesses it back out of stderr. The name crosses
                          the boundary pipe as the acknowledgement byte's
                          companion: "R" + rule. [refusal_of_rule_bytes]
                          trims the NUL padding by content; the mapping is
                          pure so the emission path is testable without a
                          real seccomp/Landlock refusal. *)
                       if restrict_self scratch deny_fs deny_net refusing_rule = 0
                       then ()
                       else raise (refusal_of_rule_bytes refusing_rule))
                 , (fun () -> remove_tree scratch) ) in
             let (pid, stdin_w, stdout_r, stderr_r, boundary_r, listener_fd) =
               (* A socketpair has two ends; [spawn] uses one in the child
                  (to hand the listener fd over) and the other in the
                  parent (to receive it) -- passing the same end to both
                  would have the parent waiting on a message the child
                  never actually delivers to that end (verified: this was
                  the shape of the earlier bug, and it hung every Observe
                  request, not only ones that reached the drain loop). *)
               let observe_sock =
                 if observe_notif_active
                 then (
                   try Some (Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0)
                   with Unix.Unix_error _ -> None)
                 else None
               in
               let program =
                 resolve_program ~payload_path:config.payload_path
                   ~is_executable:is_executable_file (List.hd argv)
               in
               try spawn ~before_exec ?observe_sock ~program ~argv ~env ~cwd () with
               (* In the parent, spawn runs Unix.pipe, Unix.fork and fd closes;
                  before_exec is invoked in the child after the fork. So Unix_error
                  is what this body raises, and enumerating it rather than catching
                  everything is what lets an exception this library cannot name --
                  exec_shim links no eio -- leave untouched. *)
               | Unix.Unix_error _ as exn ->
                 (match observe_sock with
                  | Some (child_end, parent_end) ->
                    (try Unix.close child_end with
                     | Unix.Unix_error _ -> ());
                    (try Unix.close parent_end with
                     | Unix.Unix_error _ -> ())
                  | None -> ());
                 cleanup ();
                 shim_fail ~boundary:Child_ack_unavailable
                   (Printf.sprintf "%s: spawn failed: %s" shim_error_code
                      (Printexc.to_string exn)) in
             let trailer, boundary =
               Fun.protect
                 ~finally:(fun () ->
                   Unix.close boundary_r;
                   (if listener_fd <> Unix.stdin
                    then
                      try Unix.close listener_fd with
                      | Unix.Unix_error _ -> ());
                   cleanup ())
                 (fun () ->
                   let trailer =
                     supervise ~v ~pid ~stdin_w ~stdout_r ~stderr_r ~stdin_payload
                       ~listener_fd:listener_fd
                       ~timeout_sec:req.Exec_ssh_protocol.timeout_sec in
                   trailer, read_child_boundary boundary_r)
             in
             emit_trailer_stderr ~execution_receipt:(receipt boundary) trailer;
             exit 0)))

(* Capabilities are what this host can do, read when asked, so a probe on a
   kernel without Landlock says so and the runner never sends it a box. *)
let probe () =
  Exec_ssh_protocol.
    { name = "masc-exec-shim"
    ; version =
      Printf.sprintf "%d.0.0%s" protocol_version Shim_build_id.suffix
    ; capabilities =
      (if observe_supported () then [ observe_capability ] else [])
      @ (if user_notif_supported () then [ user_notif_capability ] else [])
    ; release = (if Shim_build_id.release = "" then None else Some Shim_build_id.release)
    }

let main () =
  (* OCaml does NOT ignore SIGPIPE by default; an undelivered SIGPIPE would
     kill the shim outright (signal 13) where the code expects EPIPE
     exceptions — the ssh channel going away mid-stream is a cancel path,
     handled via the On_eof kill policy.  Ignore it here; the payload child
     re-arms the default disposition pre-exec. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  match Array.to_list Sys.argv with
  | [ _; "--probe" ] -> print_endline (Exec_ssh_protocol.render_probe (probe ()))
  | [ _ ] -> run ()
  | _ ->
    prerr_endline "usage: masc-exec-shim [--probe]";
    exit 2
