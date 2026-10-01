(* The real prune and real credential publishers contend on the same durable
   transaction. Admission barriers fix order without sleeps or stale lists. *)
open Alcotest
module Prune = Auth_token_prune

let () = Mirage_crypto_rng_unix.use_default ()

let auth_ok = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let with_workspace_at base_path f =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ()) (fun () ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    f base_path)

let with_workspace f =
  with_workspace_at (Filename.temp_dir "token-prune-transaction-" "") f

(* A fixed clock leaves issuance's live bearers far from the expired fixture. *)
let now = 1_735_689_600.
let expired = "2000-01-01T00:00:00Z"

let mint base_path name role = auth_ok (Auth.create_token base_path ~agent_name:name ~role)

let make_expired base_path name =
  let token, credential = mint base_path name Masc_domain.Worker in
  Auth.save_credential base_path { credential with expires_at = Some expired };
  token

let prune ?(mode = Prune.Retire) base_path = Prune.run ~base_path ~now ~mode

let lock_path base_path = Filename.concat (Unix.realpath (Auth.auth_dir base_path)) ".credentials.lock"

let await_waiter base_path completed =
  let rec wait () =
    if File_lock_eio.For_testing.holders_and_waiters ~lock_path:(lock_path base_path) >= 2 then ()
    else match Eio.Promise.peek completed with
      | Some _ -> fail "the competing operation bypassed the credential transaction"
      | None -> Eio.Fiber.yield (); wait () in
  wait ()

let interleave ?(while_waiting = fun () -> ()) base_path first second =
  let admitted, signal_admitted = Eio.Promise.create () in
  let continue, signal_continue = Eio.Promise.create () in
  let first_done, signal_first_done = Eio.Promise.create () in
  let second_done, signal_second_done = Eio.Promise.create () in
  let armed = Atomic.make true in
  let previous = Atomic.get File_lock_eio.on_lock_attempt_fn in
  Atomic.set File_lock_eio.on_lock_attempt_fn
    (fun ~caller ~retries ~elapsed_s ~outcome ->
      previous ~caller ~retries ~elapsed_s ~outcome;
      if String.equal caller "File_lock_eio.durable" && Atomic.compare_and_set armed true false then (
        Eio.Promise.resolve signal_admitted ();
        Eio.Promise.await continue));
  Fun.protect ~finally:(fun () -> Atomic.set File_lock_eio.on_lock_attempt_fn previous)
    (fun () -> Eio.Switch.run @@ fun sw ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_first_done (first ()));
      let rec await_first () =
        match Eio.Promise.peek admitted, Eio.Promise.peek first_done with
        | Some (), _ -> ()
        | None, Some _ -> fail "the first operation bypassed the credential transaction"
        | None, None -> Eio.Fiber.yield (); await_first () in
      await_first ();
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_second_done (second ()));
      await_waiter base_path second_done;
      while_waiting ();
      Eio.Promise.resolve signal_continue ();
      Eio.Promise.await first_done, Eio.Promise.await second_done)

let names entries = List.map (fun (entry : Prune.entry) -> entry.agent_name) entries
let check_live base_path token =
  let credential = auth_ok (Auth.find_static_credential_by_token base_path ~token) in
  check string "renewed bearer keeps its role" "admin" (Masc_domain.agent_role_to_string credential.role)

let test_renewal_before_prune () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "player" in
  let (token, _), result = interleave base_path
      (fun () -> mint base_path "player" Masc_domain.Admin) (fun () -> prune base_path) in
  check (list string) "the current Admin is not an expired candidate" [] (names (auth_ok result));
  check_live base_path token

let write_stub base_path name target =
  Auth.save_private_text_file (Auth.credential_file base_path name)
    (Yojson.Safe.to_string (`Assoc [ "redirect_to", `String target ]))

let test_orphan_renewal_before_prune () =
  with_workspace @@ fun base_path ->
  write_stub base_path "player" "absent.json";
  let (token, _), result = interleave base_path
      (fun () -> mint base_path "player" Masc_domain.Admin) (fun () -> prune base_path) in
  check (list string) "a replacement credential is not an orphan" [] (names (auth_ok result));
  check_live base_path token

let test_prune_before_renewal () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "player" in
  let result, (token, _) = interleave base_path (fun () -> prune base_path)
      (fun () -> mint base_path "player" Masc_domain.Admin) in
  (match auth_ok result with
   | [ { Prune.agent_name = "player"; reason = Prune.Expired; outcome = Prune.Retired } ] -> ()
   | _ -> fail "the admitted prune must retire the old expired credential");
  check_live base_path token

