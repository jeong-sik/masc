(* The real rotation, prune, revoke and credential publishers contend on one durable
   transaction. Admission barriers fix order without sleeps or stale lists. *)
open Alcotest
module Prune = Auth_token_prune

let () = Mirage_crypto_rng_unix.use_default ()

let auth_ok = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)

(* The FIFO preflight children end with an alarm and the parent's wait can be
   interrupted by a caught signal -- SIGCHLD among them -- before the child
   reports. EINTR is the kernel asking us to wait again, not a failed wait;
   without the retry the same tree passed or failed by delivery timing. *)
let rec waitpid_nointr pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

let with_workspace f =
  let base_path = Filename.temp_dir "token-rotation-transaction-" "" in
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ()) (fun () ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    f base_path)

let expired = "2000-01-01T00:00:00Z"
let shared = "rotation-transaction-shared-token"

let seed ?(expiry = None) base_path name =
  let credential = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:name ~role:Masc_domain.Worker ~raw_token:shared) in
  let credential = { credential with expires_at = expiry } in
  Auth.save_credential base_path credential;
  credential

let seed_pair ?(expiry = None) base_path =
  let first = seed ~expiry base_path "aaa" in
  let second = seed ~expiry base_path "bbb" in
  first, second

let rotate base_path = Auth.rotate_shared_tokens base_path
let prune base_path = Prune.run ~base_path ~now:(Time_compat.now ()) ~mode:Prune.Retire
let renew base_path = auth_ok (Auth.create_token base_path ~agent_name:"aaa" ~role:Masc_domain.Admin)
let revoke base_path = Auth.delete_credential base_path "aaa"
let read path = In_channel.with_open_bin path In_channel.input_all
let credential base_path name = match Auth.load_credential base_path name with
  | Some credential -> credential
  | None -> fail "fixture credential missing"
let current_raw base_path name = match Auth.load_raw_token base_path ~agent_name:name with
  | Some raw -> raw
  | None -> fail "successful rotation lost its raw token"
let check_recoverable base_path name =
  let raw = current_raw base_path name in
  let current = credential base_path name in
  check string "raw sidecar matches current credential" current.token (Auth.sha256_hash raw);
  let _verified = auth_ok (Auth.verify_token base_path ~agent_name:name ~token:raw) in
  ()
let check_rotated outcomes =
  match auth_ok outcomes with
  | [ { Auth.rotated_agents = [ "aaa", Ok (); "bbb", Ok () ]; _ } ] -> ()
  | _ -> fail "both current shared owners must rotate"

let lock_path base_path = Filename.concat (Unix.realpath (Auth.auth_dir base_path)) ".credentials.lock"

let await_waiter base_path completed =
  let rec wait () =
    if File_lock_eio.For_testing.holders_and_waiters ~lock_path:(lock_path base_path) >= 2 then ()
    else match Eio.Promise.peek completed with
      | Some _ -> fail "the competing operation bypassed the credential transaction"
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
        | None, Some _ -> fail "the first operation bypassed the credential transaction"
        | None, None -> Eio.Fiber.yield (); await_first () in
      await_first ();
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_second_done (second ()));
      await_waiter base_path second_done;
      Eio.Promise.resolve signal_continue ();
      Eio.Promise.await first_done, Eio.Promise.await second_done)

let test_admin_before_rotation () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let (token, current), result = interleave base_path (fun () -> renew base_path) (fun () -> rotate base_path) in
  check int "renewal breaks the current shared group" 0 (List.length (auth_ok result));
  check bool "Admin credential is preserved exactly" true (credential base_path "aaa" = current);
  let _verified = auth_ok (Auth.verify_token base_path ~agent_name:"aaa" ~token) in
  check string "role remains Admin" "admin" (Masc_domain.agent_role_to_string current.role)

let test_rotation_before_admin () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let result, (token, current) = interleave base_path (fun () -> rotate base_path) (fun () -> renew base_path) in
  check_rotated result;
  check bool "later Admin renewal remains current" true (credential base_path "aaa" = current);
  let _verified = auth_ok (Auth.verify_token base_path ~agent_name:"aaa" ~token) in
  check_recoverable base_path "bbb"

let test_prune_before_rotation () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair ~expiry:(Some expired) base_path in
  let retired, result = interleave base_path (fun () -> prune base_path) (fun () -> rotate base_path) in
  check int "prune retired both expired owners" 2 (List.length (auth_ok retired));
  check int "fresh discovery does not resurrect deleted owners" 0 (List.length (auth_ok result));
  List.iter (fun name ->
    check bool "credential stays removed" true (Auth.load_credential base_path name = None);
    check bool "raw sidecar stays removed" true (Auth.load_raw_token base_path ~agent_name:name = None))
    [ "aaa"; "bbb" ]

