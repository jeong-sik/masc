(* File clients must recover the exact current bearer across issuance, ensure,
   prune, revoke and rotation. Admission barriers specify order without sleeps. *)
open Alcotest
module D = Masc_domain
module Prune = Auth_token_prune

let () = Mirage_crypto_rng_unix.use_default ()
let auth_ok = function Ok value -> value | Error error -> fail (D.masc_error_to_string error)
let with_workspace f =
  let base_path = Filename.temp_dir "file-backed-transaction-" "" in
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ()) (fun () ->
    Auth.save_auth_config base_path { D.default_auth_config with enabled = true; require_token = true };
    f base_path)

let read path = In_channel.with_open_bin path In_channel.input_all
let current base_path name = match Auth.load_credential base_path name with
  | Some credential -> credential | None -> fail "current fixture credential missing"
let raw base_path name = match Auth.load_raw_token base_path ~agent_name:name with
  | Some token -> token | None -> fail "successful file-backed credential has no raw bearer"
let check_pair base_path name =
  let token = raw base_path name in
  let credential = current base_path name in
  check bool "raw bearer and credential agree" true (String.equal (Auth.sha256_hash token) credential.token);
  check bool "file client and public Auth reader agree" true
    (Auth_login.read_persisted_token ~base_path ~agent_name:name = Some token);
  let verified = auth_ok (Auth.verify_token base_path ~agent_name:name ~token) in
  check bool "file client authenticates the exact current credential" true (verified = credential)
let check_absent base_path name =
  check bool "credential removed" true (Auth.load_credential base_path name = None);
  check bool "raw sidecar removed" true (Auth.load_raw_token base_path ~agent_name:name = None)
let ensure base_path = Auth.ensure_keeper_credential base_path ~agent_name:"keeper"
let supplied = "file-backed-fixture-supplied-token"
let set_admin base_path = Auth.save_file_backed_raw_token_credential base_path
    ~agent_name:"keeper" ~role:D.Admin ~raw_token:supplied
let revoke base_path = Auth.delete_credential base_path "keeper"
let prune base_path = Prune.run ~base_path ~now:(Time_compat.now ()) ~mode:Prune.Retire
let rotate base_path = Auth.rotate_shared_tokens base_path
let login base_path = Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
    ~agent_name:"keeper" ~role:D.Worker ~token_env_var:"FILE_BACKED_FIXTURE_TOKEN"
    ~token_lifetime:Auth_login.Long_lived ()
let seed_keeper base_path =
  let _token, credential = auth_ok (ensure base_path) in credential
let seed_expired base_path =
  let credential = seed_keeper base_path in
  Auth.save_credential base_path { credential with expires_at = Some "2000-01-01T00:00:00Z" };
  credential
let seed_shared base_path =
  List.iter (fun agent_name ->
    let _credential = auth_ok (Auth.save_file_backed_raw_token_credential base_path
        ~agent_name ~role:D.Worker ~raw_token:"file-backed-fixture-shared-token") in ())
    [ "keeper"; "other" ]

let lock_path base_path = Filename.concat (Unix.realpath (Auth.auth_dir base_path)) ".credentials.lock"
let await_waiter base_path completed =
  let rec wait () =
    if File_lock_eio.For_testing.holders_and_waiters ~lock_path:(lock_path base_path) >= 2 then ()
    else match Eio.Promise.peek completed with
      | Some _ -> fail "competing publisher bypassed credential admission"
      | None -> Eio.Fiber.yield (); wait () in
  wait ()
let interleave base_path first second =
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
        | None, Some _ -> fail "first operation bypassed credential admission"
        | None, None -> Eio.Fiber.yield (); await_first () in
      await_first ();
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_second_done (second ()));
      await_waiter base_path second_done;
      Eio.Promise.resolve signal_continue ();
      Eio.Promise.await first_done, Eio.Promise.await second_done)

let test_prune_then_ensure () = with_workspace @@ fun base_path ->
  let _old = seed_expired base_path in
  let retired, issued = interleave base_path (fun () -> prune base_path) (fun () -> ensure base_path) in
  check int "expired old owner is retired" 1 (List.length (auth_ok retired));
  let _token, credential = auth_ok issued in
  check bool "explicit ensure recreates after prune" true (current base_path "keeper" = credential);
  check_pair base_path "keeper"