let test_preview_preserves_files () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "player" in
  write_stub base_path "orphan" "absent.json";
  let paths = [ Auth.credential_file base_path "player"; Auth.credential_file base_path "orphan" ] in
  let contents () = List.map (fun path -> In_channel.with_open_bin path In_channel.input_all) paths in
  let before = contents () in
  let result = auth_ok (prune ~mode:Prune.Preview base_path) in
  check (list string) "preview identifies both reasons" [ "player"; "orphan" ] (names result);
  check bool "every preview is explicitly without effect" true
    (List.for_all (fun (entry : Prune.entry) -> entry.outcome = Prune.Would_retire) result);
  check (list string) "preview preserves exact files" before (contents ())

let test_uuid_cleanup_and_cache () =
  with_workspace @@ fun base_path ->
  let token, credential = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"player") in
  let uuid = match credential.id with
    | Some id -> Auth.credential_file base_path (Masc_domain.Credential_id.to_string id)
    | None -> fail "fixture needs a UUID-backed credential" in
  let _cached_credential = auth_ok (Auth.find_static_credential_by_token base_path ~token) in
  Auth.save_credential base_path { credential with expires_at = Some expired };
  check bool "the old bearer is expired before pruning" true
    (Result.is_error (Auth.find_static_credential_by_token base_path ~token));
  write_stub base_path "orphan" "absent.json";
  let result = auth_ok (prune base_path) in
  check (list string) "one canonical credential and one orphan are retired" [ "player"; "orphan" ] (names result);
  check bool "all deletions completed" true
    (List.for_all (fun (entry : Prune.entry) -> entry.outcome = Prune.Retired) result);
  List.iter (fun path -> check bool "credential artifact removed" false (Sys.file_exists path))
    [ uuid; Auth.credential_file base_path "player"; Auth.raw_token_file base_path "player";
      Auth.credential_file base_path "orphan" ];
  check bool "cached bearer cannot authenticate after retirement" true
    (Result.is_error (Auth.find_static_credential_by_token base_path ~token));
  let fresh, _ = mint base_path "player" Masc_domain.Admin in
  check_live base_path fresh;
  check bool "old bearer remains invalid after replacement" true
    (Result.is_error (Auth.find_static_credential_by_token base_path ~token))

let test_read_failure_aborts_before_any_delete () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "aaa" in
  let path = Auth.credential_file base_path "zzz" in
  Unix.mkdir path 0o700;
  (match prune base_path with Error _ -> () | Ok _ -> fail "a credential read error must abort planning");
  check bool "an earlier expired candidate was not removed" true
    (Sys.file_exists (Auth.credential_file base_path "aaa"))

(* A real FIFO with no writer made the old prune block in open while holding
   the credential transaction. Isolate the entire product call in a child;
   the parent deadline guards CI even when the regression is reintroduced. *)