let test_rotation_before_prune () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair ~expiry:(Some expired) base_path in
  let result, retired = interleave base_path (fun () -> rotate base_path) (fun () -> prune base_path) in
  check_rotated result;
  check int "prune sees current live credentials" 0 (List.length (auth_ok retired));
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_revoke_before_rotation () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let (), result = interleave base_path (fun () -> revoke base_path) (fun () -> rotate base_path) in
  check int "remaining owner is not a shared group" 0 (List.length (auth_ok result));
  check bool "revocation cannot be resurrected" true (Auth.load_credential base_path "aaa" = None);
  check bool "revoked raw token stays removed" true (Auth.load_raw_token base_path ~agent_name:"aaa" = None);
  check string "remaining owner was not rewritten" shared (current_raw base_path "bbb")

let test_rotation_before_revoke () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let result, () = interleave base_path (fun () -> rotate base_path) (fun () -> revoke base_path) in
  check_rotated result;
  check bool "later revoke removes the rotated credential" true (Auth.load_credential base_path "aaa" = None);
  check bool "later revoke removes its raw sidecar" true (Auth.load_raw_token base_path ~agent_name:"aaa" = None);
  check_recoverable base_path "bbb"

let snapshot base_path =
  List.map read [ Auth.credential_file base_path "aaa"; Auth.raw_token_file base_path "aaa";
    Auth.credential_file base_path "bbb"; Auth.raw_token_file base_path "bbb" ]
let check_refused_before_writes base_path before =
  (match rotate base_path with Error _ -> () | Ok _ -> fail "rotation must refuse the whole plan");
  check (list string) "all credential and raw bytes survive refusal" before (snapshot base_path)

let test_failed_admission () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let before = snapshot base_path in
  let path = lock_path base_path in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  check_refused_before_writes base_path before

let test_read_failure () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let before = snapshot base_path in
  Unix.mkdir (Auth.credential_file base_path "zzz") 0o700;
  check_refused_before_writes base_path before

let test_config_failure () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let before = snapshot base_path in
  Auth.save_private_text_file (Auth.auth_config_file base_path) "{";
  check_refused_before_writes base_path before

let test_ambiguous_names_preserved () =
  with_workspace @@ fun base_path ->
  let _, second = seed_pair base_path in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa") "{";
  Auth.save_private_text_file (Auth.credential_file base_path "bbb")
    (Masc_domain.agent_credential_to_yojson { second with agent_name = "other" } |> Yojson.Safe.to_string);
  let before = snapshot base_path in
  check int "ambiguous records grant no rotation authority" 0 (List.length (auth_ok (rotate base_path)));
  check (list string) "ambiguous files remain exact" before (snapshot base_path)

let test_raw_failure_continues () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let raw = Auth.raw_token_file base_path "aaa" in
  Unix.unlink raw;
  Unix.mkdir raw 0o700;
  let old = credential base_path "aaa" in
  let _cached_result = Auth.find_static_credential_by_token base_path ~token:shared in
  (match auth_ok (rotate base_path) with
   | [ { Auth.rotated_agents = [ "aaa", Error { raw_token = Auth.Publication_unreadable _;
       credential = Auth.Not_published; _ }; "bbb", Ok () ]; _ } ] -> ()
   | _ -> fail "raw failure must report observed state and allow the later owner to rotate");
  check bool "failed raw write preserves the old credential" true (credential base_path "aaa" = old);
  check_recoverable base_path "bbb";
  check bool "old shared bearer has one current owner after partial rotation" true
    (Result.is_ok (Auth.find_static_credential_by_token base_path ~token:shared))

let test_credential_failure_after_raw_publication () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let before = List.map (fun name -> read (Auth.credential_file base_path name)) [ "aaa"; "bbb" ] in
  let directory = Filename.dirname (Auth.credential_file base_path "aaa") in
  (* The credential directory is readable, but publication cannot create a
     replacement file. Raw sidecars live in the writable parent Auth directory. *)
  Unix.chmod directory 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
    match auth_ok (rotate base_path) with
    | [ { Auth.rotated_agents = [ "aaa", Error { raw_token = Auth.Not_published;
        credential = Auth.Not_published; _ }; "bbb", Error { raw_token = Auth.Not_published;
        credential = Auth.Not_published; _ } ]; _ } ] -> ()
    | _ -> fail "second-stage publication failure must report the restored raw sidecar");
  check (list string) "credential bytes remained old" before
    (List.map (fun name -> read (Auth.credential_file base_path name)) [ "aaa"; "bbb" ]);
  List.iter (fun name -> check bool "failed rotation preserves the old recoverable bearer" true
    (String.equal (Auth.sha256_hash (current_raw base_path name)) (credential base_path name).token))
    [ "aaa"; "bbb" ]

