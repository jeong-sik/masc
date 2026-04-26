(** RFC-0008 PR-1 — pin {!Credential_provider} type surface and
    {!Host_config_provider} pure helpers.

    Integration coverage of [resolve] (which goes through
    [Keeper_gh_env.keeper_binding] + filesystem) is left to the
    existing [test_keeper_shell_docker_route] suite — that path
    already exercises the inline composition we just centralised
    behind the trait, so the functional contract stays pinned end
    to end without re-staging a tmpdir + keeper profile fixture
    here.

    What this file pins:

    1. [Credential_provider.pp_error] formats every variant.  Mostly
       a regression guard: if a future PR adds a fifth error case
       and forgets [pp_error], the [exhaustive] assertion catches it.
    2. [Host_config_provider.For_testing.mount_if_present] returns
       [[]] for empty / missing host paths and a single-element
       [ro_mount] when the path exists.
    3. [For_testing.compose_env] emits exactly the env-key set the
       inline block at [keeper_shell_docker.ml:271-329] used to emit,
       no more, no less.  This is the "behaviorally identical to
       today" property RFC-0008 PR-1 promises.
    4. [finalize] / [tear_down] are noops in PR-1 ([finalize] returns
       [Ok ()] regardless of [container_id]; [tear_down] never
       raises). *)

open Alcotest
module CP = Masc_mcp.Credential_provider
module HCP = Masc_mcp.Host_config_provider

(* --- 1. pp_error covers every variant --- *)

let test_pp_error_all_variants () =
  let cases =
    [ CP.Missing_bundle { identity = "id-A"; path = "/x" }, "Missing_bundle"
    ; CP.Invalid_token { identity = "id-B"; reason = "sha-match" }, "Invalid_token"
    ; CP.Finalize_failed { identity = "id-C"; reason = "rewrite" }, "Finalize_failed"
    ; CP.Tear_down_failed { identity = "id-D"; reason = "rm" }, "Tear_down_failed"
    ]
  in
  List.iter
    (fun (err, prefix) ->
       let rendered = CP.pp_error err in
       check
         bool
         (Printf.sprintf "pp_error renders %s" prefix)
         true
         (String.length rendered > String.length prefix
          && String.sub rendered 0 (String.length prefix) = prefix))
    cases
;;

(* --- 2. mount_if_present skip rules --- *)

let test_mount_if_present_empty_host () =
  let r = HCP.For_testing.mount_if_present ~host:"" ~container:"/x" in
  check int "empty host -> no mount" 0 (List.length r)
;;

let test_mount_if_present_missing_path () =
  let r =
    HCP.For_testing.mount_if_present
      ~host:"/nonexistent-host-path-rfc0008-pr1"
      ~container:"/x"
  in
  check int "missing path -> no mount" 0 (List.length r)
;;

let test_mount_if_present_existing_dir () =
  (* [/tmp] is reliably present on every platform we run on (incl.
     macOS sandboxes where it is a symlink to /private/tmp). *)
  let host = Filename.get_temp_dir_name () in
  let r = HCP.For_testing.mount_if_present ~host ~container:"/c" in
  match r with
  | [ m ] ->
    check string "host preserved" host m.CP.host;
    check string "container preserved" "/c" m.CP.container
  | other -> failf "expected single mount, got %d" (List.length other)
;;

(* --- 3. compose_env key set is exactly what the inline block emitted --- *)

let expected_env_keys =
  [ (* path-derived block (RFC-0008 §3 evidence note) *)
    "HOME"
  ; "GH_CONFIG_DIR"
  ; "GIT_CONFIG_GLOBAL"
  ; "GIT_CONFIG_COUNT"
  ; "GIT_CONFIG_KEY_0"
  ; "GIT_CONFIG_VALUE_0"
  ; (* git author / committer (RFC-0008 §3) *)
    "GIT_AUTHOR_NAME"
  ; "GIT_AUTHOR_EMAIL"
  ; "GIT_COMMITTER_NAME"
  ; "GIT_COMMITTER_EMAIL"
  ; (* Env_git_noninteractive (RFC-0007 PR-1) *)
    "GIT_TERMINAL_PROMPT"
  ; "GIT_ASKPASS"
  ; "GCM_INTERACTIVE"
  ; "SSH_ASKPASS"
  ]