let test_fifo_refusal_releases_publishers () =
  let base_path = Filename.temp_dir "token-prune-fifo-" "" in
  let finished_read, finished_write = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
      Unix.close finished_read;
      (try
         with_workspace_at base_path (fun base_path ->
           let _expired_token = make_expired base_path "aaa" in
           let canary = Auth.credential_file base_path "aaa" in
           let before = In_channel.with_open_bin canary In_channel.input_all in
           let fifo = Auth.credential_file base_path "zzz" in
           Unix.mkfifo fifo 0o600;
           List.iter (fun mode ->
             match prune ~mode base_path with
             | Error _ -> ()
             | Ok _ -> fail "a FIFO credential must refuse the entire plan")
             [Prune.Preview; Prune.Retire];
           check bool "the FIFO is retained" true ((Unix.lstat fifo).st_kind = Unix.S_FIFO);
           check string "no earlier candidate was deleted" before
             (In_channel.with_open_bin canary In_channel.input_all);
           Unix.unlink fifo;
           let token, _ = mint base_path "publisher" Masc_domain.Admin in
           check_live base_path token;
           (match auth_ok (prune base_path) with
            | [{Prune.agent_name="aaa"; reason=Prune.Expired; outcome=Prune.Retired}] -> ()
            | _ -> fail "regular credential reads must still permit retirement"));
         ignore (Unix.write_substring finished_write "x" 0 1 : int);
         Unix.close finished_write;
         Unix._exit 0
       with
       | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
       | error ->
           prerr_endline (Printexc.to_string error);
           Unix.close finished_write;
           Unix._exit 2)
  | child ->
      Unix.close finished_write;
      let reaped = ref false in
      Fun.protect
        ~finally:(fun () ->
          Unix.close finished_read;
          if not !reaped then (
            (try Unix.kill child Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
            ignore (Unix.waitpid [] child));
          Fs_compat.remove_tree base_path)
        (fun () ->
          let ready, _, _ = Unix.select [finished_read] [] [] 10.0 in
          if ready = [] then fail "FIFO prune or the following publisher blocked";
          let completed = Bytes.create 1 in
          let bytes = Unix.read finished_read completed 0 1 in
          let _, status = Unix.waitpid [] child in
          reaped := true;
          check int "child completed its actual prune and publisher controls" 1 bytes;
          match status with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
              fail "isolated FIFO prune scenario failed")

let test_regular_symlink_refuses_plan () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "aaa" in
  let token, _ = mint base_path "live" Masc_domain.Admin in
  let alias = Auth.credential_file base_path "zzz" in
  Unix.symlink (Auth.credential_file base_path "live") alias;
  (match prune base_path with Error _ -> () | Ok _ -> fail "symlink JSON is not a prune read authority");
  check bool "the symlink remains" true ((Unix.lstat alias).st_kind = Unix.S_LNK);
  check bool "earlier expired credential remains" true (Sys.file_exists (Auth.credential_file base_path "aaa"));
  check_live base_path token

let test_relative_base_preserves_regular_reads () =
  let base_path = Filename.temp_dir ~temp_dir:(Sys.getcwd ()) "token-prune-relative-" "" in
  with_workspace_at base_path @@ fun base_path ->
  let _expired_token = make_expired base_path "expired" in
  let token, _ = mint base_path "live" Masc_domain.Admin in
  let relative_base = Filename.basename base_path in
  (match auth_ok (prune relative_base) with
   | [{ Prune.agent_name = "expired"; reason = Prune.Expired; outcome = Prune.Retired }] -> ()
   | _ -> fail "relative base must retire the actual expired credential");
  check bool "expired credential was removed" false
    (Sys.file_exists (Auth.credential_file base_path "expired"));
  check_live base_path token;
  let publisher, _ = mint relative_base "publisher" Masc_domain.Admin in
  check_live relative_base publisher

let test_dangling_target_is_not_orphan_authority () =
  with_workspace @@ fun base_path ->
  let target = Auth.credential_file base_path "target" in
  Unix.symlink (target ^ ".absent") target;
  write_stub base_path "orphan" "target.json";
  (match prune base_path with Error _ -> () | Ok _ -> fail "a dangling target must refuse planning");
  let _target_stat = Unix.lstat target in
  check bool "the redirect is retained" true (Sys.file_exists (Auth.credential_file base_path "orphan"))

let test_undecodable_and_mismatched_are_preserved () =
  with_workspace @@ fun base_path ->
  let path = Auth.credential_file base_path "broken" in
  Auth.save_private_text_file path "{";
  let _, credential = mint base_path "player" Masc_domain.Admin in
  let mismatch = { credential with agent_name = "other"; expires_at = Some expired } in
  Auth.save_private_text_file (Auth.credential_file base_path "player")
    (Masc_domain.agent_credential_to_yojson mismatch |> Yojson.Safe.to_string);
  check (list string) "ambiguous files provide no deletion authority" [] (names (auth_ok (prune base_path)));
  check bool "the corrupt file survives" true (Sys.file_exists path);
  check bool "the mismatched file survives" true (Sys.file_exists (Auth.credential_file base_path "player"))

let test_forged_uuid_cannot_delete_another_owners_bearer () =
  with_workspace @@ fun base_path ->
  let token, operator = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
  let operator = { operator with role = Masc_domain.Admin } in
  Auth.save_credential base_path operator;
  let id = match operator.id with Some id -> id | None -> fail "operator fixture must have a UUID" in
  let target = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
  let forged = { operator with agent_name = "player"; expires_at = Some expired;
    token = Auth.sha256_hash (Auth.generate_token ()) } in
  let forged_json = Masc_domain.agent_credential_to_yojson forged |> Yojson.Safe.to_string in
  let old_target = Auth.credential_file base_path "oldid" in
  Auth.save_private_text_file old_target forged_json;
  write_stub base_path "player" "oldid.json";
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let before = read target in
  let _cached_credential = auth_ok (Auth.find_static_credential_by_token base_path ~token) in
  (match prune base_path with
   | Error _ -> ()
   | Ok _ -> fail "a redirect that disagrees with the embedded UUID must refuse the whole plan");
  check string "unrelated live UUID bytes are preserved" before (read target);
  check string "forged target is preserved for diagnosis" forged_json (read old_target);
  check_live base_path token;
  (* A direct record cannot add another owner's UUID to its deletion set. *)
  Auth.save_private_text_file (Auth.credential_file base_path "player") forged_json;
  (match prune base_path with
   | Error _ -> ()
   | Ok _ -> fail "a direct forged embedded UUID must refuse the whole plan");
  check string "direct forgery also preserves the live UUID" before (read target);
  check_live base_path token;
  let escaped = { forged with id = Some (Masc_domain.Credential_id.of_string "../../outside") } in
  let escaped_json = Masc_domain.agent_credential_to_yojson escaped |> Yojson.Safe.to_string in
  let outside = Filename.concat (Filename.dirname (Auth.auth_dir base_path)) "outside.json" in
  Auth.save_private_text_file outside escaped_json;
  Auth.save_private_text_file (Auth.credential_file base_path "player") escaped_json;
  (match prune base_path with
   | Error _ -> ()
   | Ok _ -> fail "an embedded id outside the credential store must refuse the plan");
  check string "a traversal id cannot authorize an outside file" escaped_json (read outside);
  check_live base_path token

let test_same_owner_uuid_replacement_refuses_stale_prune () =
  with_workspace @@ fun base_path ->
  let _, current = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"keeper-current") in
  let id = match current.id with Some id -> id | None -> fail "fixture needs a UUID" in
  let target = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
  let named = Auth.credential_file base_path "keeper-current" in
  let raw = Auth.raw_token_file base_path "keeper-current" in
  (* The IDs still agree, but the named copy precedes a token/expiry renewal.
     Publication recovery may recognize this UUID; deletion must not use it. *)
  let stale = { current with expires_at = Some expired;
    token = Auth.sha256_hash (Auth.generate_token ()) } in
  Auth.save_private_text_file named
    (Masc_domain.agent_credential_to_yojson stale |> Yojson.Safe.to_string);
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let before_named, before_target, before_raw = read named, read target, read raw in
  (match prune base_path with
   | Error _ -> ()
   | Ok _ -> fail "an expired named copy must not authorize deleting its renewed UUID");
  check string "stale canonical remains diagnosable" before_named (read named);
  check string "renewed same-owner UUID survives" before_target (read target);
  check string "recoverable current raw token survives" before_raw (read raw)

let test_dangling_raw_sidecar_is_really_removed () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "player" in
  let raw = Auth.raw_token_file base_path "player" in
  Unix.symlink (raw ^ ".absent") raw;
  let _sidecar_stat = Unix.lstat raw in
  (match auth_ok (prune base_path) with
   | [ { Prune.agent_name = "player"; reason = Prune.Expired; outcome = Prune.Retired } ] -> ()
   | _ -> fail "the credential and dangling sidecar must both retire");
  (match Unix.lstat raw with
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
   | _ -> fail "Retired must remove the dangling raw token symlink")

let test_partial_delete_is_failed_and_later_entries_continue () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "aaa" in
  let _other_expired_token = make_expired base_path "bbb" in
  let raw = Auth.raw_token_file base_path "aaa" in
  Unix.mkdir raw 0o700;
  let result = auth_ok (prune base_path) in
  (match result with
   | [ { Prune.agent_name = "aaa"; reason = Prune.Expired; outcome = Prune.Failed _ };
       { Prune.agent_name = "bbb"; reason = Prune.Expired; outcome = Prune.Retired } ] -> ()
   | _ -> fail "partial deletion must report Failed and a later successful retirement separately");
  check bool "failed cleanup retains canonical retry authority" true
    (Sys.file_exists (Auth.credential_file base_path "aaa"));
  check bool "the unremoved sidecar is retained" true (Sys.file_exists raw);
  check bool "the later entry is removed" false (Sys.file_exists (Auth.credential_file base_path "bbb"));
  Unix.rmdir raw;
  (match auth_ok (prune base_path) with
   | [{ Prune.agent_name = "aaa"; reason = Prune.Expired; outcome = Prune.Retired }] -> ()
   | _ -> fail "repairing the sidecar problem must let the next prune finish cleanup")

let test_absent_preview_creates_nothing () =
  with_workspace @@ fun base_path ->
  let absent = Filename.concat base_path "untouched-workspace" in
  check (list string) "absent preview is empty" []
    (names (auth_ok (prune ~mode:Prune.Preview absent)));
  check bool "preview does not create the workspace or auth lock" false (Sys.file_exists absent)

let test_expired_uuid_retires_validated_aliases () =
  with_workspace @@ fun base_path ->
  let _, credential = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"keeper-canonical") in
  Auth.save_credential base_path { credential with expires_at = Some expired };
  List.iter (fun alias_name ->
    (* A real independently minted Keeper has a raw bearer before its named
       credential is repointed to the canonical UUID. *)
    let token, _ = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:alias_name) in
    check (option string) "minted alias owns a raw sidecar" (Some token)
      (Auth.load_raw_token base_path ~agent_name:alias_name);
    auth_ok (Auth.ensure_credential_alias base_path
      ~canonical_name:"keeper-canonical" ~alias_name)) ["keeper-short"; "keeper-other"];
  (match auth_ok (prune base_path) with
   | [{ Prune.agent_name = "keeper-canonical"; reason = Prune.Expired; outcome = Prune.Retired }] -> ()
   | _ -> fail "the canonical credential and aliases must retire in one entry");
  List.iter (fun name ->
    check bool "validated alias was removed in the same prune" false
      (Sys.file_exists (Auth.credential_file base_path name));
    check bool "raw bearer was removed in the same prune" false
      (Sys.file_exists (Auth.raw_token_file base_path name)))
    ["keeper-canonical"; "keeper-short"; "keeper-other"];
  check (list string) "no orphan remains for a second prune" [] (names (auth_ok (prune base_path)))

