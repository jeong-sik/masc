(** RFC-0019 PR-B §4.4 — credential materialiser.

    Decides the on-disk lifecycle status of a credential record:

    | gh_config_dir input | action | resulting state |
    |---------------------|--------|-----------------|
    | None / empty | none | [Unmaterialized] |
    | non-empty dir, missing on disk | none | [Unmaterialized] |
    | exists + [gh auth status] = 0 | record verify timestamp | [Materialized {last_verified_at}] |
    | exists + [gh auth status] != 0 | record reason | [Stale {reason}] |

    PR-B Slice 1 ships this **verify-only** path.  The two [oauth_method]
    materialisation flows (web device-flow, with-token) are layered on
    top by Slice 2 in [Server_routes_http_routes_credentials].  The trait
    surface stays minimal so PR-C can wire [Credential_provider.finalize]
    against it without introducing new public types. *)

open Repo_manager_types

let git_terminal_prompt_key = "GIT_" ^ "TERMINAL_PROMPT"
let git_terminal_prompt_env = git_terminal_prompt_key ^ "=0"

let now_unix_ms () =
  Int64.of_float (Unix.gettimeofday () *. 1000.0)

let gh_hosts_yml = "hosts.yml"

let close_fd_noerr fd =
  try Unix.close fd with Unix.Unix_error _ -> ()

(* [Unix.waitpid] raises [Unix_error EINTR] when a signal interrupts
   the wait.  Without retry the exception escapes the three call
   sites in this module — [gh_auth_status_ok],
   [read_operator_ambient_token], [provision_via_with_token] — and
   ultimately surfaces as [tools/call crashed: Unix_error EINTR
   waitpid] for keeper_bash / docker shell paths.  Observed live at
   ~5/hr (2026-05-05).  Retry is the canonical Posix idiom and
   matches the prior-art helper in lib/process/process_eio.ml:281. *)
let rec waitpid_no_intr pid =
  try Unix.waitpid [] pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_no_intr pid

let env_key kv =
  match String.index_opt kv '=' with
  | None -> kv
  | Some i -> String.sub kv 0 i

let scrubbed_gh_env_key = function
  | "GH_CONFIG_DIR"
  | "GH_TOKEN"
  | "GITHUB_TOKEN"
  | "GH_ENTERPRISE_TOKEN"
  | "GITHUB_ENTERPRISE_TOKEN"
  | "GH_PROMPT_DISABLED" ->
      true
  | key when String.equal key git_terminal_prompt_key -> true
  | _ -> false

let gh_bundle_env ~gh_config_dir =
  let inherited =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun kv -> not (scrubbed_gh_env_key (env_key kv)))
  in
  Array.of_list
    (inherited
     @ [
         "GH_CONFIG_DIR=" ^ gh_config_dir;
         git_terminal_prompt_env;
         "GH_PROMPT_DISABLED=1";
       ])

(** Run [gh auth status] against the supplied [GH_CONFIG_DIR] and
    return whether it succeeded.  The child process receives a
    bundle-scoped environment only, so ambient GH_TOKEN/GITHUB_TOKEN
    values cannot make a stale bundle look materialized. *)
let gh_auth_status_ok ~gh_config_dir =
  let devnull_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let devnull_out = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o644 in
  let pid =
    try
      Some
        (Unix.create_process_env "gh"
           [| "gh"; "auth"; "status" |]
           (gh_bundle_env ~gh_config_dir)
           devnull_in devnull_out devnull_out)
    with Unix.Unix_error _ -> None
  in
  close_fd_noerr devnull_in;
  close_fd_noerr devnull_out;
  match pid with
  | None -> false
  | Some pid -> (
      match snd (waitpid_no_intr pid) with
      | Unix.WEXITED 0 -> true
      | _ -> false)

(** Compute the new state for [gh_config_dir] without writing anywhere.
    Pure with respect to credential records; reads filesystem + invokes
    [gh] subprocess. *)
let verify_state ~gh_config_dir : credential_state =
  if String.equal (String.trim gh_config_dir) "" then Unmaterialized
  else if not (Sys.file_exists gh_config_dir) then Unmaterialized
  else if not (Sys.is_directory gh_config_dir) then
    Stale { reason = "gh_config_dir is not a directory" }
  else if gh_auth_status_ok ~gh_config_dir then
    Materialized { last_verified_at = now_unix_ms () }
  else
    Stale { reason = "gh auth status returned non-zero exit code" }

