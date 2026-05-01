(** See {!In_container_login_provider} interface. *)

(* ── Path constants ─────────────────────────────────────────────────── *)

(* Path inside the container where the token temp-file is mounted. *)
let container_token_path = "/tmp/masc-keeper-bootstrap-token"

(* In-container GH_CONFIG_DIR — mirrors Host_config_provider.cred_root. *)
let gh_config_dir_in_container =
  Filename.concat Host_config_provider.cred_root ".config/gh"

let container_hosts_yml_path =
  Filename.concat gh_config_dir_in_container "hosts.yml"

(* ── Token extraction ────────────────────────────────────────────────── *)

(* Strip one layer of optional surrounding single/double quotes and
   trim whitespace.  YAML scalars in hosts.yml are either bare or
   single-quoted; tokens never contain whitespace. *)
let strip_yaml_value raw =
  let s = String.trim raw in
  let n = String.length s in
  if n >= 2
     && ( (s.[0] = '"' && s.[n - 1] = '"')
       || (s.[0] = '\'' && s.[n - 1] = '\'') )
  then String.sub s 1 (n - 2)
  else s

(** Extract [oauth_token] from [<gh_config_dir>/hosts.yml].
    Returns [None] when the file is absent or the key is missing. *)
let read_token_from_hosts_yml ~gh_config_dir =
  let path = Filename.concat gh_config_dir "hosts.yml" in
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      let token = ref None in
      (try
         while !token = None do
           let line = input_line ic in
           let trimmed = String.trim line in
           let prefix = "oauth_token:" in
           let plen = String.length prefix in
           if String.length trimmed > plen
              && String.equal (String.sub trimmed 0 plen) prefix
           then begin
             let raw =
               String.sub trimmed plen (String.length trimmed - plen)
             in
             token := Some (strip_yaml_value raw)
           end
         done
       with End_of_file -> ());
      close_in ic;
      !token
    with Sys_error _ -> None

(* ── SHA-256 helper ──────────────────────────────────────────────────── *)

let sha256_prefix s =
  let full = Digestif.SHA256.(digest_string s |> to_hex) in
  String.sub full 0 12

(* ── Operator ambient token (best-effort) ───────────────────────────── *)

(* Capture the operator ambient [gh auth token] — same approach as
   in [Credential_materializer] but local here to keep lib/keeper free
   of a direct dep on lib/repo_manager.  Returns [None] on any failure;
   the gate is permissive in that case. *)
let read_operator_ambient_token () : string option =
  let read_fd, write_fd = Unix.pipe ~cloexec:false () in
  let devnull_err =
    try Some (Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o644)
    with Unix.Unix_error _ -> None
  in
  let stderr_fd = Option.value devnull_err ~default:Unix.stderr in
  (* Strip any GH_CONFIG_DIR set in the caller so we read the operator
     ambient credential, not whatever the keeper bootstrap pointed at. *)
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun kv ->
         not
           (String.length kv >= 14
            && String.equal (String.sub kv 0 14) "GH_CONFIG_DIR="))
    |> Array.of_list
  in
  let pid =
    try
      Some
        (Unix.create_process_env "gh"
           [| "gh"; "auth"; "token" |]
           env Unix.stdin write_fd stderr_fd)
    with Unix.Unix_error _ -> None
  in
  (try Unix.close write_fd with Unix.Unix_error _ -> ());
  Option.iter
    (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())
    devnull_err;
  match pid with
  | None ->
      (try Unix.close read_fd with Unix.Unix_error _ -> ());
      None
  | Some pid ->
      let ic = Unix.in_channel_of_descr read_fd in
      let buf = Buffer.create 128 in
      (try while true do Buffer.add_channel buf ic 64 done
       with End_of_file -> ());
      (try close_in ic with _ -> ());
      let status = snd (Unix.waitpid [] pid) in
      (match status with
       | Unix.WEXITED 0 ->
           let token = String.trim (Buffer.contents buf) in
           if String.equal token "" then None else Some token
       | _ -> None)

(* ── provider_gate ──────────────────────────────────────────────────── *)

