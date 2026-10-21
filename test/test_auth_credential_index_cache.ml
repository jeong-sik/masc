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
    - Requests that miss together rebuild the index once, not once each.
    - An index listed while the directory's last change is inside one file
      time step is rebuilt once after the step, because a second write in
      that step may have left the directory's times unchanged. The TTL
      still caps how long any index serves.

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

(* Requests that miss together queue on the credential transaction; only
   the first may re-read the credentials. *)
let test_requests_that_miss_together_rebuild_once () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let before = index_rebuilds () in
        Eio.Fiber.List.iter
          (fun () ->
            match Auth.find_credential_by_token dir ~token:raw with
            | Ok _ -> ()
            | Error e -> fail ("concurrent lookup: " ^ Masc_domain.masc_error_to_string e))
          (List.init 5 (fun _ -> ()));
        check (float 0.0) "one rebuild" (before +. 1.0) (index_rebuilds ())))

(* Real clock and file times: the first lookup follows the write within the
   same step, the second waits the step out, and the index it lists outlives
   a further step because nothing changed after its step. *)
let test_index_listed_inside_a_time_step_is_rebuilt_once_the_step_ends () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let raw = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let lookup label =
          match Auth.find_credential_by_token dir ~token:raw with
          | Ok _ -> ()
          | Error e -> fail (label ^ ": " ^ Masc_domain.masc_error_to_string e)
        in
        let before = index_rebuilds () in
        lookup "inside the step";
        lookup "inside the step, again";
        check (float 0.0) "the step's index serves while the step lasts"
          (before +. 1.0) (index_rebuilds ());
        let stats = Unix.stat (Common.agents_dir_from_base_path ~base_path:dir) in
        let step_end =
          Float.max stats.Unix.st_mtime stats.Unix.st_ctime
          +. Auth.Credential_index_expiry_for_testing.time_step_sec
        in
        let step = Auth.Credential_index_expiry_for_testing.time_step_sec in
        Unix.sleepf (Float.max 0.0 (step_end -. Unix.gettimeofday ()) +. 0.1);
        lookup "after the step";
        lookup "after the step, again";
        check (float 0.0) "one rebuild after the step, then the index serves"
          (before +. 2.0) (index_rebuilds ());
        Unix.sleepf (step +. 0.1);
        lookup "a step later";
        check (float 0.0) "an index listed after the step outlives the next step"
          (before +. 2.0) (index_rebuilds ())))

let test_time_step_never_outlasts_the_ttl () =
  let module Expiry = Auth.Credential_index_expiry_for_testing in
  let stamped_at = 1_000_000.0 in
  let expires_at dir_changed_at =
    Expiry.expires_at ~stamped_at ~dir_changed_at ~has_unreadable:false
  in
  check (float 0.0) "listed after the step: the TTL"
    (stamped_at +. Expiry.ttl_sec)
    (expires_at (Some (stamped_at -. Expiry.time_step_sec -. 1.0)));
  check (float 0.0) "listed inside the step: the step's end"
    (stamped_at -. 0.5 +. Expiry.time_step_sec)
    (expires_at (Some (stamped_at -. 0.5)));
  check (float 0.0) "listed exactly at the step's end: the TTL"
    (stamped_at +. Expiry.ttl_sec)
    (expires_at (Some (stamped_at -. Expiry.time_step_sec)));
  check (float 0.0) "a file clock ahead by less than the TTL: the step's end"
    (stamped_at +. 10.0 +. Expiry.time_step_sec)
    (expires_at (Some (stamped_at +. 10.0)));
  check (float 0.0) "a file clock far ahead: still the TTL"
    (stamped_at +. Expiry.ttl_sec) (expires_at (Some (stamped_at +. 3600.0)));
  check (float 0.0) "no agents directory: the TTL"
    (stamped_at +. Expiry.ttl_sec) (expires_at None)