let test_ensure_then_prune () = with_workspace @@ fun base_path ->
  let old = seed_expired base_path in
  let issued, retired = interleave base_path (fun () -> ensure base_path) (fun () -> prune base_path) in
  let _token, credential = auth_ok issued in
  check int "prune observes the live replacement" 0 (List.length (auth_ok retired));
  check bool "owned UUID continuity retained" true (credential.id = old.id);
  check_pair base_path "keeper"
let test_admin_then_ensure () = with_workspace @@ fun base_path ->
  let _old = seed_expired base_path in
  let admin, issued = interleave base_path (fun () -> set_admin base_path) (fun () -> ensure base_path) in
  let admin = auth_ok admin in
  let token, credential = auth_ok issued in
  check bool "ensure reuses current Admin instead of stale Worker UUID" true (credential = admin);
  check bool "current supplied bearer reused" true (String.equal token supplied);
  check_pair base_path "keeper"
let test_ensure_then_admin () = with_workspace @@ fun base_path ->
  let old = seed_expired base_path in
  let issued, admin = interleave base_path (fun () -> ensure base_path) (fun () -> set_admin base_path) in
  let _token, keeper = auth_ok issued in
  check bool "earlier Keeper recreation retains its UUID" true (keeper.id = old.id);
  check bool "later explicit Admin replacement is current" true (current base_path "keeper" = auth_ok admin);
  check_pair base_path "keeper"
let test_set_then_revoke () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  let issued, () = interleave base_path (fun () -> set_admin base_path) (fun () -> revoke base_path) in
  let _issued = auth_ok issued in check_absent base_path "keeper"
let test_revoke_then_set () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  let (), issued = interleave base_path (fun () -> revoke base_path) (fun () -> set_admin base_path) in
  check bool "later explicit publication is current" true (current base_path "keeper" = auth_ok issued);
  check_pair base_path "keeper"
let test_set_then_rotation () = with_workspace @@ fun base_path ->
  seed_shared base_path;
  let issued, rotated = interleave base_path (fun () -> set_admin base_path) (fun () -> rotate base_path) in
  check int "current replacement breaks the shared group" 0 (List.length (auth_ok rotated));
  check bool "current Admin remains exact" true (current base_path "keeper" = auth_ok issued);
  List.iter (check_pair base_path) [ "keeper"; "other" ]
let test_rotation_then_set () = with_workspace @@ fun base_path ->
  seed_shared base_path;
  let rotated, issued = interleave base_path (fun () -> rotate base_path) (fun () -> set_admin base_path) in
  (match auth_ok rotated with
   | [ { Auth.rotated_agents = [ "keeper", Ok (); "other", Ok () ]; _ } ] -> ()
   | _ -> fail "both current shared owners must rotate");
  check bool "later explicit replacement is current" true (current base_path "keeper" = auth_ok issued);
  List.iter (check_pair base_path) [ "keeper"; "other" ]
let test_login_then_revoke () = with_workspace @@ fun base_path ->
  let issued, () = interleave base_path (fun () -> login base_path) (fun () -> revoke base_path) in
  let _report = auth_ok issued in check_absent base_path "keeper"
let test_revoke_then_login () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  let (), issued = interleave base_path (fun () -> revoke base_path) (fun () -> login base_path) in
  let report = auth_ok issued in
  check bool "report uses shared raw path authority" true (report.raw_token_file = Auth.raw_token_file base_path "keeper");
  check bool "login reports the current persisted bearer" true (raw base_path "keeper" = report.bearer_token);
  check_pair base_path "keeper"

let rejected = function Error _ -> () | Ok _ -> fail "unknown current authority must refuse publication"
let snapshot paths = List.map read paths
let test_corrupt_name_preserved () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  let file = Auth.credential_file base_path "keeper" in
  Auth.save_private_text_file file "{";
  let paths = [ file; Auth.raw_token_file base_path "keeper" ] in
  let before = snapshot paths in
  rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
  check bool "corrupt current name and raw bytes survive all publishers" true (snapshot paths = before)
let test_foreign_uuid_preserved () = with_workspace @@ fun base_path ->
  let token, owner = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
  let id = match owner.id with Some id -> id | None -> fail "fixture UUID missing" in
  let target = Auth.credential_file base_path (D.Credential_id.to_string id) in
  let named = Auth.credential_file base_path "keeper" in
  let forged = { owner with D.agent_name = "keeper" } in
  Auth.save_private_text_file named (D.agent_credential_to_yojson forged |> Yojson.Safe.to_string);
  let before = read target, read named in
  rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
  check bool "foreign UUID and forged name remain exact" true ((read target, read named) = before);
  let _verified = auth_ok (Auth.verify_token base_path ~agent_name:"operator" ~token) in
  Auth.save_private_text_file named (Yojson.Safe.to_string (`Assoc [ "redirect_to", `String (D.Credential_id.to_string id ^ ".json") ]));
  let before = read target, read named in
  rejected (ensure base_path);
  check bool "foreign-owner redirect cannot authorize recreation" true ((read target, read named) = before)