let provider_gate ~identity ~gh_config_dir =
  match read_token_from_hosts_yml ~gh_config_dir with
  | None ->
      Error
        (Printf.sprintf
           "no oauth_token found in bundle for identity %s \
            (path: %s/hosts.yml); cannot run provider_gate"
           identity gh_config_dir)
  | Some bundle_token ->
      let bundle_sha = sha256_prefix bundle_token in
      (match read_operator_ambient_token () with
       | None ->
           (* Operator ambient token unavailable — gate is permissive. *)
           Ok ()
       | Some op_token ->
           let op_sha = sha256_prefix op_token in
           if String.equal op_sha bundle_sha then
             Error
               (Printf.sprintf
                  "In_container_login_provider: identity %s token \
                   SHA-256 prefix (%s) matches operator ambient token; \
                   refusing Option B bootstrap. Rotate the keeper's \
                   fine-grained PAT (RFC-0008 F-1) before using this \
                   provider. Override with MASC_KEEPER_ALLOW_SHARED_TOKEN=1."
                  identity bundle_sha)
           else Ok ())

(* ── identity safety guard ──────────────────────────────────────────── *)

(* Keeper names contain only alphanumeric, hyphens, and underscores by
   convention.  This invariant is checked before embedding the identity
   in shell arguments passed to the awk fallback. *)