let test_unreadable_index_serves_only_the_retry_bound () =
  let module Expiry = Auth.Credential_index_expiry_for_testing in
  let stamped_at = 1_000_000.0 in
  let expires_at dir_changed_at =
    Expiry.expires_at ~stamped_at ~dir_changed_at ~has_unreadable:true
  in
  check (float 0.0) "listed after the step: the retry bound, not the TTL"
    (stamped_at +. Expiry.unreadable_retry_sec)
    (expires_at (Some (stamped_at -. Expiry.time_step_sec -. 1.0)));
  check (float 0.0) "no agents directory: the retry bound"
    (stamped_at +. Expiry.unreadable_retry_sec) (expires_at None);
  check bool "the retry bound is shorter than the TTL" true
    (Expiry.unreadable_retry_sec < Expiry.ttl_sec);
  check (float 0.0) "listed inside the step: the step's end when it comes first"
    (Float.min
       (stamped_at -. 0.5 +. Expiry.time_step_sec)
       (stamped_at +. Expiry.unreadable_retry_sec))
    (expires_at (Some (stamped_at -. 0.5)))

(* A credential file the server cannot read, for a moment or for good, says
   nothing about whether that credential exists, and it says nothing about any
   other credential. A mode-0 file stands in for a failed open (ENFILE in
   production), which changes neither the directory's times nor its listing,
   so the stamp cannot save a cached index. *)
let is_read_failure = function
  | Error (Masc_domain.System (Masc_domain.System_error.IoError _)) -> true
  | Ok _
  | Error
      (Masc_domain.System
         (Masc_domain.System_error.NotInitialized
         | Masc_domain.System_error.ValidationError _
         | Masc_domain.System_error.LockContention _)
      | Masc_domain.Task _
      | Masc_domain.Agent _
      | Masc_domain.Auth _) -> false

let is_mismatch result = Result.is_error result && not (is_read_failure result)

(* Mode-0 beta beside readable alpha. Root opens a mode-0 file, so there is
   nothing to make unreadable. *)
let with_unreadable_beta f =
  if Unix.geteuid () = 0 then skip ();
  let dir = setup_test_workspace () in
  let beta_file = Auth.credential_file dir "beta" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod beta_file 0o600 with Unix.Unix_error _ -> ());
      cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let alpha = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let beta = create_token_for dir ~agent_name:"beta" ~role:Masc_domain.Worker in
        Unix.chmod beta_file 0o000;
        f ~dir ~beta_file ~alpha ~beta))

let test_unreadable_credential_harms_only_its_own_token () =
  with_unreadable_beta (fun ~dir ~beta_file:_ ~alpha ~beta ->
    (match Auth.find_credential_by_token dir ~token:alpha with
     | Ok cred -> check string "the readable credential still resolves" "alpha" cred.agent_name
     | Error e ->
       fail ("a readable credential was refused for another file's sake: "
             ^ Masc_domain.masc_error_to_string e));
    check bool "the unreadable credential's token is a read failure, not a mismatch"
      true (is_read_failure (Auth.find_credential_by_token dir ~token:beta));
    check bool "a token the index does not hold is a read failure while a file is unreadable"
      true (is_read_failure (Auth.find_credential_by_token dir ~token:"not-a-real-token")))

(* A revoked token must not be accepted because another credential is
   unreadable: the index holds only what this rebuild read. *)
let test_revoked_token_is_not_accepted_beside_an_unreadable_credential () =
  with_unreadable_beta (fun ~dir ~beta_file:_ ~alpha ~beta:_ ->
    let gamma = create_token_for dir ~agent_name:"gamma" ~role:Masc_domain.Worker in
    (match Auth.find_credential_by_token dir ~token:gamma with
     | Ok _ -> ()
     | Error e -> fail ("gamma warm: " ^ Masc_domain.masc_error_to_string e));
    Auth.delete_credential dir "gamma";
    (match Auth.find_credential_by_token dir ~token:gamma with
     | Ok cred ->
       fail (Printf.sprintf "a revoked token resolved to %s" cred.agent_name)
     | Error _ -> ());
    match Auth.find_credential_by_token dir ~token:alpha with
    | Ok cred -> check string "alpha still resolves" "alpha" cred.agent_name
    | Error e -> fail ("alpha: " ^ Masc_domain.masc_error_to_string e))