let test_alias_raw_cleanup_failure_retains_retry_authority () =
  with_workspace @@ fun base_path ->
  let _, credential = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"aaa") in
  let _, _ = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"alias") in
  auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:"aaa" ~alias_name:"alias");
  Auth.save_credential base_path { credential with expires_at = Some expired };
  let _later = make_expired base_path "bbb" in
  let canonical = Auth.credential_file base_path "aaa" in
  let alias = Auth.credential_file base_path "alias" in
  let before_canonical = read canonical and before_alias = read alias in
  let raw = Auth.raw_token_file base_path "alias" in
  Unix.unlink raw;
  Unix.mkdir raw 0o700;
  (match auth_ok (prune base_path) with
   | [{Prune.agent_name="aaa"; outcome=Prune.Failed _; _};
      {Prune.agent_name="bbb"; outcome=Prune.Retired; _}] -> ()
   | _ -> fail "alias raw cleanup failure must not report successful canonical retirement");
  check string "canonical owner remains for retry" before_canonical (read canonical);
  check string "alias stays discoverable until its raw bearer retires" before_alias (read alias);
  check bool "failed raw cleanup retains the obstructing path" true (Sys.file_exists raw);
  Unix.rmdir raw;
  (match auth_ok (prune base_path) with
   | [{Prune.agent_name="aaa"; outcome=Prune.Retired; _}] -> ()
   | _ -> fail "repairing alias raw cleanup must allow one complete retirement");
  List.iter (fun path -> check bool "retry removes every admitted alias artifact" false
      (Sys.file_exists path)) [canonical; alias; raw]