let test_self_uuid_preserved () = with_workspace @@ fun base_path ->
  let old = seed_keeper base_path in
  let name = Auth.credential_file base_path "keeper" in
  let forged = { old with D.id = Some (D.Credential_id.of_string "keeper") } in
  Auth.save_private_text_file name (D.agent_credential_to_yojson forged |> Yojson.Safe.to_string);
  Unix.unlink (Auth.raw_token_file base_path "keeper");
  let before = read name in
  rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
  check bool "self-UUID payload remains exact" true (read name = before);
  check bool "no raw token written before refusal" true (Auth.load_raw_token base_path ~agent_name:"keeper" = None)
let test_unreadable_raw_preserved () =
  List.iter (fun dangling -> with_workspace @@ fun base_path ->
    let _old = seed_keeper base_path in
    let named = Auth.credential_file base_path "keeper" in
    let raw_path = Auth.raw_token_file base_path "keeper" in
    let before = read named in
    Unix.unlink raw_path;
    if dangling then Unix.symlink (Filename.concat base_path "missing-raw-target") raw_path
    else Unix.mkdir raw_path 0o700;
    rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
    check bool "credential preserved on raw read failure" true (read named = before);
    check bool "occupied raw path preserved" true
      ((Unix.lstat raw_path).Unix.st_kind = if dangling then Unix.S_LNK else Unix.S_DIR)) [ false; true ]
let test_failed_admission_preserves_pair () = with_workspace @@ fun base_path ->
  let _old = seed_expired base_path in
  let paths = [ Auth.credential_file base_path "keeper"; Auth.raw_token_file base_path "keeper" ] in
  let before = snapshot paths in
  let path = lock_path base_path in Unix.unlink path; Unix.mkdir path 0o700;
  rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
  check bool "admission failure precedes every pair write" true (snapshot paths = before)
let test_partial_publication_reported () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  let previous_raw = raw base_path "keeper" in
  let named = Auth.credential_file base_path "keeper" in
  let before = read named in
  let directory = Filename.dirname named in
  Unix.chmod directory 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
    match set_admin base_path with
    | Error (D.System (D.System_error.IoError detail)) ->
      check bool "failure reports restored raw token" true
        (String_util.string_contains_substring ~needle:"raw token: not published" detail);
      check bool "failure reports unpublished credential" true
        (String_util.string_contains_substring ~needle:"credential: not published" detail)
    | Error error -> fail (D.masc_error_to_string error)
    | Ok _ -> fail "readable but unwritable credential directory must refuse successful publication");
  check bool "credential remained unchanged" true (read named = before);
  check bool "old recoverable raw token restored" true (raw base_path "keeper" = previous_raw);
  check_pair base_path "keeper";
  check bool "partial pair is not claimed to authenticate" true
    (Result.is_error (Auth.verify_token base_path ~agent_name:"keeper" ~token:supplied))
let test_opaque_bearer_and_name_roundtrip () = with_workspace @@ fun base_path ->
  let agent_name = "Agent +&" in
  let supplied = "opaque-file+backed~fixture/==" in
  let credential = auth_ok (Auth.save_file_backed_raw_token_credential base_path ~agent_name ~role:D.Admin ~raw_token:supplied) in
  check bool "Auth reader preserves supplied opaque bytes" true (Auth.load_raw_token base_path ~agent_name = Some supplied);
  check bool "login file client preserves supplied opaque bytes" true
    (Auth_login.read_persisted_token ~base_path ~agent_name = Some supplied);
  let verified = auth_ok (Auth.verify_token base_path ~agent_name ~token:supplied) in
  check bool "opaque file client authenticates the current record" true (verified = credential);
  let request = Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "Authorization", "Bearer " ^ supplied ])
      `POST "/mcp" in
  check (option string) "production HTTP bearer parsing resolves the exact file-backed owner"
    (Some agent_name) (Server_auth.dashboard_actor_for_request ~base_path request);
  let request_authority =
    match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority
    | Error `Malformed -> fail "fixture loopback request authority is malformed" in
  (match Server_auth.verify_mcp_auth_for_authority ~base_path ~request_authority request with
   | Ok None -> () (* Authorization succeeded; identity was checked above. *)
   | Ok (Some _) -> fail "unexpected MCP authorization result"
   | Error error -> fail (D.masc_error_to_string error));
  let report = auth_ok (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935 ~agent_name ~role:D.Worker
      ~token_env_var:"FILE_BACKED_FIXTURE_TOKEN" ~token_lifetime:Auth_login.Long_lived ()) in
  check bool "login report names Auth's encoded path" true (report.raw_token_file = Auth.raw_token_file base_path agent_name);
  check_pair base_path agent_name

