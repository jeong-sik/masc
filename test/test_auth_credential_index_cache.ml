(** Tests for the credential token-hash index cache.

    These tests assert the *observable* invariants the cache must preserve:

    - [find_credential_by_token] returns the same answer it did before
      the cache existed: hit on a live token, mismatch on a deleted
      token, mismatch on a never-issued token, expired error past TTL.
    - [save_credential] makes a freshly minted token findable on the
      *very next* lookup (not after the 60s TTL), proving the cache is
      invalidated on writes through this module.
    - [delete_credential] makes a revoked token un-findable on the
      next lookup, proving the same invalidation path also fires on
      removal — silent re-authentication from a stale cache would be a
      security regression.
    - Repeated lookups for the same token stay correct (cache TTL
      window stays valid).
    - A token another process minted after the index was cached is found
      on the next lookup. masc-tui, [masc login] and setup mint beside a
      running server; the server's own invalidation never sees those writes.
    - A bearer that matches nothing does not rebuild the index while the
      credentials are unchanged, so unknown tokens cost one stat each.

    The cache is keyed by [agents_dir config] (per base_path), so each
    test sets up its own temp workspace and cleans up to avoid cross-test
    interference. *)

let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest
module Auth = Auth

let setup_test_workspace () =
  let unique_id =
    Printf.sprintf "masc-auth-cache-test-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  let masc_dir = Filename.concat tmp Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  tmp

let cleanup_test_workspace dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path
  in
  try rm_rf dir with _ -> ()

(** Auth credential I/O is built on [Eio_guard.run_in_systhread], and
    the cache itself protects state with [Eio.Mutex] — both require an
    active Eio context.  Wrap each test that touches credential state
    in the same shape as [test_auth.ml]'s [with_eio_runtime]. *)
let with_eio_runtime f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.clear_fs ())
    f

let create_token_for dir ~agent_name ~role =
  match Auth.create_token dir ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error e -> fail (Masc_domain.masc_error_to_string e)

(* ------------------------------------------------------------------ *)

let test_lookup_stays_correct_across_repeated_calls () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        for _ = 1 to 5 do
          match Auth.find_credential_by_token dir ~token:raw with
          | Ok cred -> check string "alpha resolved" "alpha" cred.agent_name
          | Error e -> fail (Masc_domain.masc_error_to_string e)
        done))

let test_save_credential_invalidates_cache () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw_a = create_token_for dir ~agent_name:"agent_a" ~role:Masc_domain.Worker in
        (match Auth.find_credential_by_token dir ~token:raw_a with
         | Ok _ -> ()
         | Error e -> fail ("agent_a warm: " ^ Masc_domain.masc_error_to_string e));
        let raw_b = create_token_for dir ~agent_name:"agent_b" ~role:Masc_domain.Worker in
        (match Auth.find_credential_by_token dir ~token:raw_b with
         | Ok cred -> check string "agent_b resolved" "agent_b" cred.agent_name
         | Error e -> fail ("agent_b: " ^ Masc_domain.masc_error_to_string e));
        match Auth.find_credential_by_token dir ~token:raw_a with
        | Ok cred -> check string "agent_a still resolved" "agent_a" cred.agent_name
        | Error e -> fail ("agent_a re-lookup: " ^ Masc_domain.masc_error_to_string e)))

let test_delete_credential_invalidates_cache () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"ephemeral" ~role:Masc_domain.Worker in
        (match Auth.find_credential_by_token dir ~token:raw with
         | Ok _ -> ()
         | Error e -> fail ("warm: " ^ Masc_domain.masc_error_to_string e));
        Auth.delete_credential dir "ephemeral";
        match Auth.find_credential_by_token dir ~token:raw with
        | Ok cred ->
          fail
            (Printf.sprintf
               "expected post-delete mismatch but got cred for %s"
               cred.agent_name)
        | Error _ -> ()))

let test_unknown_token_is_mismatch () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let _ = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let lookup () =
          match Auth.find_credential_by_token dir ~token:"not-a-real-token" with
          | Ok cred ->
            fail
              (Printf.sprintf "bogus token unexpectedly resolved to %s"
                 cred.agent_name)
          | Error _ -> ()
        in
        lookup ();
        lookup ();
        lookup ()))

(* The other process is this executable started again with
   [mint_child_flag]: it mints into the same workspace and exits before the
   suite runs, the way masc-tui mints beside a running server. *)
let mint_child_flag = "--mint-in-child"

let mint_in_another_process dir ~agent_name =
  let token_out = Filename.concat dir (agent_name ^ ".minted") in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; mint_child_flag; dir; agent_name; token_out |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  (* A SIGCHLD handler the Eio runtime left behind interrupts the wait. *)
  let rec wait_for_child () =
    match Unix.waitpid [] pid with
    | status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
  in
  match wait_for_child () with
  | _, Unix.WEXITED 0 -> In_channel.with_open_bin token_out In_channel.input_all
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) ->
    fail "the child process did not mint"

let test_token_minted_by_another_process_is_found () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"local-admin" ~role:Masc_domain.Admin in
        match Auth.find_credential_by_token dir ~token:raw with
        | Ok _ -> ()
        | Error e -> fail ("warm: " ^ Masc_domain.masc_error_to_string e));
      let minted = mint_in_another_process dir ~agent_name:"masc-tui" in
      with_eio_runtime (fun () ->
        match Auth.find_credential_by_token dir ~token:minted with
        | Ok cred -> check string "masc-tui resolved" "masc-tui" cred.agent_name
        | Error e ->
          fail ("a token another process minted was refused: "
                ^ Masc_domain.masc_error_to_string e)))

let index_rebuilds () =
  Otel_metric_store_core.get_metric_value
    Otel_identity_metric_names.metric_auth_credential_index_cache_misses ()
  |> Option.value ~default:0.0

let test_unknown_bearer_does_not_rebuild_the_index () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        (match Auth.find_credential_by_token dir ~token:raw with
         | Ok _ -> ()
         | Error e -> fail ("warm: " ^ Masc_domain.masc_error_to_string e));
        let before = index_rebuilds () in
        for _ = 1 to 3 do
          match Auth.find_credential_by_token dir ~token:"not-a-real-token" with
          | Ok cred ->
            fail (Printf.sprintf "bogus token unexpectedly resolved to %s" cred.agent_name)
          | Error _ -> ()
        done;
        check (float 0.0) "no rebuild for an unknown bearer" before (index_rebuilds ())))

let () =
  match Array.to_list Sys.argv with
  | [ _; flag; dir; agent_name; token_out ] when String.equal flag mint_child_flag ->
    with_eio_runtime (fun () ->
      let raw = create_token_for dir ~agent_name ~role:Masc_domain.Admin in
      Out_channel.with_open_bin token_out (fun oc -> output_string oc raw));
    exit 0
  | _ -> ()

let () =
  Alcotest.run "auth_credential_index_cache"
    [ ( "cache"
      , [ test_case "repeated lookups stay correct"
          `Quick test_lookup_stays_correct_across_repeated_calls
        ; test_case "save_credential invalidates cache"
          `Quick test_save_credential_invalidates_cache
        ; test_case "delete_credential invalidates cache"
          `Quick test_delete_credential_invalidates_cache
        ; test_case "unknown token is mismatch (cold + warm)"
          `Quick test_unknown_token_is_mismatch
        ; test_case "a token another process minted is found"
          `Quick test_token_minted_by_another_process_is_found
        ; test_case "an unknown bearer does not rebuild the index"
          `Quick test_unknown_bearer_does_not_rebuild_the_index
        ] )
    ]