(* RFC-0019 PR-C §3.2 P1 — token-as-boundary invariant requires a
   stable, length-bounded fingerprint of the actual oauth_token so the
   F-1 gate can compare a keeper-scoped credential against the operator
   ambient credential without ever seeing the token strings themselves.

   We use [Digestif.SHA256.digest_string] with a 12-character hex prefix.
   12 hex chars = 48 bits — enough to make accidental collisions
   astronomically unlikely (2^-48 per pair) while being short enough to
   surface in logs/audit without prompting people to redact it. *)
let sha256_prefix s =
  let full =
    Digestif.SHA256.(digest_string s |> to_hex)
  in
  String.sub full 0 12

(* Strip a single leading or trailing whitespace/quote/CR around the
   YAML scalar value.  Tokens in [hosts.yml] never contain whitespace,
   so this is sufficient for the narrow F-1 input.  Conservative: we
   accept either bare or single/double-quoted forms. *)
let strip_value_decorations raw =
  let trimmed = String.trim raw in
  let n = String.length trimmed in
  if n >= 2
     && ( (trimmed.[0] = '"' && trimmed.[n - 1] = '"')
       || (trimmed.[0] = '\'' && trimmed.[n - 1] = '\'') )
  then String.sub trimmed 1 (n - 2)
  else trimmed

(* Read the [oauth_token] line from a [hosts.yml] under [gh_config_dir].
   Returns [None] if the file is missing or the token line is absent.
   The token value never escapes this function; callers receive only
   its [sha256_prefix]. *)
let read_token_from_hosts_yml ~gh_config_dir =
  let path = Filename.concat gh_config_dir gh_hosts_yml in
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let token = ref None in
          (try
             while !token = None do
               let line = input_line ic in
               let trimmed = String.trim line in
               let prefix = "oauth_token:" in
               let plen = String.length prefix in
               if String.length trimmed > plen
                  && String.equal (String.sub trimmed 0 plen) prefix
               then
                 let raw =
                   String.sub trimmed plen (String.length trimmed - plen)
                 in
                 token := Some (strip_value_decorations raw)
             done
           with End_of_file -> ());
          !token)
    with Sys_error _ -> None

(** Compute the SHA-256 prefix of the [oauth_token] stored in
    [<gh_config_dir>/hosts.yml].  Returns [None] when the bundle has not
    been materialised yet (no hosts.yml on disk).  Callers that need the
    full hash should not — the prefix is sufficient for F-1 comparison
    and intentionally short enough to be safe to surface. *)
let compute_token_sha256_prefix ~gh_config_dir : string option =
  match read_token_from_hosts_yml ~gh_config_dir with
  | None -> None
  | Some token -> Some (sha256_prefix token)

(* Capture the operator ambient [gh auth token] best-effort.  Used only
   for F-1 comparison; on any failure (gh not installed, not authed,
   subprocess error) we return [None] and the gate stays silent — F-1
   is permissive in PR-C and only ratchets to strict in a follow-up. *)