let test_uuid_owners_and_aliases () =
  with_workspace @@ fun base_path ->
  let first, second = seed_pair base_path in
  let first = { first with id = Some (Masc_domain.Credential_id.of_string "rotation-uuid-a") } in
  let second = { second with id = Some (Masc_domain.Credential_id.of_string "rotation-uuid-b") } in
  Auth.save_credential base_path first;
  Auth.save_credential base_path second;
  Auth.save_private_text_file (Auth.credential_file base_path "alias")
    (Yojson.Safe.to_string (`Assoc [ "redirect_to", `String "rotation-uuid-a.json" ]));
  check_rotated (rotate base_path);
  check bool "UUID identity preserved" true ((credential base_path "aaa").id = first.id);
  check bool "legitimate alias still resolves the canonical owner" true
    (Auth.load_credential base_path "alias" = Some (credential base_path "aaa"));
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_forged_uuid_refused () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  let token, operator = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
  let operator = { operator with role = Masc_domain.Admin } in
  Auth.save_credential base_path operator;
  let id = match operator.id with Some id -> id | None -> fail "UUID fixture missing" in
  let target = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
  let before_operator = read target in
  let forged = { first with id = Some id } in
  let json = Masc_domain.agent_credential_to_yojson forged |> Yojson.Safe.to_string in
  Auth.save_private_text_file (Auth.credential_file base_path "oldid") json;
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Yojson.Safe.to_string (`Assoc [ "redirect_to", `String "oldid.json" ]));
  check_refused_before_writes base_path (snapshot base_path);
  check string "foreign live UUID remains exact" before_operator (read target);
  let _verified = auth_ok (Auth.verify_token base_path ~agent_name:"operator" ~token) in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa") json;
  check_refused_before_writes base_path (snapshot base_path);
  check string "direct forged UUID also preserves operator" before_operator (read target);
  let escaped = { first with id = Some (Masc_domain.Credential_id.of_string "../../outside") } in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson escaped |> Yojson.Safe.to_string);
  check_refused_before_writes base_path (snapshot base_path)

let test_keeper_ensure_refuses_foreign_uuid_before_publication () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  let token, operator = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
  let operator = { operator with role = Masc_domain.Admin } in
  Auth.save_credential base_path operator;
  let id = match operator.id with Some id -> id | None -> fail "operator UUID missing" in
  let uuid = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson { first with id = Some id } |> Yojson.Safe.to_string);
  Auth.save_private_text_file (Auth.credential_file base_path "operator-alias")
    (Yojson.Safe.to_string (`Assoc ["redirect_to", `String (Masc_domain.Credential_id.to_string id ^ ".json")]));
  (* The earlier requested owner would need to remint its stale raw sidecar,
     but another current owner's forged UUID must refuse that write too. *)
  Auth.save_private_text_file (Auth.raw_token_file base_path "operator") shared;
  let paths = [uuid; Auth.credential_file base_path "operator";
    Auth.raw_token_file base_path "operator"; Auth.credential_file base_path "operator-alias";
    Auth.credential_file base_path "aaa"; Auth.raw_token_file base_path "aaa";
    Auth.credential_file base_path "bbb"; Auth.raw_token_file base_path "bbb"] in
  let before = List.map read paths in
  check bool "singleton refuses the forged UUID before publication" true
    (Result.is_error (Auth.ensure_keeper_credential base_path ~agent_name:"aaa"));
  check (list string) "singleton preserves every victim, raw and alias byte" before (List.map read paths);
  let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["operator"; "aaa"]) in
  check bool "both conflicting publishers refuse in the batch" true
    (List.for_all (fun (_, result) -> Result.is_error result) results);
  check (list string) "batch does not partially remint its earlier colliding owner" before (List.map read paths);
  let verified = auth_ok (Auth.verify_token base_path ~agent_name:"operator" ~token) in
  check bool "victim bearer remains the original Admin authority" true
    (verified = operator)
;;

let test_keeper_ensure_refuses_another_owner_alias () =
  List.iter (fun keep_raw -> with_workspace @@ fun base_path ->
    let _pair = seed_pair base_path in
    let token, victim = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"operator") in
    let id = match victim.id with Some id -> id | None -> fail "operator UUID missing" in
    let uuid = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
    Auth.save_private_text_file (Auth.credential_file base_path "aaa")
      (Yojson.Safe.to_string (`Assoc ["redirect_to", `String (Masc_domain.Credential_id.to_string id ^ ".json")]));
    let raw = Auth.raw_token_file base_path "aaa" in
    if not keep_raw then Unix.unlink raw;
    let paths = [uuid; Auth.credential_file base_path "operator";
      Auth.raw_token_file base_path "operator"; Auth.credential_file base_path "aaa";
      Auth.credential_file base_path "bbb"; Auth.raw_token_file base_path "bbb"] in
    let before = List.map read paths in
    check bool "singleton refuses another owner's redirect" true
      (Result.is_error (Auth.ensure_keeper_credential base_path ~agent_name:"aaa"));
    let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["aaa"]) in
    check bool "batch refuses another owner's redirect" true
      (List.for_all (fun (_, result) -> Result.is_error result) results);
    check (list string) "refusal preserves credential, UUID and raw bytes" before (List.map read paths);
    check bool "refusal does not create a missing raw sidecar" keep_raw (Sys.file_exists raw);
    if keep_raw then check string "existing raw survives alias refusal" shared (read raw);
    check bool "victim bearer remains authoritative" true
      (auth_ok (Auth.verify_token base_path ~agent_name:"operator" ~token) = victim))
    [true; false]