let test_unstable_bearers_refuse_without_effects () =
  List.iter (fun supplied -> with_workspace @@ fun base_path ->
    let _old = seed_keeper base_path in
    let paths = [ Auth.credential_file base_path "keeper";
      Auth.raw_token_file base_path "keeper"; Auth.auth_config_file base_path;
      Auth.workspace_secret_file base_path ] in
    let snapshot () = List.map (fun path ->
      if Sys.file_exists path then Some (read path) else None) paths in
    let before = snapshot () in
    (match Auth.save_file_backed_raw_token_credential base_path ~agent_name:"keeper"
        ~role:D.Admin ~raw_token:supplied with
     | Error (D.Auth (D.Auth_error.InvalidToken _)) -> ()
     | Error error -> fail (D.masc_error_to_string error)
     | Ok _ -> fail "HTTP-unstable bearer was published");
    check bool "refused supplied bearer leaves pair and config exact" true (snapshot () = before))
    [ " leading"; "trailing "; "with space"; "with\ttab"; "with\rCR";
      "with\nLF"; "with\000NUL"; "with\127DEL" ];
  List.iter (fun supplied -> with_workspace @@ fun base_path ->
    (* Direct token APIs keep their opaque contract. Seed a legacy matching
       file pair to exercise Ensure's separate reuse admission boundary. *)
    let _credential = auth_ok (Auth.save_raw_token_credential base_path
        ~agent_name:"keeper" ~role:D.Admin ~raw_token:supplied) in
    Auth.save_private_text_file (Auth.raw_token_file base_path "keeper") supplied;
    let paths = [ Auth.credential_file base_path "keeper";
      Auth.raw_token_file base_path "keeper"; Auth.auth_config_file base_path;
      Auth.workspace_secret_file base_path;
      Filename.concat (Auth.auth_dir base_path) "internal_keeper.token.hash" ] in
    let snapshot () = List.map (fun path ->
      if Sys.file_exists path then Some (read path) else None) paths in
    let before = snapshot () in
    (match ensure base_path with
     | Error (D.Auth (D.Auth_error.InvalidToken _)) -> ()
     | Error error -> fail (D.masc_error_to_string error)
     | Ok _ -> fail "Ensure reused an HTTP-unstable matching bearer");
    check bool "reuse refusal neither normalizes pair nor bootstraps config/internal token"
      true (snapshot () = before)) [ " leading"; "trailing\t"; "with\nLF" ]

let test_fifo_authority_refuses_without_blocking () =
  (* Fork outside an Eio environment. The bounded child proves actual Auth
     calls refuse a FIFO with no writer; an older blocking open fails finitely. *)
  List.iter (fun raw_fifo ->
  match Unix.fork () with
  | 0 ->
      Sys.set_signal Sys.sigalrm Sys.Signal_default;
      let _previous_alarm_seconds = Unix.alarm 5 in
      (try
         (with_workspace @@ fun base_path ->
           let _old = seed_keeper base_path in
           let named = Auth.credential_file base_path "keeper" in
           let raw_path = Auth.raw_token_file base_path "keeper" in
           let occupied = if raw_fifo then raw_path else named in
           let other = if raw_fifo then named else raw_path in
           let before = read other, read (Auth.auth_config_file base_path) in
           Unix.unlink occupied;
           Unix.mkfifo occupied 0o600;
           rejected (ensure base_path); rejected (set_admin base_path); rejected (login base_path);
           check bool "FIFO refusal preserves pair counterpart and config" true
             ((read other, read (Auth.auth_config_file base_path)) = before);
           check bool "occupied FIFO is preserved" true ((Unix.lstat occupied).Unix.st_kind = Unix.S_FIFO);
           Unix.unlink occupied;
           let _issued_pair = auth_ok (ensure base_path) in
           check_pair base_path "keeper");
         exit 0
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> prerr_endline (Printexc.to_string exn); exit 2)
  | pid ->
      let reaped = ref false in
      Fun.protect ~finally:(fun () -> if not !reaped then (
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        let _reaped_child = Unix.waitpid [] pid in ())) (fun () ->
          let _, status = Unix.waitpid [] pid in
          reaped := true;
          match status with Unix.WEXITED 0 -> ()
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
              fail "FIFO authority must refuse without waiting for a writer")) [ false; true ]

let test_regular_symlink_authority_remains_readable () = with_workspace @@ fun base_path ->
  let _old = seed_keeper base_path in
  List.iter (fun path ->
    let target = path ^ ".regular-target" in
    Unix.rename path target; Unix.symlink target path)
    [ Auth.credential_file base_path "keeper"; Auth.raw_token_file base_path "keeper" ];
  let _issued_pair = auth_ok (ensure base_path) in
  check_pair base_path "keeper";
  let batch = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["keeper"]) in
  List.iter (fun (_, issued) -> ignore (auth_ok issued)) batch;
  let _admin = auth_ok (set_admin base_path) in
  check_pair base_path "keeper";
  let _login = auth_ok (login base_path) in
  check_pair base_path "keeper"