let read_operator_ambient_token () : string option =
  let read_fd, write_fd = Unix.pipe ~cloexec:false () in
  let devnull_err =
    try Some (Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o644)
    with Unix.Unix_error _ -> None
  in
  let stderr_fd = Option.value devnull_err ~default:Unix.stderr in
  (* Strip any GH_CONFIG_DIR set in the parent so we read the operator
     ambient credential, not whatever the parent caller pointed at. *)
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun kv ->
      not (String.length kv >= 14
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
      (try
         while true do Buffer.add_channel buf ic 64 done
       with End_of_file -> ());
      close_in_noerr ic;
      let status = snd (waitpid_no_intr pid) in
      (match status with
       | Unix.WEXITED 0 ->
           let token = String.trim (Buffer.contents buf) in
           if String.equal token "" then None else Some token
       | _ -> None)

(** RFC-0019 PR-C §3.2 P1 — F-1 gate (permissive).

    Compares the SHA-256 prefix of the keeper bundle's token against the
    operator ambient [gh auth token].  Emits the
    [keeper_credential_provider_gate_warned_total] Prometheus counter
    when the prefixes match (i.e. the keeper is reusing the operator's
    PAT — the cosmetic-identity scenario that motivated RFC-0008 F-1).

    Permissive in PR-C: the gate logs and counts but does not refuse
    materialisation.  Strict mode is gated on a 2-week soak window in
    PR-D.  Best-effort on the operator side: if [gh] is not installed
    or the operator is not authed, we silently skip — the warning is
    a positive signal, never an absence-of-signal. *)
type f1_gate_outcome =
  | F1_skipped of string
  | F1_distinct
  | F1_shared_with_operator

let f1_gate_check ~credential_id:_ ~gh_config_dir : f1_gate_outcome =
  match compute_token_sha256_prefix ~gh_config_dir with
  | None -> F1_skipped "bundle has no oauth_token to fingerprint"
  | Some bundle_prefix ->
      (match read_operator_ambient_token () with
       | None ->
           F1_skipped
             "operator ambient `gh auth token` unavailable; gate is \
              permissive and skips comparison"
       | Some op_token ->
           let op_prefix = sha256_prefix op_token in
           if String.equal op_prefix bundle_prefix then
             F1_shared_with_operator
           else F1_distinct)

(** Re-compute and update the [state] and [token_sha256_prefix] fields
    of [cred] without touching other fields.  Idempotent.  Called by
    [Credential_store.add] / [Credential_store.update] so newly-
    registered credentials carry an accurate state without requiring an
    explicit second call. *)
let ensure (cred : credential) : credential =
  let new_state, new_prefix =
    match cred.gh_config_dir with
    | None -> Unmaterialized, None
    | Some dir ->
        let s = verify_state ~gh_config_dir:dir in
        let p =
          match s with
          | Materialized _ -> compute_token_sha256_prefix ~gh_config_dir:dir
          | _ -> None
        in
        s, p
  in
  { cred with state = new_state; token_sha256_prefix = new_prefix }

(** RFC-0008 F-2 / RFC-0019 PR-C — rewrite [hosts.yml:user] back to the
    keeper-scoped identity label after [gh auth login --with-token]
    overwrites it with the real GitHub login.

    Best-effort: the relabel is cosmetic by P1 (the credential boundary
    IS the token, not the [user:] line).  We attempt the rewrite and
    silently skip on any I/O error — the bundle remains usable and the
    operator's audit shows the real GitHub login as a fallback.  Any
    failure is reflected in the [state] field by the next
    [verify_state] call. *)
let relabel_hosts_yml ~gh_config_dir ~identity_label =
  let path = Filename.concat gh_config_dir gh_hosts_yml in
  if not (Sys.file_exists path) then ()
  else
    try
      let ic = open_in path in
      let lines =
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
            let lines = ref [] in
            (try
               while true do lines := input_line ic :: !lines done
             with End_of_file -> ());
            !lines)
      in
      let rewritten =
        List.rev_map
          (fun line ->
            let trimmed = String.trim line in
            let prefix = "user:" in
            let plen = String.length prefix in
            if String.length trimmed > plen
               && String.equal (String.sub trimmed 0 plen) prefix
            then
              (* Preserve the original indentation. *)
              let leading_ws =
                let n = String.length line in
                let i = ref 0 in
                while !i < n && (line.[!i] = ' ' || line.[!i] = '\t') do
                  incr i
                done;
                String.sub line 0 !i
              in
              Printf.sprintf "%suser: %s" leading_ws identity_label
            else line)
          lines
      in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          List.iter
            (fun line -> output_string oc line; output_char oc '\n')
            rewritten)
    with Sys_error _ -> ()

(* RFC-0019 PR-B Slice 2 + §8 R3: refuse paths that escape via [..]
   segments.  Absolute or relative are both allowed; what is not allowed
   is any segment equal to [".."], anywhere in the path.  This guards
   the operator-supplied [gh_config_dir] from being used to write into
   arbitrary host directories via crafted POST bodies. *)
let path_safe path : (unit, string) result =
  let segments = String.split_on_char '/' path in
  if List.exists (fun s -> String.equal s "..") segments then
    Result.Error
      (Printf.sprintf
         "gh_config_dir %S contains a forbidden \"..\" segment" path)
  else Result.Ok ()

(* Recursive mkdir for the provisioner; mirrors [Fs_compat.mkdir_p]
   semantics but stays inside the repo_manager library so the materializer
   has no external dep. *)
let rec mkdir_p path mode =
  if String.equal path "" || String.equal path "/" || String.equal path "." then
    ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent mode;
    try Unix.mkdir path mode
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