let identity_is_safe s =
  String.length s > 0
  && String.for_all
       (fun c ->
         (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
         || c = '-' || c = '_')
       s

(* ── Temp token file lifecycle ──────────────────────────────────────── *)

(* Write [token] to a fresh temp file with mode 0600 and return its
   path.  Returns [Error _] when creation or write fails. *)
let write_token_to_temp_file ~identity token =
  let prefix = Printf.sprintf "masc-keeper-token-%s-" identity in
  try
    let path = Filename.temp_file prefix "" in
    (* Restrict to owner-only immediately.  The temp_file call creates
       the file with mode determined by umask; chmod before writing. *)
    Unix.chmod path 0o600;
    let oc = open_out path in
    (Fun.protect
       ~finally:(fun () -> close_out_noerr oc)
       (fun () ->
         output_string oc token;
         output_char oc '\n'));
    Ok path
  with
  | Sys_error msg ->
      Error
        (Credential_provider.Missing_bundle
           { identity
           ; path =
               Printf.sprintf
                 "could not write temporary token file for %s: %s"
                 identity msg
           })
  | Unix.Unix_error (e, _, _) ->
      Error
        (Credential_provider.Missing_bundle
           { identity
           ; path =
               Printf.sprintf
                 "could not chmod temporary token file for %s: %s"
                 identity (Unix.error_message e)
           })

(* ── resolve ────────────────────────────────────────────────────────── *)

let resolve ~config ~identity:keeper_name =
  (* Allow gate override for exceptional cases (RFC-0008 §6 R2). *)
  let gate_overridden =
    match Sys.getenv_opt "MASC_KEEPER_ALLOW_SHARED_TOKEN" with
    | Some v when not (String.equal (String.trim v) "0") -> true
    | _ -> false
  in
  match Keeper_gh_env.keeper_binding config ~keeper_name with
  | Error reason ->
      Error
        (Credential_provider.Missing_bundle
           { identity = keeper_name; path = reason })
  | Ok kb ->
      let gate_result =
        if gate_overridden then begin
          Log.Keeper.warn
            "%s: MASC_KEEPER_ALLOW_SHARED_TOKEN overrides provider_gate; \
             audit line emitted (RFC-0008 §6 R2)"
            keeper_name;
          Ok ()
        end else
          provider_gate ~identity:keeper_name
            ~gh_config_dir:kb.gh_config_dir
      in
      (match gate_result with
       | Error reason ->
           Error
             (Credential_provider.Invalid_token
                { identity = keeper_name; reason })
       | Ok () ->
           match
             read_token_from_hosts_yml ~gh_config_dir:kb.gh_config_dir
           with
           | None ->
               Error
                 (Credential_provider.Missing_bundle
                    { identity = keeper_name
                    ; path =
                        Printf.sprintf
                          "no oauth_token in bundle hosts.yml for %s \
                           (gh_config_dir: %s)"
                          keeper_name kb.gh_config_dir
                    })
           | Some token ->
               match write_token_to_temp_file ~identity:keeper_name token with
               | Error _ as err -> err
               | Ok token_host_path ->
                   (* Compose the same container-local env as Option A.
                      The container builds its own gh config via bootstrap;
                      the host bundle is NOT mounted read-only. *)
                   let git_author_name, git_author_email =
                     match kb.github_identity, kb.git_identity_mode with
                     | Some id, "github_identity" ->
                         id, id ^ "@users.noreply.github.com"
                     | _ ->
                         Keeper_identity.keeper_git_author ~keeper_name,
                         Keeper_identity.keeper_git_email ~keeper_name
                   in
                   let env =
                     Host_config_provider.For_testing.compose_env
                       ~git_author_name ~git_author_email
                   in
                   (* Token temp-file is the only host-side RO mount.
                      The keeper's gh config bundle is NOT mounted because
                      the container writes its own config via bootstrap.
                      tear_down deletes the host temp file. *)
                   let ro_mounts =
                     [ Credential_provider.
                         { host = token_host_path
                         ; container = container_token_path
                         }
                     ]
                   in
                   (* Bootstrap argv: read token from the mounted temp file
                      and pipe to gh auth login.  The docker-invocation
                      site executes this after container start (RFC-0008
                      §4 PR-3). *)
                   let bootstrap =
                     Some
                       [ "sh"; "-c"
                       ; Printf.sprintf
                           "gh auth login --with-token \
                            --hostname github.com \
                            --git-protocol https \
                            < %s"
                           container_token_path
                       ]
                   in
                   let metadata =
                     [ "source", "in_container_login"
                     ; "git_identity_mode", kb.git_identity_mode
                     ; "effective_github_identity",
                       kb.effective_github_identity
                     ; "credential_scope",
                       Keeper_gh_env.credential_scope_to_string
                         kb.credential_scope
                     ; "bundle_root", kb.bundle_root
                     (* token_host_path is read by tear_down for cleanup *)
                     ; "token_host_path", token_host_path
                     ]
                   in
                   let metadata =
                     match kb.github_identity with
                     | Some id -> metadata @ [ "github_identity", id ]
                     | None -> metadata
                   in
                   Ok
                     Credential_provider.
                       { identity = keeper_name
                       ; env
                       ; ro_mounts
                       ; bootstrap
                       ; metadata
                       })

(* ── finalize ───────────────────────────────────────────────────────── *)

(* Run [docker exec <container_id> <argv>] synchronously, discarding
   stdout/stderr.  Returns [Ok ()] on exit 0, [Error msg] otherwise. *)
let run_docker_exec ~container_id argv_tail =
  let argv = Array.of_list ("docker" :: "exec" :: container_id :: argv_tail) in
  let devnull =
    try Some (Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o644)
    with Unix.Unix_error _ -> None
  in
  let null_fd = Option.value devnull ~default:Unix.stderr in
  let pid =
    try Some (Unix.create_process "docker" argv Unix.stdin null_fd null_fd)
    with Unix.Unix_error _ -> None
  in
  Option.iter
    (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())
    devnull;
  match pid with
  | None -> Error "failed to spawn `docker exec`"
  | Some pid ->
      let status = snd (Unix.waitpid [] pid) in
      (match status with
       | Unix.WEXITED 0 -> Ok ()
       | Unix.WEXITED n ->
           Error (Printf.sprintf "docker exec exited %d" n)
       | Unix.WSIGNALED n ->
           Error (Printf.sprintf "docker exec killed by signal %d" n)
       | Unix.WSTOPPED n ->
           Error (Printf.sprintf "docker exec stopped by signal %d" n))

(* Rewrite [hosts.yml:user] inside the container to [identity].

   Primary path: Python 3 one-liner — identity is passed as a separate
   argv argument so there is no shell-string interpolation risk.

   Fallback: POSIX awk + temp-file rename — used when python3 is
   absent.  The awk path requires [identity_is_safe identity] because
   the identity is embedded in the awk program string; [resolve]
   enforces this precondition at binding time (keeper names are
   alphanumeric + '-' + '_').

   Returns [Ok ()] when either path succeeds; [Error msg] otherwise. *)
let rewrite_hosts_yml_user ~container_id ~identity ~hosts_yml_path =
  (* Primary: Python 3 — identity passed as argv, no shell quoting needed. *)
  let py_code =
    "import re, sys, os; p=sys.argv[1]; id_=sys.argv[2]; \
     (not os.path.exists(p)) and exit(0); \
     t=open(p).read(); \
     open(p,'w').write(re.sub(r'(?m)(^[ \\t]*user:[ \\t]*).*', \
     lambda m: m.group(1)+id_, t))"
  in
  let primary =
    run_docker_exec ~container_id
      [ "python3"; "-c"; py_code; hosts_yml_path; identity ]
  in
  match primary with
  | Ok () -> Ok ()
  | Error primary_err ->
      (* Fallback: POSIX awk — only safe when identity contains no shell
         metacharacters (validated by identity_is_safe). *)
      if not (identity_is_safe identity) then Error primary_err
      else
        (* POSIX sub() rewrites only the first match per line; the
           pattern anchors to lines beginning with optional whitespace
           followed by "user:", which is exactly one line in hosts.yml. *)
        let awk_prog =
          Printf.sprintf
            "/^[[:space:]]*user:/{sub(/user:[[:space:]].*/,\
             \"user: %s\")} 1"
            identity
        in
        let awk_cmd =
          Printf.sprintf
            "awk '%s' '%s' > '%s.tmp' && mv '%s.tmp' '%s'"
            awk_prog hosts_yml_path hosts_yml_path
            hosts_yml_path hosts_yml_path
        in
        (match run_docker_exec ~container_id [ "sh"; "-c"; awk_cmd ] with
         | Ok () -> Ok ()
         | Error _ -> Error primary_err)

let finalize (b : Credential_provider.binding) ~container_id =
  Prometheus.inc_counter
    "keeper_credential_provider_finalize_relabel_total"
    ~labels:[ ("provider", "in_container_login"); ("result", "attempt") ]
    ();
  let result =
    rewrite_hosts_yml_user ~container_id
      ~identity:b.identity
      ~hosts_yml_path:container_hosts_yml_path
  in
  (match result with
   | Ok () ->
       Prometheus.inc_counter
         "keeper_credential_provider_finalize_relabel_total"
         ~labels:[ ("provider", "in_container_login"); ("result", "ok") ]
         ()
   | Error reason ->
       Prometheus.inc_counter
         "keeper_credential_provider_finalize_relabel_total"
         ~labels:[ ("provider", "in_container_login"); ("result", "error") ]
         ();
       Log.Keeper.warn
         "In_container_login_provider.finalize: hosts.yml user relabel \
          failed for %s (container %s): %s"
         b.identity container_id reason);
  (match result with
   | Ok () -> Ok ()
   | Error reason ->
       Error
         (Credential_provider.Finalize_failed
            { identity = b.identity; reason }))

(* ── tear_down ──────────────────────────────────────────────────────── *)

let tear_down (b : Credential_provider.binding) ~container_id:_ =
  (* Delete the temporary token file staged by [resolve].  Idempotent:
     if the file is already gone (e.g. a previous [tear_down] call),
     [Sys.remove] raises [Sys_error] which we silently drop. *)
  (match List.assoc_opt "token_host_path" b.metadata with
   | None -> ()
   | Some path ->
       if not (String.equal (String.trim path) "") then
         (try Sys.remove path with Sys_error _ -> ()))

(* ── For_testing ────────────────────────────────────────────────────── *)

module For_testing = struct
  let container_hosts_yml_path = container_hosts_yml_path
  let read_token_from_hosts_yml = read_token_from_hosts_yml
end