type bootstrap_config = Missing_config | Disabled_config
type bootstrap_corruption = Malformed_name | Foreign_redirect
let optional_bytes path = if Sys.file_exists path then Some (read path) else None
let test_bootstrap_cannot_bypass_current_authority () =
  List.iter (fun config_state -> List.iter (fun corruption -> with_workspace @@ fun base_path ->
    let token, operator = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
    let operator = { operator with D.role = D.Admin } in
    Auth.save_credential base_path operator;
    let id = match operator.id with Some id -> id | None -> fail "operator UUID missing" in
    let target = Auth.credential_file base_path (D.Credential_id.to_string id) in
    let name = Auth.credential_file base_path "keeper" in
    (match corruption with
     | Malformed_name -> Auth.save_private_text_file name "{"
     | Foreign_redirect -> Auth.save_private_text_file name
       (Yojson.Safe.to_string (`Assoc [ "redirect_to", `String (D.Credential_id.to_string id ^ ".json") ])));
    (match config_state with
     | Missing_config -> Unix.unlink (Auth.auth_config_file base_path)
     | Disabled_config -> Auth.save_auth_config base_path { D.default_auth_config with enabled = false });
    let paths = [ target; name; Auth.auth_config_file base_path; Auth.workspace_secret_file base_path ] in
    let before = List.map optional_bytes paths in
    rejected (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"keeper" ~role:D.Admin ~token_env_var:"FILE_BACKED_FIXTURE_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ());
    check bool "bootstrap refusal preserves config, secret and both identity files" true
      (List.map optional_bytes paths = before);
    check (option string) "no bootstrap Admin name was published" None (Auth.read_initial_admin base_path);
    check bool "no bearer sidecar was published" true (Auth.load_raw_token base_path ~agent_name:"keeper" = None);
    check bool "foreign operator remains the exact current Admin" true
      (auth_ok (Auth.verify_token base_path ~agent_name:"operator" ~token) = operator))
    [ Malformed_name; Foreign_redirect ]) [ Missing_config; Disabled_config ]

let test_valid_admin_bootstrap_keeps_secret_and_pair () = with_workspace @@ fun base_path ->
  Auth.save_auth_config base_path { D.default_auth_config with enabled = false };
  let report = auth_ok (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"keeper" ~role:D.Admin ~token_env_var:"FILE_BACKED_FIXTURE_TOKEN"
      ~token_lifetime:Auth_login.Long_lived ()) in
  check bool "login reports the real bootstrap transition" true (report.auth_change = Auth_login.Auth_enabled);
  let cfg = Auth.load_auth_config base_path in
  check bool "required bearer auth enabled" true (cfg.enabled && cfg.require_token);
  check (option string) "initial Admin ownership recorded" (Some "keeper") (Auth.read_initial_admin base_path);
  check bool "workspace-secret hash has the same config and file authority" true
    (cfg.workspace_secret_hash = Some (String.trim (read (Auth.workspace_secret_file base_path))));
  check bool "explicit no-expiry bootstrap honored" true ((current base_path "keeper").expires_at = None);
  check_pair base_path "keeper"