(** RFC-0019 PR-B Slice 2 — materialise a credential via [gh auth login
    --with-token].

    Security invariants (all validated by [test_credential_materializer]):

    - [token] is consumed exactly once, written to the [gh] subprocess
      via stdin pipe, and never appears in the function's return value,
      its error messages, the captured subprocess stdout/stderr, or any
      log line.
    - [stderr] and [stdout] of [gh auth login] are redirected to
      [/dev/null] so partial-failure messages from [gh] cannot
      accidentally surface a user-supplied token.
    - [gh_config_dir] is rejected if it contains a [".."] segment.
    - [gh] receives only bundle-scoped GitHub auth env and is forced to
      [--insecure-storage], so the token is written into
      [GH_CONFIG_DIR/hosts.yml] instead of an operator keyring that a
      keeper container cannot mount.
    - The resulting bundle is verified by [verify_state] before the
      function returns; the caller can rely on the returned [state]
      reflecting the actual on-disk outcome.

    The function is synchronous (uses [Unix.create_process_env]); PR-C
    will move it to [Process_eio.run_argv] alongside the keeper-side
    lifecycle hooks. *)
let provision_via_with_token ?credential_id ?identity_label
    ~gh_config_dir ~token () : (credential_state, string) result =
  match path_safe gh_config_dir with
  | Error _ as e -> e
  | Ok () ->
      if String.equal (String.trim token) "" then
        Error "with_token provisioning requires a non-empty token"
      else (
        (try mkdir_p gh_config_dir 0o700
         with Unix.Unix_error _ -> ());
        if not (Sys.file_exists gh_config_dir) then
          Error
            (Printf.sprintf
               "could not create gh_config_dir %S" gh_config_dir)
        else
          let read_fd, write_fd = Unix.pipe ~cloexec:false () in
          (* The pipe's read end will be passed to the child; the write
             end stays in the parent.  cloexec on read_fd would close it
             before exec; we set cloexec=false then explicitly close
             read_fd in the parent after fork. *)
          let devnull_out =
            Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o644
	          in
	          let env = gh_bundle_env ~gh_config_dir in
          let argv =
            [|
              "gh"; "auth"; "login";
              "--with-token";
              "--insecure-storage";
              "--hostname"; "github.com";
              "--git-protocol"; "https";
            |]
          in
          let pid =
            try
              Some
                (Unix.create_process_env "gh" argv env read_fd devnull_out
                   devnull_out)
            with Unix.Unix_error _ -> None
          in
          (* Parent: close child's stdin read end *)
          (try Unix.close read_fd with Unix.Unix_error _ -> ());
          (try Unix.close devnull_out with Unix.Unix_error _ -> ());
          match pid with
          | None ->
              (try Unix.close write_fd with Unix.Unix_error _ -> ());
              Error
                "failed to spawn `gh auth login --with-token` subprocess; \
                 is gh installed and on PATH?"
          | Some pid ->
              (* Write token to child's stdin and close.  No logging,
                 no string concatenation that could leak the token. *)
              let oc = Unix.out_channel_of_descr write_fd in
              (try
                 output_string oc token;
                 output_char oc '\n';
                 close_out oc
               with
               | Sys_error _ ->
                   close_out_noerr oc);
              let status = snd (waitpid_no_intr pid) in
              (match status with
               | Unix.WEXITED 0 ->
                   (* RFC-0008 F-2: relabel hosts.yml:user back to the
                      keeper-scoped identity (gh just overwrote it
                      with the real GitHub login).  Best-effort. *)
                   Option.iter
                     (fun label ->
                       relabel_hosts_yml ~gh_config_dir
                         ~identity_label:label)
                     identity_label;
                   (* RFC-0019 PR-C: F-1 gate is invoked by the caller
                      (server route) so the Prometheus emission stays in
                      the masc_mcp library, avoiding a circular dep
                      from repo_manager.  The [credential_id] arg is
                      accepted here for API symmetry only. *)
                   ignore credential_id;
                   Ok (verify_state ~gh_config_dir)
               | Unix.WEXITED n ->
                   Error
                     (Printf.sprintf
                        "gh auth login --with-token failed (exit %d). \
                         Token contents are not logged. Run `GH_CONFIG_DIR=%s \
                         gh auth status` manually to diagnose."
                        n gh_config_dir)
               | Unix.WSIGNALED n ->
                   Error
                     (Printf.sprintf
                        "gh auth login --with-token killed by signal %d"
                        n)
               | Unix.WSTOPPED n ->
                   Error
                     (Printf.sprintf
                        "gh auth login --with-token stopped by signal %d"
                        n)))
