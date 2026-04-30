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

let now_unix_ms () =
  Int64.of_float (Unix.gettimeofday () *. 1000.0)

(** Run [gh auth status] against the supplied [GH_CONFIG_DIR] and
    return whether it succeeded.  The implementation runs synchronously
    via [Unix.system] for now; PR-C will move it to [Process_eio.run_argv]
    once the lifecycle hooks land in the keeper-side path. *)
let gh_auth_status_ok ~gh_config_dir =
  let cmd =
    Printf.sprintf
      "GH_CONFIG_DIR=%s gh auth status >/dev/null 2>&1"
      (Filename.quote gh_config_dir)
  in
  match Unix.system cmd with Unix.WEXITED 0 -> true | _ -> false

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

(** Re-compute and update the [state] field of [cred] without touching
    other fields.  Idempotent.  Called by [Credential_store.add] /
    [Credential_store.update] (PR-B Slice 2) so newly-registered
    credentials carry an accurate state without requiring an explicit
    second call. *)
let ensure (cred : credential) : credential =
  let new_state =
    match cred.gh_config_dir with
    | None -> Unmaterialized
    | Some dir -> verify_state ~gh_config_dir:dir
  in
  { cred with state = new_state }

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
    - The resulting bundle is verified by [verify_state] before the
      function returns; the caller can rely on the returned [state]
      reflecting the actual on-disk outcome.

    The function is synchronous (uses [Unix.create_process_env]); PR-C
    will move it to [Process_eio.run_argv] alongside the keeper-side
    lifecycle hooks. *)
let provision_via_with_token ~gh_config_dir ~token : (credential_state, string) result =
  match path_safe gh_config_dir with
  | Error _ as e -> e
  | Ok () ->
      if String.equal (String.trim token) "" then
        Error "with_token provisioning requires a non-empty token"
      else (
        (try mkdir_p gh_config_dir 0o700
         with
         | Unix.Unix_error (err, _, _) ->
             ()
             |> ignore
             |> fun () ->
             ignore err);
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
          let env =
            Array.append (Unix.environment ())
              [|
                "GH_CONFIG_DIR=" ^ gh_config_dir;
                "GIT_TERMINAL_PROMPT=0";
              |]
          in
          let argv =
            [|
              "gh"; "auth"; "login";
              "--with-token";
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
               with _ ->
                 (try close_out_noerr oc with _ -> ()));
              let status = snd (Unix.waitpid [] pid) in
              (match status with
               | Unix.WEXITED 0 ->
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