let test_normalized_canonical_survives_uuid_cleanup_failure () =
  with_workspace @@ fun base_path ->
  let _, credential = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"Alice") in
  let credential = { credential with expires_at = Some expired } in
  Auth.save_credential base_path credential;
  let uuid = match credential.id with Some id -> Auth.credential_file base_path
      (Masc_domain.Credential_id.to_string id) | None -> fail "fixture needs UUID" in
  let before_uuid = read uuid in
  let retirement = Auth_credential_base.with_credential_transaction base_path (fun transaction ->
    let snapshot = auth_ok (Auth_credential_base.credential_prune_snapshot_in_transaction transaction) in
    let _, authority = List.find (fun (current, _) -> current.Masc_domain.agent_name = "Alice") snapshot.credentials in
    Unix.unlink uuid; Unix.mkdir uuid 0o700;
    Auth_credential_base.retire_prune_credential_in_transaction transaction authority) |> auth_ok in
  check bool "UUID failure is explicit" true (Result.is_error retirement);
  check bool "normalized canonical remains retryable" true
    (Sys.file_exists (Auth.credential_file base_path "Alice"));
  Unix.rmdir uuid; Auth.save_private_text_file uuid before_uuid;
  (match auth_ok (prune base_path) with
   | [{ Prune.agent_name = "Alice"; outcome = Prune.Retired; _ }] -> ()
   | _ -> fail "the restored target must finish under the retained canonical owner")