let test_missing_config_admin_keeps_required_default_and_pair () = with_workspace @@ fun base_path ->
  Unix.unlink (Auth.auth_config_file base_path);
  let report = auth_ok (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"keeper" ~role:D.Admin ~token_env_var:"FILE_BACKED_FIXTURE_TOKEN"
      ~token_lifetime:Auth_login.Long_lived ()) in
  check bool "missing config uses already-required auth" true
    (report.auth_change = Auth_login.Auth_already_required);
  check bool "required default config remains authoritative" true
    (Auth.load_auth_config base_path = D.default_auth_config);
  check bool "login does not manufacture a config file" false
    (Sys.file_exists (Auth.auth_config_file base_path));
  check bool "login does not manufacture a workspace secret" false
    (Sys.file_exists (Auth.workspace_secret_file base_path));
  check (option string) "already-required default needs no bootstrap Admin marker" None
    (Auth.read_initial_admin base_path);
  check bool "requested Admin role is honored" true ((current base_path "keeper").role = D.Admin);
  check bool "explicit no-expiry default login honored" true ((current base_path "keeper").expires_at = None);
  check bool "report contains the recoverable bearer" true (raw base_path "keeper" = report.bearer_token);
  check_pair base_path "keeper"

let test_keeper_reuse_repairs_unselected_collision () = with_workspace @@ fun base_path ->
  seed_shared base_path;
  let other_before = current base_path "other" in
  let token, credential = auth_ok (ensure base_path) in
  check bool "keeper remints its ambiguous bearer" false (String.equal token (raw base_path "other"));
  check bool "unselected owner is preserved" true (current base_path "other" = other_before);
  check bool "returned credential is current" true (current base_path "keeper" = credential);
  List.iter (check_pair base_path) [ "keeper"; "other" ];
  let request = Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "Authorization", "Bearer " ^ token ]) `POST "/mcp" in
  check (option string) "repaired keeper bearer reaches HTTP actor resolution"
    (Some "keeper") (Server_auth.dashboard_actor_for_request ~base_path request)

let () = run "auth_file_backed_transaction" [ "publication", [
  test_case "keeper reuse repairs a bearer shared with an unselected owner" `Quick test_keeper_reuse_repairs_unselected_collision;
  test_case "prune then ensure recreates a recoverable pair" `Quick test_prune_then_ensure;
  test_case "ensure then prune preserves live pair and UUID" `Quick test_ensure_then_prune;
  test_case "Admin then ensure reuses current role and identity" `Quick test_admin_then_ensure;
  test_case "ensure then Admin preserves explicit replacement" `Quick test_ensure_then_admin;
  test_case "file-backed publication then revoke removes both files" `Quick test_set_then_revoke;
  test_case "revoke then publication creates both files" `Quick test_revoke_then_set;
  test_case "publication then rotation uses current group" `Quick test_set_then_rotation;
  test_case "rotation then publication keeps file clients current" `Quick test_rotation_then_set;
  test_case "CLI login then revoke leaves no orphan raw token" `Quick test_login_then_revoke;
  test_case "revoke then CLI login yields a recoverable report" `Quick test_revoke_then_login;
  test_case "corrupt current name cannot authorize a publisher" `Quick test_corrupt_name_preserved;
  test_case "foreign UUID and redirect cannot be overwritten" `Quick test_foreign_uuid_preserved;
  test_case "self UUID cannot become an unreadable successful result" `Quick test_self_uuid_preserved;
  test_case "directory and dangling raw token preserve authority" `Quick test_unreadable_raw_preserved;
  test_case "failed admission precedes every pair write" `Quick test_failed_admission_preserves_pair;
  test_case "partial publication is observed and reported" `Quick test_partial_publication_reported;
  test_case "opaque supplied bytes and encoded names reach file clients and HTTP auth" `Quick test_opaque_bearer_and_name_roundtrip;
  test_case "HTTP-unstable supplied and reused bearers preserve pair and config" `Quick test_unstable_bearers_refuse_without_effects;
  test_case "FIFO authority refuses without waiting for a writer" `Quick test_fifo_authority_refuses_without_blocking;
  test_case "regular symlink authority remains readable" `Quick test_regular_symlink_authority_remains_readable;
  test_case "missing and disabled bootstrap refuse corrupt or foreign ownership" `Quick test_bootstrap_cannot_bypass_current_authority;
  test_case "valid Admin bootstrap retains secret and recoverable pair" `Quick test_valid_admin_bootstrap_keeps_secret_and_pair;
  test_case "missing config Admin retains required default without bootstrap files" `Quick test_missing_config_admin_keeps_required_default_and_pair;
] ]