;;

let test_keeper_ensure_refuses_absent_uuid_collisions () =
  List.iter (fun second_id -> with_workspace @@ fun base_path ->
    let first, second = seed_pair base_path in
    List.iter (fun (name, credential, id) ->
      Auth.save_private_text_file (Auth.credential_file base_path name)
        (Masc_domain.agent_credential_to_yojson
           { credential with id = Some (Masc_domain.Credential_id.of_string id) }
         |> Yojson.Safe.to_string))
      ["aaa", first, "unpublished-keeper-uuid"; "bbb", second, second_id];
    let before = snapshot base_path in
    check bool "singleton refuses absent duplicate or case-variant UUID ownership" true
      (Result.is_error (Auth.ensure_keeper_credential base_path ~agent_name:"aaa"));
    let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["aaa"; "bbb"]) in
    check bool "batch has no admitted publisher for these colliding targets" true
      (List.for_all (fun (_, result) -> Result.is_error result) results);
    check (list string) "all named credentials and raw bearers remain exact" before (snapshot base_path);
    check bool "refusal never creates the colliding target" false
      (Sys.file_exists (Auth.credential_file base_path "unpublished-keeper-uuid")))
    ["unpublished-keeper-uuid"; "UNPUBLISHED-KEEPER-UUID"]
;;

let test_keeper_same_owner_partial_uuid_retry () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  let first = { first with id = Some (Masc_domain.Credential_id.of_string "keeper-retry-uuid") } in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson first |> Yojson.Safe.to_string);
  Auth.save_private_text_file (Auth.credential_file base_path "keeper-retry-uuid")
    (Masc_domain.agent_credential_to_yojson { first with token = Auth.sha256_hash "partial-publication" }
     |> Yojson.Safe.to_string);
  let _, repaired = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"aaa") in
  check bool "same-owner partial UUID remains reusable" true (repaired.id = first.id);
  check_recoverable base_path "aaa"
;;

let test_self_redirect_refused () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson
      { first with id = Some (Masc_domain.Credential_id.of_string "aaa") } |> Yojson.Safe.to_string);
  check_refused_before_writes base_path (snapshot base_path)

let test_absent_uuid_collision_refused () =
  with_workspace @@ fun base_path ->
  let first, second = seed_pair base_path in
  let id = Some (Masc_domain.Credential_id.of_string "absent-uuid") in
  List.iter (fun (name, current) -> Auth.save_private_text_file
    (Auth.credential_file base_path name)
    (Masc_domain.agent_credential_to_yojson { current with Masc_domain.id = id } |> Yojson.Safe.to_string))
    [ "aaa", first; "bbb", second ];
  check_refused_before_writes base_path (snapshot base_path);
  check bool "the colliding UUID is never created" false
    (Sys.file_exists (Auth.credential_file base_path "absent-uuid"))

let test_unique_owner_uuid_collision_refused () =
  with_workspace @@ fun base_path ->
  let first, _second = seed_pair base_path in
  let outsider = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:"operator" ~role:Masc_domain.Admin ~raw_token:"unique-operator-token") in
  let id = Some (Masc_domain.Credential_id.of_string "absent-shared-uuid") in
  List.iter (fun (name, current) -> Auth.save_private_text_file
    (Auth.credential_file base_path name)
    (Masc_domain.agent_credential_to_yojson { current with Masc_domain.id = id } |> Yojson.Safe.to_string))
    [ "aaa", first; "operator", outsider ];
  let before_operator = read (Auth.credential_file base_path "operator") in
  check_refused_before_writes base_path (snapshot base_path);
  check string "unique owner stays unchanged" before_operator (read (Auth.credential_file base_path "operator"));
  check bool "UUID shared with a unique owner is not created" false
    (Sys.file_exists (Auth.credential_file base_path "absent-shared-uuid"))

let test_unselected_case_variant_uuid_refused () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  let outsider = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:"operator" ~role:Masc_domain.Admin ~raw_token:"unique-operator-token") in
  List.iter (fun (name, current, id) -> Auth.save_private_text_file
    (Auth.credential_file base_path name)
    (Masc_domain.agent_credential_to_yojson
      { current with Masc_domain.id = Some (Masc_domain.Credential_id.of_string id) }
      |> Yojson.Safe.to_string))
    ["aaa", first, "case-uuid"; "operator", outsider, "CASE-UUID"];
  let before = snapshot base_path in
  let before_operator = read (Auth.credential_file base_path "operator") in
  (match Auth.rotate_shared_tokens_for_agents base_path ~agent_names:["aaa"] with
   | Error _ -> () | Ok _ -> fail "unselected noncanonical UUID must refuse the entire plan");
  check bool "selected files are unchanged" true (snapshot base_path = before);
  check string "unselected owner is unchanged" before_operator
    (read (Auth.credential_file base_path "operator"));
  check bool "no case-variant payload is published" false
    (Sys.file_exists (Auth.credential_file base_path "case-uuid"))