let test_raw_publication_waits_for_prune () =
  with_workspace @@ fun base_path ->
  let old_token, credential = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"keeper") in
  Auth.save_credential base_path { credential with expires_at = Some expired };
  let result, renewed = interleave base_path
      ~while_waiting:(fun () -> check (option string)
        "a publisher waiting for prune cannot replace its sidecar" (Some old_token)
        (Auth.load_raw_token base_path ~agent_name:"keeper"))
      (fun () -> prune base_path)
      (fun () -> Auth.ensure_keeper_credential base_path ~agent_name:"keeper") in
  let _retired = auth_ok result in
  let token, _ = auth_ok renewed in
  check (option string) "the successful publisher retains its new bearer" (Some token)
    (Auth.load_raw_token base_path ~agent_name:"keeper");
  let current = auth_ok (Auth.verify_token base_path ~agent_name:"keeper" ~token) in
  check string "new credential still authenticates" "keeper" current.agent_name

let test_failed_admission_preserves_every_file () =
  with_workspace @@ fun base_path ->
  let _expired_token = make_expired base_path "player" in
  let path = lock_path base_path in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  (match prune base_path with Error _ -> () | Ok _ -> fail "prune must refuse unavailable admission");
  check bool "failed admission runs no deletion" true (Sys.file_exists (Auth.credential_file base_path "player"))

let () =
  run "auth_token_prune_transaction"
    [ "prune",
      [ test_case "same-owner renewed UUID refuses stale deletion authority" `Quick test_same_owner_uuid_replacement_refuses_stale_prune
      ; test_case "alias raw cleanup failure retains retry authority" `Quick test_alias_raw_cleanup_failure_retains_retry_authority
      ; test_case "normalized canonical survives UUID cleanup failure" `Quick test_normalized_canonical_survives_uuid_cleanup_failure
      ; test_case "renewal before prune preserves the current Admin" `Quick test_renewal_before_prune
      ; test_case "orphan replacement before prune preserves its bearer" `Quick test_orphan_renewal_before_prune
      ; test_case "prune finishes before the later renewal" `Quick test_prune_before_renewal
      ; test_case "preview preserves exact files" `Quick test_preview_preserves_files
      ; test_case "absent preview creates no directories or lock" `Quick test_absent_preview_creates_nothing
      ; test_case "expired UUID removes its validated aliases once" `Quick test_expired_uuid_retires_validated_aliases
      ; test_case "raw publication waits for prune admission" `Quick test_raw_publication_waits_for_prune
      ; test_case "UUID cleanup invalidates cached credentials" `Quick test_uuid_cleanup_and_cache
      ; test_case "read failure aborts the plan before deletion" `Quick test_read_failure_aborts_before_any_delete
      ; test_case "FIFO refusal releases publishers and regular reads still retire" `Quick test_fifo_refusal_releases_publishers
      ; test_case "regular symlink refuses the complete prune plan" `Quick test_regular_symlink_refuses_plan
      ; test_case "relative base retains regular reads and publisher access" `Quick test_relative_base_preserves_regular_reads
      ; test_case "a dangling target is not an orphan" `Quick test_dangling_target_is_not_orphan_authority
      ; test_case "undecodable and mismatched files are preserved" `Quick test_undecodable_and_mismatched_are_preserved
      ; test_case "forged UUID cannot remove another owner's live credential" `Quick test_forged_uuid_cannot_delete_another_owners_bearer
      ; test_case "dangling raw token symlink is actually removed" `Quick test_dangling_raw_sidecar_is_really_removed
      ; test_case "partial deletion reports failure and continues" `Quick test_partial_delete_is_failed_and_later_entries_continue
      ; test_case "failed admission preserves every file" `Quick test_failed_admission_preserves_every_file ] ]
