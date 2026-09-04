(** Which machine a Keeper's GitHub device-flow login is written to.

    A Docker or Micro_vm Keeper's identity lives in the host directory
    [<base>/.masc/keepers/<name>/github-cli] -- Docker bind-mounts it, a guest
    carries a snapshot of it -- so its login belongs on this host. Both carry
    that directory in at creation, so a container or guest started before its
    Keeper had any identity picks the login up when it is next recreated, not
    while it runs.

    A Remote_ssh Keeper's tree and its [gh] live on another machine, and a login
    written here would never be seen there: every turn would keep failing the
    endpoint's identity preflight ([remote_github_identity_missing]) while the
    operator looks at a successful login on this screen. *)

let ( let* ) = Result.bind

(* Each shaping step is one short remote command. The login itself is the long
   one and carries its own budget. *)
let step_timeout_sec = 30.0

(* Deliberately not [Keeper_sandbox_remote_lane.attached_guest_endpoint]. That
   door ends in [check_preflight], whose last step is the [gh auth status] this
   login exists to make pass, so routing through it makes the fix unreachable
   from the state it fixes. *)
let resolve ~(config : Workspace.config) ~keeper_name =
  let base_path = config.Workspace.base_path in
  let* endpoint = Keeper_sandbox_ssh.resolve_endpoint ~base_path ~keeper_name in
  Keeper_sandbox_ssh.create ~base_path ~keeper_name ~endpoint ()
;;

let run_remote endpoint ~timeout_sec ~on_stdout_chunk ~on_stderr_chunk ~argv =
  let run = Keeper_sandbox_remote.runner ~timeout_sec endpoint in
  run
    ~on_stdout_chunk
    ~on_stderr_chunk
    ~stdin_content:None
    ~argv
    ~env:[||]
    ~cwd:(Some (Keeper_sandbox_remote.remote_root endpoint))
;;

(* The argv is a fixed shape built here -- mkdir, chmod, find, gh -- and carries
   paths rather than credentials, so naming it in the failure is what lets an
   operator act on an exit code. The remote stderr is another matter: it is text
   from another machine that reaches the operator through the SSE [error] event,
   so it goes through the same redaction every other identity failure does, and
   redaction runs before truncation so a cut cannot leave half a secret. *)
let step ~redaction endpoint ~argv =
  match
    run_remote
      endpoint
      ~timeout_sec:step_timeout_sec
      ~on_stdout_chunk:None
      ~on_stderr_chunk:None
      ~argv
  with
  | Unix.WEXITED 0, stdout, _ -> Ok stdout
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, stderr ->
    Error
      (Printf.sprintf
         "remote_ssh_github_login_step_failed: endpoint %s ran [%s]: %s"
         (Keeper_sandbox_remote.name endpoint)
         (String.concat " " argv)
         (Exec_policy.truncate_for_log
            (Keeper_secret_redaction.redact_text redaction (String.trim stderr))))
;;

(* The host lane secures exactly these two names, skips one that is absent and
   refuses one that is not a regular file. The endpoint has to agree on all
   three counts: [gh] writes [config.yml] as well as [hosts.yml], and a chmod
   aimed at one fixed path would fail a login that had in fact succeeded. *)
let config_name_predicate =
  [ "("; "-name"; "hosts.yml"; "-o"; "-name"; "config.yml"; ")" ]
;;

let find_config_files gh_dir tail =
  ([ "find"; gh_dir; "-maxdepth"; "1" ] @ config_name_predicate) @ tail
;;

let secure_config_files ~redaction endpoint ~gh_dir =
  let* (_ : string) = step ~redaction endpoint ~argv:[ "chmod"; "0700"; gh_dir ] in
  let* irregular =
    step ~redaction endpoint ~argv:(find_config_files gh_dir [ "!"; "-type"; "f" ])
  in
  if String.trim irregular <> ""
  then
    Error
      (Printf.sprintf
         "remote_ssh_github_login_credential_not_a_regular_file: endpoint %s: %s"
         (Keeper_sandbox_remote.name endpoint)
         (String.trim irregular))
  else
    let* (_ : string) =
      step
        ~redaction
        endpoint
        ~argv:
          (find_config_files
             gh_dir
             [ "-type"; "f"; "-exec"; "chmod"; "0600"; "{}"; "+" ])
    in
    Ok ()
;;

let remote_lane ~(config : Workspace.config) ~keeper_name ~hostname =
  let base_path = config.Workspace.base_path in
  let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
  let* endpoint = resolve ~config ~keeper_name in
  let gh_dir = Keeper_sandbox_remote.gh_config_dir endpoint in
  (* The endpoint may never have held this Keeper. A root the ssh user cannot
     write is the bootstrap's job, and this step names it rather than letting
     gh fail later with a directory message. *)
  let* (_ : string) = step ~redaction endpoint ~argv:[ "mkdir"; "-p"; gh_dir ] in
  let* (_ : string) = step ~redaction endpoint ~argv:[ "chmod"; "0700"; gh_dir ] in
  let lane : Keeper_github_identity.login_lane =
    { run_login =
        (fun ~on_stdout_chunk ~on_stderr_chunk ->
          run_remote
            endpoint
            ~timeout_sec:Keeper_github_identity.login_timeout_sec
            ~on_stdout_chunk:(Some on_stdout_chunk)
            ~on_stderr_chunk:(Some on_stderr_chunk)
            ~argv:(Keeper_github_identity.login_argv ~hostname))
    ; secure_after_login = (fun () -> secure_config_files ~redaction endpoint ~gh_dir)
    ; observe_after_login =
        (fun () ->
          let run =
            run_remote
              endpoint
              ~timeout_sec:step_timeout_sec
              ~on_stdout_chunk:None
              ~on_stderr_chunk:None
              ~argv:(Keeper_github_identity.auth_probe_argv ~hostname)
          in
          let result =
            Keeper_github_identity.auth_result_of_probe ~base_path ~keeper_name run
          in
          (* masc projects no GitHub token onto an endpoint: the runner drops
             every caller env name outside the endpoint allowlist, and this
             lane supplies none. So the probe with the config directory alone
             is the whole story, and [stored] and [effective] are one reading
             rather than two. *)
          let observation : Keeper_github_identity.observation =
            { keeper = keeper_name
            ; hostname
            ; config_dir = gh_dir
            ; projected_token_env_names = []
            ; stored = result
            ; effective = result
            ; effective_probe_scope = `Endpoint_process_only
            ; checked_at_unix = Time_compat.now ()
            }
          in
          Ok observation)
    }
  in
  Ok lane
;;

let for_keeper ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname =
  let keeper_name = meta.Keeper_meta_contract.name in
  match
    (meta.Keeper_meta_contract.sandbox_profile
      : Keeper_types_profile_sandbox.sandbox_profile)
  with
  (* Both reach the host directory -- Docker binds it, a guest carries a
     snapshot of it -- so a host login is what reaches them. *)
  | Keeper_types_profile_sandbox.Docker | Keeper_types_profile_sandbox.Micro_vm ->
    Keeper_github_identity.local_lane ~config ~keeper_name ~hostname
  | Keeper_types_profile_sandbox.Remote_ssh -> remote_lane ~config ~keeper_name ~hostname
;;