let test_unpublished_uuid_has_no_bearer_authority () =
  with_workspace @@ fun base_path ->
  let raw = "named-current-token" in
  let current = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:"operator" ~role:Masc_domain.Admin ~raw_token:raw) in
  let id = Some (Masc_domain.Credential_id.of_string "partial-uuid") in
  let current = { current with id } in
  Auth.save_private_text_file (Auth.credential_file base_path "operator")
    (Masc_domain.agent_credential_to_yojson current |> Yojson.Safe.to_string);
  let failed_raw = "unpublished-uuid-token" in
  Auth.save_private_text_file (Auth.credential_file base_path "partial-uuid")
    (Masc_domain.agent_credential_to_yojson { current with token = Auth.sha256_hash failed_raw }
      |> Yojson.Safe.to_string);
  check bool "failed UUID publication cannot authenticate" true
    (Result.is_error (Auth.find_credential_by_token base_path ~token:failed_raw));
  check string "direct named owner retains authority" "operator"
    (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name;
  check bool "listing returns only the named record" true (Auth.list_credentials base_path = [current])

let test_retired_uuid_has_no_bearer_authority () =
  with_workspace @@ fun base_path ->
  let old_raw, old = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"keeper") in
  let raw = "replacement-direct-token" in
  let current = { old with id = None; token = Auth.sha256_hash raw } in
  (* The named publication committed, but retiring the old UUID failed. *)
  Auth.save_private_text_file (Auth.credential_file base_path "keeper")
    (Masc_domain.agent_credential_to_yojson current |> Yojson.Safe.to_string);
  Auth.save_private_text_file (Auth.raw_token_file base_path "keeper") raw;
  check bool "retired UUID token cannot authenticate" true
    (Result.is_error (Auth.find_credential_by_token base_path ~token:old_raw));
  check string "new named token remains authoritative" "keeper"
    (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name;
  check bool "listing ignores the retained old UUID" true (Auth.list_credentials base_path = [current])

let test_one_selected_owner_rotates () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let other = credential base_path "bbb" in
  (match auth_ok (Auth.rotate_shared_tokens_for_agents base_path ~agent_names:[ "aaa" ]) with
   | [ { Auth.rotated_agents = [ "aaa", Ok () ]; _ } ] -> ()
   | _ -> fail "one selected member of a globally shared group must rotate");
  check bool "unselected owner is unchanged" true (credential base_path "bbb" = other);
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_keeper_before_rotation () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let ensured, rotated = interleave base_path
      (fun () -> Auth.ensure_keeper_credential base_path ~agent_name:"aaa")
      (fun () -> rotate base_path) in
  let token, _credential = auth_ok ensured in
  check int "keeper repair breaks the shared group" 0 (List.length (auth_ok rotated));
  check string "returned keeper token is recoverable" token (current_raw base_path "aaa");
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_rotation_before_keeper () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let rotated, ensured = interleave base_path (fun () -> rotate base_path)
      (fun () -> Auth.ensure_keeper_credential base_path ~agent_name:"aaa") in
  check_rotated rotated;
  let token, _credential = auth_ok ensured in
  check string "keeper reuses the current rotated token" token (current_raw base_path "aaa");
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_same_owner_partial_uuid_can_retry () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  let first = { first with id = Some (Masc_domain.Credential_id.of_string "retry-uuid") } in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson first |> Yojson.Safe.to_string);
  let attempted = { first with token = Auth.sha256_hash "interrupted-rotation" } in
  Auth.save_private_text_file (Auth.credential_file base_path "retry-uuid")
    (Masc_domain.agent_credential_to_yojson attempted |> Yojson.Safe.to_string);
  check_rotated (rotate base_path);
  List.iter (check_recoverable base_path) [ "aaa"; "bbb" ]

let test_noncanonical_uuid_is_refused () =
  with_workspace @@ fun base_path ->
  let first, _ = seed_pair base_path in
  Auth.save_private_text_file (Auth.credential_file base_path "aaa")
    (Masc_domain.agent_credential_to_yojson
       { first with id = Some (Masc_domain.Credential_id.of_string "AAA") } |> Yojson.Safe.to_string);
  check_refused_before_writes base_path (snapshot base_path)