let test_a_rebuild_that_reads_every_file_answers_mismatch_again () =
  with_unreadable_beta (fun ~dir ~beta_file ~alpha:_ ~beta ->
    check bool "unreadable: a read failure" true
      (is_read_failure (Auth.find_credential_by_token dir ~token:beta));
    Unix.chmod beta_file 0o600;
    (* A write through this module drops the cached index, which stands in
       for the retry bound ending. *)
    let _ = create_token_for dir ~agent_name:"gamma" ~role:Masc_domain.Worker in
    (match Auth.find_credential_by_token dir ~token:beta with
     | Ok cred -> check string "beta resolves once its file reads again" "beta" cred.agent_name
     | Error e ->
       fail ("a token stayed refused after its file read again: "
             ^ Masc_domain.masc_error_to_string e));
    check bool "every file read: an unknown token is a mismatch, not a read failure" true
      (is_mismatch (Auth.find_credential_by_token dir ~token:"not-a-real-token")))

(* No write touches the directory, and the index is listed after its time
   step, so only the retry bound can end the index that left beta out: the
   TTL is 60 s. *)
let test_unreadable_credential_recovers_after_the_retry_bound () =
  with_unreadable_beta (fun ~dir ~beta_file ~alpha:_ ~beta ->
    Unix.sleepf (Auth.Credential_index_expiry_for_testing.time_step_sec +. 0.1);
    check bool "unreadable: a read failure" true
      (is_read_failure (Auth.find_credential_by_token dir ~token:beta));
    Unix.chmod beta_file 0o600;
    Unix.sleepf (Auth.Credential_index_expiry_for_testing.unreadable_retry_sec +. 0.1);
    match Auth.find_credential_by_token dir ~token:beta with
    | Ok cred -> check string "beta resolves without a write" "beta" cred.agent_name
    | Error e ->
      fail ("a token stayed refused past the retry bound: "
            ^ Masc_domain.masc_error_to_string e))

(* The live-disk recheck behind the token lookup answers three ways: a file
   that still holds the credential is [Ok true], one that holds something
   else or is gone is [Ok false], and a file that cannot be read is [Error].
   Only [Ok false] may surface as "changed" (401); an unreadable match must
   stay a read failure (503), and it outranks a differing match because the
   token may belong to the file that could not be read. A mode-0 file stands
   in for the failed open. Root opens a mode-0 file, so there is nothing to
   make unreadable.

   Two files, not one: the differing match must come from a file that still
   reads (rotated alpha beside mode-0 beta). A rotated record of the
   unreadable file itself would error on the first element either way, and
   the outranking assertion could not fail. *)
let test_live_disk_check_reports_unreadable_as_error () =
  if Unix.geteuid () = 0 then skip ();
  let dir = setup_test_workspace () in
  let beta_file = Auth.credential_file dir "beta" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod beta_file 0o600 with Unix.Unix_error _ -> ());
      cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let alpha = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let beta = create_token_for dir ~agent_name:"beta" ~role:Masc_domain.Worker in
        let resolve token name =
          match Auth.find_credential_by_token dir ~token with
          | Ok cred -> cred
          | Error e -> fail (name ^ " warm: " ^ Masc_domain.masc_error_to_string e)
        in
        let alpha_cred = resolve alpha "alpha" in
        let beta_cred = resolve beta "beta" in
        let rotated_alpha =
          { alpha_cred with Masc_domain.token = "rotated-credential-material" }
        in
        let matches = Auth_credential_token.For_testing.credential_matches_live_disk in
        let hold = Auth_credential_token.For_testing.live_matches_hold in
        check bool "an unchanged credential still matches" true
          (matches dir alpha_cred = Ok true);
        check bool "a rotated credential no longer matches" true
          (matches dir rotated_alpha = Ok false);
        check bool "every match holding is Ok true" true
          (hold dir [ alpha_cred ] = Ok true);
        check bool "a differing match without a failure is Ok false" true
          (hold dir [ rotated_alpha ] = Ok false);
        Unix.chmod beta_file 0o000;
        (match matches dir beta_cred with
         | Error (Masc_domain.System _) -> ()
         | Ok _ -> fail "an unreadable credential matched or differed instead of erroring"
         | Error _ -> fail "an unreadable credential answered a non-system error");
        check bool "an unreadable match outranks a differing one" true
          (Result.is_error (hold dir [ rotated_alpha; beta_cred ]));
        check bool "order does not matter: unreadable still outranks" true
          (Result.is_error (hold dir [ beta_cred; rotated_alpha ]))))