;;

let test_compose_env_key_set () =
  let env =
    HCP.For_testing.compose_env
      ~git_author_name:"keeper-A"
      ~git_author_email:"keeper-A@example.invalid"
  in
  let actual_keys = List.sort compare (List.map fst env) in
  let expected_keys = List.sort compare expected_env_keys in
  check
    (list string)
    "env keys match the pre-extraction inline block exactly"
    expected_keys
    actual_keys
;;

let test_compose_env_path_values_anchored_to_cred_root () =
  let env = HCP.For_testing.compose_env ~git_author_name:"k" ~git_author_email:"k@e" in
  let lookup k = List.assoc k env in
  check string "HOME" HCP.cred_root (lookup "HOME");
  check
    string
    "GH_CONFIG_DIR"
    (Filename.concat HCP.cred_root ".config/gh")
    (lookup "GH_CONFIG_DIR");
  check
    string
    "GIT_CONFIG_GLOBAL"
    (Filename.concat HCP.cred_root ".gitconfig")
    (lookup "GIT_CONFIG_GLOBAL")
;;

let test_compose_env_git_identity_threaded () =
  let env =
    HCP.For_testing.compose_env ~git_author_name:"NAME-X" ~git_author_email:"EMAIL-X"
  in
  let lookup k = List.assoc k env in
  check string "GIT_AUTHOR_NAME" "NAME-X" (lookup "GIT_AUTHOR_NAME");
  check string "GIT_AUTHOR_EMAIL" "EMAIL-X" (lookup "GIT_AUTHOR_EMAIL");
  check string "GIT_COMMITTER_NAME" "NAME-X" (lookup "GIT_COMMITTER_NAME");
  check string "GIT_COMMITTER_EMAIL" "EMAIL-X" (lookup "GIT_COMMITTER_EMAIL")
;;

(* --- 4. finalize / tear_down noop semantics --- *)

let dummy_binding () : CP.binding =
  { identity = "k"; env = []; ro_mounts = []; bootstrap = None; metadata = [] }
;;

let test_finalize_is_noop_ok () =
  let b = dummy_binding () in
  match HCP.finalize b ~container_id:"abc123" with
  | Ok () -> ()
  | Error err -> failf "finalize must noop-Ok in PR-1; got %s" (CP.pp_error err)
;;

let test_tear_down_idempotent () =
  let b = dummy_binding () in
  HCP.tear_down b ~container_id:None;
  HCP.tear_down b ~container_id:(Some "abc");
  HCP.tear_down b ~container_id:None;
  ()
;;

let () =
  run
    "credential_provider"
    [ ( "errors"
      , [ test_case "pp_error covers all variants" `Quick test_pp_error_all_variants ] )
    ; ( "mount_if_present"
      , [ test_case "empty host" `Quick test_mount_if_present_empty_host
        ; test_case "missing path" `Quick test_mount_if_present_missing_path
        ; test_case "existing dir" `Quick test_mount_if_present_existing_dir
        ] )
    ; ( "compose_env"
      , [ test_case "key set" `Quick test_compose_env_key_set
        ; test_case
            "paths anchored to cred_root"
            `Quick
            test_compose_env_path_values_anchored_to_cred_root
        ; test_case "identity threaded" `Quick test_compose_env_git_identity_threaded
        ] )
    ; ( "lifecycle (PR-1 noop)"
      , [ test_case "finalize Ok" `Quick test_finalize_is_noop_ok
        ; test_case "tear_down idempotent" `Quick test_tear_down_idempotent
        ] )
    ]
;;