let test_failed_supplied_token_preserves_previous_raw () =
  with_workspace @@ fun base_path ->
  let original = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:"operator" ~role:Masc_domain.Admin ~raw_token:"recoverable-old-token") in
  let id = Masc_domain.Credential_id.generate () in
  Auth.save_credential base_path { original with id = Some id };
  let uuid_file = Filename.concat (Filename.dirname (Auth.credential_file base_path "operator"))
      (Masc_domain.Credential_id.to_string id ^ ".json") in
  let previous_uuid = read uuid_file in
  let directory = Filename.dirname (Auth.credential_file base_path "operator") in
  Unix.chmod directory 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
    check bool "credential replacement fails" true
      (Result.is_error (Auth.save_file_backed_raw_token_credential base_path
        ~agent_name:"operator" ~role:Masc_domain.Admin ~raw_token:"unpublished-new-token")));
  check string "previous UUID authority survives failed named replacement" previous_uuid (read uuid_file);
  check string "old recoverable bearer survives" "recoverable-old-token" (current_raw base_path "operator");
  check_recoverable base_path "operator"

let test_failed_keeper_remint_preserves_previous_pair () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let before = snapshot base_path in
  let directory = Filename.dirname (Auth.credential_file base_path "aaa") in
  Unix.chmod directory 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
    check bool "colliding Keeper remint refuses failed publication" true
      (Result.is_error (Auth.ensure_keeper_credential base_path ~agent_name:"aaa")));
  check bool "failed Keeper remint restores both old pairs" true (snapshot base_path = before)