(* #44247: the credential a caller read first can be stale by the time it is
   checked. The owner's file decides. The same token with a role or expiry an
   operator edited meanwhile is the same credential, answered with the file's
   current values; a token replaced or removed is [InvalidToken]. *)
let test_canonical_credential_follows_the_owners_file () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let token = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let snapshot =
          match Auth.find_credential_by_token dir ~token with
          | Ok cred -> cred
          | Error e -> fail ("alpha did not resolve: " ^ Masc_domain.masc_error_to_string e)
        in
        let canonical = Auth_credential_token.For_testing.canonical_credential_of_token in
        let invalid label = function
          | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
          | Error e -> fail (label ^ ": " ^ Masc_domain.masc_error_to_string e)
          | Ok _ -> fail (label ^ ": accepted") in
        let edited = { snapshot with Masc_domain.role = Masc_domain.Admin; expires_at = None } in
        Auth.save_credential dir edited;
        (match canonical dir snapshot with
         | Ok fresh ->
           check bool "the file's current role is answered" true
             (fresh.Masc_domain.role = Masc_domain.Admin);
           check (option string) "the file's current expiry is answered" None
             fresh.Masc_domain.expires_at
         | Error e ->
           fail ("a role and expiry edit was refused: " ^ Masc_domain.masc_error_to_string e));
        (match Auth.verify_token dir ~agent_name:"alpha" ~token with
         | Ok cred ->
           check bool "verify_token answers the edited role" true
             (cred.Masc_domain.role = Masc_domain.Admin)
         | Error e ->
           fail ("verify_token refused an edited credential: " ^ Masc_domain.masc_error_to_string e));
        Auth.save_credential dir { edited with Masc_domain.token = "rotated-credential-material" };
        invalid "a replaced token" (canonical dir snapshot);
        invalid "verify_token with a replaced token" (Auth.verify_token dir ~agent_name:"alpha" ~token);
        Auth.delete_credential dir "alpha";
        invalid "a removed credential" (canonical dir snapshot)))

(* The same helper behind a stale read. A stored alias leads to the id-named
   payload; the owner's named file is then replaced by hand with the same
   token and a lower role. The old comparison refused that answer outright. The
   owner's file decides, so the alias answers the lower role. *)
let test_a_stale_alias_read_answers_the_owners_current_role () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let name = "operator" in
        let token, worker =
          match Auth.ensure_keeper_credential dir ~agent_name:name with
          | Ok pair -> pair
          | Error e -> fail ("keeper credential: " ^ Masc_domain.masc_error_to_string e)
        in
        let admin = { worker with Masc_domain.role = Masc_domain.Admin } in
        Auth.save_credential dir admin;
        (match
           Auth.ensure_credential_alias dir ~canonical_name:name ~alias_name:"short-operator"
         with
         | Ok () -> ()
         | Error e -> fail ("alias: " ^ Masc_domain.masc_error_to_string e));
        (match Auth.verify_token dir ~agent_name:"short-operator" ~token with
         | Ok cred ->
           check bool "the alias answers Admin while the owner's file says Admin" true
             (cred.Masc_domain.role = Masc_domain.Admin)
         | Error e -> fail ("alias refused before the edit: " ^ Masc_domain.masc_error_to_string e));
        let demoted =
          { admin with Masc_domain.id = None; role = Masc_domain.Worker }
        in
        Auth.save_private_text_file (Auth.credential_file dir name)
          (Masc_domain.agent_credential_to_yojson demoted |> Yojson.Safe.to_string);
        match Auth.verify_token dir ~agent_name:"short-operator" ~token with
        | Ok cred ->
          check bool "the alias answers the owner's current role" true
            (cred.Masc_domain.role = Masc_domain.Worker)
        | Error e ->
          fail ("a demoted owner file refused its own token: "
                ^ Masc_domain.masc_error_to_string e)))

(* An owner file that cannot be read is a read failure, not a verdict on the
   token: [canonical_credential_of_token] must pass the error through. Root
   opens a mode-0 file, so there is nothing to make unreadable. *)