let test_extended_redirect_remains_a_current_owner () =
  with_workspace @@ fun base_path ->
  let first, _second = seed_pair base_path in
  Auth.save_credential base_path { first with id = Some (Masc_domain.Credential_id.generate ()) };
  let named = Auth.credential_file base_path "aaa" in
  let fields = match Yojson.Safe.from_string (read named) with
    | `Assoc fields -> fields | _ -> fail "expected redirect fixture" in
  Auth.save_private_text_file named
    (Yojson.Safe.to_string (`Assoc (("note", `String "extra redirect metadata") :: fields)));
  check bool "normal credential loading accepts the redirect extension" true
    (Auth.load_credential base_path "aaa" <> None);
  (match auth_ok (rotate base_path) with
   | [{Auth.rotated_agents = ["aaa", Ok (); "bbb", Ok ()]; _}] -> ()
   | _ -> fail "extended redirect must participate in the shared-owner rotation");
  List.iter (check_recoverable base_path) ["aaa"; "bbb"]

let test_fifo_diagnostic_listing_refuses_without_blocking () =
  match Unix.fork () with
  | 0 ->
    Sys.set_signal Sys.sigalrm Sys.Signal_default;
    let _previous_alarm_seconds = Unix.alarm 5 in
    (try with_workspace (fun base_path ->
       Unix.mkfifo (Auth.credential_file base_path "fifo") 0o600;
       match Auth.list_credential_results base_path with
       | [Error (Auth.Unreadable_credential _)] -> ()
       | _ -> fail "nonregular diagnostic entry must be unreadable"); exit 0
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> prerr_endline (Printexc.to_string exn); exit 2)
  | pid ->
    let _, status = waitpid_nointr pid in
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      fail "diagnostic FIFO read must refuse without waiting for a writer"

let test_publication_fifo_snapshots_refuse_without_blocking () =
  match Unix.fork () with
  | 0 ->
    Sys.set_signal Sys.sigalrm Sys.Signal_default;
    let _previous_alarm_seconds = Unix.alarm 5 in
    (try List.iter (fun raw_fifo -> with_workspace (fun base_path ->
       let _pair = seed_pair base_path in
       let named = Auth.credential_file base_path "aaa" in
       let raw = Auth.raw_token_file base_path "aaa" in
       let occupied, counterpart = if raw_fifo then raw, named else named, raw in
       let previous = occupied ^ ".preserved" in
       let before = read counterpart in
       Unix.rename occupied previous; Unix.mkfifo occupied 0o600;
       check bool "supplied writer refuses special-file preflight" true
         (Result.is_error (Auth.save_file_backed_raw_token_credential base_path
           ~agent_name:"aaa" ~role:Masc_domain.Worker ~raw_token:"new-unpublished"));
       check bool "Keeper refuses special-file preflight" true
         (Result.is_error (Auth.ensure_keeper_credential base_path ~agent_name:"aaa"));
       (match rotate base_path with
        | Error _ when not raw_fifo -> ()
        | Ok [{Auth.rotated_agents = ("aaa", Error _) :: _; _}] when raw_fifo -> ()
        | _ -> fail "rotation must report the occupied special-file refusal");
       check string "counterpart remains unchanged" before (read counterpart);
       Unix.unlink occupied; Unix.rename previous occupied;
       let _restored = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"aaa") in
       check_recoverable base_path "aaa")) [false; true]; exit 0
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> prerr_endline (Printexc.to_string exn); exit 2)
  | pid ->
    let _, status = waitpid_nointr pid in
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      fail "publication must refuse FIFO paths without waiting for a writer"

let test_keeper_batch_updates_its_admitted_index () =
  with_workspace @@ fun base_path ->
  let _pair = seed_pair base_path in
  let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:[ "aaa"; "bbb" ]) in
  List.iter (fun (name, result) ->
    let token, current = auth_ok result in
    check string "batch result matches stored raw" token (current_raw base_path name);
    check bool "batch result matches current credential" true (current = credential base_path name);
    check_recoverable base_path name) results;
  check int "both requested owners are returned" 2 (List.length results)

let test_batch_retires_every_initially_shared_bearer () =
  with_workspace @@ fun base_path ->
  let _ = seed_pair base_path in
  let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["aaa"; "bbb"]) in
  List.iter (fun (name, result) ->
    let raw, _ = auth_ok result in
    check bool "each initial sharer changes bearer" false (String.equal raw shared);
    check_recoverable base_path name) results;
  check bool "the initially shared secret authenticates nobody" true
    (Result.is_error (Auth.find_credential_by_token base_path ~token:shared))

let test_batch_continues_after_raw_preflight_failure () =
  with_workspace @@ fun base_path ->
  let _ = seed_pair base_path in
  let path = Auth.raw_token_file base_path "aaa" in
  Unix.unlink path; Unix.mkdir path 0o700;
  let results = auth_ok (Auth.ensure_keeper_credentials base_path ~agent_names:["aaa"; "bbb"]) in
  (match results with
   | ["aaa", Error _; "bbb", Ok (raw, _)] ->
       check bool "later initial sharer still remints" false (String.equal raw shared);
       check_recoverable base_path "bbb"
   | _ -> fail "one raw preflight failure must not suppress the later Keeper")

let test_normalized_names_retain_bearer_authority () =
  with_workspace @@ fun base_path ->
  List.iteri (fun index name ->
    let raw = "normalized-credential-token-" ^ string_of_int index in
    let current = auth_ok (Auth.save_file_backed_raw_token_credential base_path
      ~agent_name:name ~role:Masc_domain.Worker ~raw_token:raw) in
    check bool "normalized owner appears in listing" true (List.mem current (Auth.list_credentials base_path));
    check string "token lookup retains original owner name" name
      (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name)
    ["Minsu"; "keeper:foo"]


let test_normalized_uuid_names_retain_bearer_authority () =
  with_workspace @@ fun base_path ->
  List.iteri (fun index name ->
    let raw, current = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:name) in
    let id = match current.id with
      | Some id -> id
      | None -> fail "Keeper fixture must publish a UUID credential" in
    let named = Auth.credential_file base_path name in
    let stub = Yojson.Safe.from_string (read named) in
    check bool "normalized named file is the UUID stub" true
      (stub = `Assoc ["redirect_to", `String (Masc_domain.Credential_id.to_string id ^ ".json")]);
    check string "UUID bearer resolves the original owner name" name
      (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name;
    let admitted = Auth.list_credentials base_path in
    check bool "UUID-backed normalized owner appears in listing" true (List.mem current admitted);
    let alias_name = "normalized-alias-" ^ string_of_int index in
    auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:name ~alias_name);
    check bool "alias resolves without becoming a second canonical owner" true
      (Auth.load_credential base_path alias_name = Some current);
    let failed_raw = "normalized-orphan-token-" ^ string_of_int index in
    let orphan_id = Masc_domain.Credential_id.of_string
      ("normalized-orphan-" ^ string_of_int index) in
    Auth.save_private_text_file
      (Auth.credential_file base_path (Masc_domain.Credential_id.to_string orphan_id))
      (Masc_domain.agent_credential_to_yojson
         { current with id = Some orphan_id; token = Auth.sha256_hash failed_raw }
       |> Yojson.Safe.to_string);
    (* Republish the unchanged canonical credential through the public writer
       to invalidate bearer lookup without retiring the alias or orphan. *)
    Auth.save_credential base_path current;
    check bool "aliases and orphan UUID do not change the owner listing" true
      (List.sort Stdlib.compare (Auth.list_credentials base_path)
       = List.sort Stdlib.compare admitted);
    check bool "diagnostic listing excludes aliases and orphan UUID records" true
      (List.sort Stdlib.compare (List.filter_map Result.to_option
         (Auth.list_credential_results base_path)) = List.sort Stdlib.compare admitted);
    check bool "normalized orphan payload cannot authenticate" true
      (Result.is_error (Auth.find_credential_by_token base_path ~token:failed_raw));
    check string "canonical UUID bearer retains authority after orphan publication" name
      (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name)
    ["Minsu"; "keeper:foo"]

let test_minted_bearer_survives_retirement_failure () =
  with_workspace @@ fun base_path ->
  let _, prior = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:"aaa") in
  let id = match prior.id with Some id -> id | None -> fail "expected UUID-backed fixture" in
  let target = Auth.credential_file base_path (Masc_domain.Credential_id.to_string id) in
  Unix.unlink target;
  Unix.mkdir target 0o700;
  let raw, current = auth_ok (Auth.create_token base_path ~agent_name:"aaa" ~role:Masc_domain.Worker) in
  check string "returned bearer matches committed named record" current.token (Auth.sha256_hash raw);
  check string "returned bearer authenticates" "aaa"
    (auth_ok (Auth.find_credential_by_token base_path ~token:raw)).agent_name;
  check bool "cleanup failure remains observable on disk" true (Sys.is_directory target)

let () =
  run "auth_token_rotation_transaction"
    [ "rotation",
      [ test_case "Keeper ensure rejects forged foreign UUID before publication" `Quick test_keeper_ensure_refuses_foreign_uuid_before_publication
      ; test_case "Keeper ensure rejects foreign aliases with or without raw" `Quick test_keeper_ensure_refuses_another_owner_alias
      ; test_case "Keeper refuses absent and case-variant UUID collisions" `Quick test_keeper_ensure_refuses_absent_uuid_collisions
      ; test_case "Keeper same-owner partial UUID retry" `Quick test_keeper_same_owner_partial_uuid_retry
      ; test_case "batch retires every initial shared bearer" `Quick test_batch_retires_every_initially_shared_bearer
      ; test_case "batch continues after raw preflight refusal" `Quick test_batch_continues_after_raw_preflight_failure
      ; test_case "normalized names retain bearer authority" `Quick test_normalized_names_retain_bearer_authority
      ; test_case "normalized UUID names retain bearer authority" `Quick test_normalized_uuid_names_retain_bearer_authority
      ; test_case "minted bearer survives superseded payload cleanup failure" `Quick test_minted_bearer_survives_retirement_failure
      ; test_case "unselected case-variant UUID refuses before writes" `Quick test_unselected_case_variant_uuid_refused
      ; test_case "unpublished UUID cannot grant bearer authority" `Quick test_unpublished_uuid_has_no_bearer_authority
      ; test_case "retired UUID cannot retain bearer authority" `Quick test_retired_uuid_has_no_bearer_authority
      ; test_case "publication snapshots refuse FIFO without blocking" `Quick test_publication_fifo_snapshots_refuse_without_blocking
      ; test_case "extended redirects remain current owners" `Quick test_extended_redirect_remains_a_current_owner
      ; test_case "diagnostic listing refuses FIFO without blocking" `Quick test_fifo_diagnostic_listing_refuses_without_blocking
      ; test_case "same-owner partial UUID publication can retry" `Quick test_same_owner_partial_uuid_can_retry
      ; test_case "noncanonical UUID refuses before writes" `Quick test_noncanonical_uuid_is_refused
      ; test_case "failed supplied-token write preserves old bearer" `Quick test_failed_supplied_token_preserves_previous_raw
      ; test_case "failed Keeper remint preserves previous pair" `Quick test_failed_keeper_remint_preserves_previous_pair
      ; test_case "batch Keeper sync updates its admitted index" `Quick test_keeper_batch_updates_its_admitted_index
      ; test_case "unique owner UUID collision refuses before writes" `Quick test_unique_owner_uuid_collision_refused
      ; test_case "one selected owner in a global shared group rotates" `Quick test_one_selected_owner_rotates
      ; test_case "keeper publisher before rotation" `Quick test_keeper_before_rotation
      ; test_case "rotation before keeper publisher" `Quick test_rotation_before_keeper
      ; test_case "Admin renewal before rotation" `Quick test_admin_before_rotation
      ; test_case "rotation before Admin renewal" `Quick test_rotation_before_admin
      ; test_case "prune before rotation cannot resurrect credentials" `Quick test_prune_before_rotation
      ; test_case "rotation before prune retains recoverable raw tokens" `Quick test_rotation_before_prune
      ; test_case "revoke before rotation cannot resurrect credentials" `Quick test_revoke_before_rotation
      ; test_case "rotation before revoke is removed completely" `Quick test_rotation_before_revoke
      ; test_case "failed admission preserves every file" `Quick test_failed_admission
      ; test_case "read failure precedes every write" `Quick test_read_failure
      ; test_case "malformed config returns outer Error before writes" `Quick test_config_failure
      ; test_case "ambiguous names remain unchanged" `Quick test_ambiguous_names_preserved
      ; test_case "raw failure reports state and later owner succeeds" `Quick test_raw_failure_continues
      ; test_case "credential failure reports already published raw tokens" `Quick test_credential_failure_after_raw_publication
      ; test_case "UUID owners and legitimate aliases remain valid" `Quick test_uuid_owners_and_aliases
      ; test_case "forged UUID and traversal refuse before writes" `Quick test_forged_uuid_refused
      ; test_case "UUID cannot collide with its named redirect" `Quick test_self_redirect_refused
      ; test_case "absent UUID write target cannot be shared" `Quick test_absent_uuid_collision_refused ] ]