let test_canonical_credential_reports_unreadable_as_error () =
  if Unix.geteuid () = 0 then skip ();
  let dir = setup_test_workspace () in
  let alpha_file = Auth.credential_file dir "alpha" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod alpha_file 0o600 with Unix.Unix_error _ -> ());
      cleanup_test_workspace dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let token = create_token_for dir ~agent_name:"alpha" ~role:Masc_domain.Worker in
        let snapshot =
          match Auth.find_credential_by_token dir ~token with
          | Ok cred -> cred
          | Error e -> fail ("alpha did not resolve: " ^ Masc_domain.masc_error_to_string e)
        in
        Unix.chmod alpha_file 0o000;
        match Auth_credential_token.For_testing.canonical_credential_of_token dir snapshot with
        | Error (Masc_domain.System _) -> ()
        | Error _ -> fail "an unreadable owner file answered a non-system error"
        | Ok _ -> fail "an unreadable owner file was accepted"))

(* [verify_token] reads the named file, not the token index: an unreadable
   file is a read failure (503 downstream), not an undecodable credential
   (401). *)
let test_verify_token_reports_unreadable_as_read_failure () =
  with_unreadable_beta (fun ~dir ~beta_file:_ ~alpha ~beta ->
    (match Auth.verify_token dir ~agent_name:"alpha" ~token:alpha with
     | Ok cred ->
       check string "the readable credential still verifies" "alpha" cred.agent_name
     | Error e ->
       fail ("a readable credential failed to verify: "
             ^ Masc_domain.masc_error_to_string e));
    check bool "verify_token on an unreadable credential is a read failure, not InvalidToken"
      true (is_read_failure (Auth.verify_token dir ~agent_name:"beta" ~token:beta)))

(* A miss answered as a read failure because some file was unreadable is
   counted apart, so a wrong token's 503 during an unreadable window does
   not mix into the 503s that name a genuinely failing store. *)
let test_unreadable_window_miss_is_counted_apart () =
  with_unreadable_beta (fun ~dir ~beta_file:_ ~alpha:_ ~beta:_ ->
    let metric = Masc.Otel_metric_store.metric_auth_credential_unreadable_index_miss in
    check string "unreadable-miss metric name"
      "masc_auth_credential_unreadable_index_miss_total" metric;
    let before = Masc.Otel_metric_store.metric_total metric in
    (match Auth.find_credential_by_token dir ~token:"not-a-real-token" with
     | Error _ -> ()
     | Ok cred -> fail ("an unknown token resolved to " ^ cred.agent_name));
    check (float 0.0001) "one miss during the window counts once"
      (before +. 1.) (Masc.Otel_metric_store.metric_total metric))

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
        ; test_case "requests that miss together rebuild once"
          `Quick test_requests_that_miss_together_rebuild_once
        ; test_case "an index listed inside a time step is rebuilt once the step ends"
          `Slow test_index_listed_inside_a_time_step_is_rebuilt_once_the_step_ends
        ; test_case "a time step never outlasts the TTL"
          `Quick test_time_step_never_outlasts_the_ttl
        ; test_case "an unreadable index serves only the retry bound"
          `Quick test_unreadable_index_serves_only_the_retry_bound
        ; test_case "an unreadable credential harms only its own token"
          `Quick test_unreadable_credential_harms_only_its_own_token
        ; test_case "a revoked token is not accepted beside an unreadable credential"
          `Quick test_revoked_token_is_not_accepted_beside_an_unreadable_credential
        ; test_case "a rebuild that reads every file answers mismatch again"
          `Quick test_a_rebuild_that_reads_every_file_answers_mismatch_again
        ; test_case "an unreadable credential recovers after the retry bound"
          `Slow test_unreadable_credential_recovers_after_the_retry_bound
        ; test_case "live-disk check reports unreadable as error"
          `Quick test_live_disk_check_reports_unreadable_as_error
        ; test_case "canonical credential follows the owner's file"
          `Quick test_canonical_credential_follows_the_owners_file
        ; test_case "a stale alias read answers the owner's current role"
          `Quick test_a_stale_alias_read_answers_the_owners_current_role
        ; test_case "canonical credential reports unreadable as error"
          `Quick test_canonical_credential_reports_unreadable_as_error
        ; test_case "verify_token reports unreadable as read failure"
          `Quick test_verify_token_reports_unreadable_as_read_failure
        ; test_case "unreadable-window miss is counted apart"
          `Quick test_unreadable_window_miss_is_counted_apart
        ] )
    ]
