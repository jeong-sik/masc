(* Authentication follows the current named owner, even when the old UUID
   payload survives external replacement. Both cold and warm indexes exercise
   production bearer, alias, Play permission and MCP authorization entrypoints. *)
open Alcotest
module D = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()
let auth_ok = function
  | Ok value -> value
  | Error error -> fail (D.masc_error_to_string error)

let with_workspace f =
  let base_path = Filename.temp_dir "credential-index-authority-" "" in
  Masc_test_deps.with_process_env "MASC_OAUTH_ENABLED" (Some "0") (fun () ->
    Eio_main.run @@ fun env ->
    Masc_test_deps.init_eio_clock env;
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ())
      (fun () -> Auth.save_auth_config base_path D.default_auth_config; f base_path))

let read path = In_channel.with_open_bin path In_channel.input_all
let request token path = Httpun.Request.create
  ~headers:(Httpun.Headers.of_list [ "Authorization", "Bearer " ^ token ]) `POST path

let play_admin base_path token =
  Server_auth.authorize_token_bound_permission_request ~base_path ~permission:D.CanAdmin
    (request token "/api/v1/play/invites")

let mcp base_path token =
  let request_authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority
    | Error `Malformed -> fail "fixture request authority must be valid" in
  Server_auth.verify_mcp_auth_for_authority ~base_path ~request_authority (request token "/mcp")

let denied label = function
  | Error _ -> ()
  | Ok _ -> fail label

let seed_admin base_path name =
  let token, worker = auth_ok (Auth.ensure_keeper_credential base_path ~agent_name:name) in
  let admin = { worker with D.role = D.Admin } in
  Auth.save_credential base_path admin;
  let uuid = match admin.id with
    | Some id -> Auth.credential_file base_path (D.Credential_id.to_string id)
    | None -> fail "fixture requires a UUID-backed old Admin" in
  token, admin, uuid

type named_state = Missing_name | Malformed_name | Current_worker

let test_old_uuid_cannot_authorize ~warm state = with_workspace @@ fun base_path ->
  let name = "operator" in
  let old_token, old_admin, uuid = seed_admin base_path name in
  let old_bytes = read uuid in
  let uuid_name = Filename.basename uuid |> Filename.remove_extension in
  let stored_alias = "short-operator" in
  let () = auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:name ~alias_name:stored_alias) in
  let alias_file = Auth.credential_file base_path stored_alias in
  let alias_bytes = read alias_file in
  List.iter (fun agent_name ->
    check bool "bound UUID and stored alias verify before the transition" true
      (auth_ok (Auth.verify_token base_path ~agent_name ~token:old_token) = old_admin);
    let () = auth_ok (Auth.check_permission base_path ~agent_name ~token:(Some old_token)
      ~permission:D.CanAdmin) in ()) [ uuid_name; stored_alias ];
  if warm then (
    check bool "old Admin is valid before the external transition" true
      (auth_ok (Auth.find_static_credential_by_token base_path ~token:old_token) = old_admin));
  let new_token = "current-worker-index-authority-fixture" in
  let replacement = { old_admin with D.id = None; role = D.Worker; token = Auth.sha256_hash new_token } in
  let named = Auth.credential_file base_path name in
  (* This intentionally bypasses the Auth writer/cache invalidator, matching
     ordinary external credential replacement. The UUID stays intact. *)
  (match state with
   | Missing_name -> Unix.unlink named
   | Malformed_name -> Auth.save_private_text_file named "{"
   | Current_worker -> Auth.save_private_text_file named
       (D.agent_credential_to_yojson replacement |> Yojson.Safe.to_string));
  List.iter (fun agent_name ->
    let rejected label = function
      | Error (D.Auth (D.Auth_error.InvalidToken _)) -> ()
      | Error error -> fail (D.masc_error_to_string error)
      | Ok _ -> fail label in
    rejected "bound UUID or stored alias verified the retired Admin"
      (Auth.verify_token base_path ~agent_name ~token:old_token);
    rejected "bound UUID or stored alias granted CanAdmin to the retired Admin"
      (Auth.check_permission base_path ~agent_name ~token:(Some old_token)
        ~permission:D.CanAdmin)) [ uuid_name; stored_alias ];
  denied "old UUID Admin authenticated as a static bearer"
    (Auth.find_static_credential_by_token base_path ~token:old_token);
  denied "old UUID Admin authenticated through general bearer lookup"
    (Auth.find_credential_by_token base_path ~token:old_token);
  denied "named verification recovered old Admin through alias fallback"
    (Auth.verify_token base_path ~agent_name:name ~token:old_token);
  denied "a generated alias recovered the old UUID Admin"
    (Auth.verify_token base_path ~agent_name:"operator-fair-tapir" ~token:old_token);
  denied "Play token-bound CanAdmin accepted the old UUID Admin" (play_admin base_path old_token);
  denied "MCP authorization accepted the old UUID Admin" (mcp base_path old_token);
  (match state with
   | Missing_name | Malformed_name ->
     check bool "unknown current name has no authoritative credential" true
       (Auth.load_credential base_path name = None)
   | Current_worker ->
     check bool "replacement bearer resolves the complete current Worker" true
       (auth_ok (Auth.find_credential_by_token base_path ~token:new_token) = replacement);
     check bool "current Worker is verified by exact name" true
       (auth_ok (Auth.verify_token base_path ~agent_name:name ~token:new_token) = replacement);
     check bool "current Worker keeps generated alias continuity" true
       (auth_ok (Auth.verify_token base_path ~agent_name:"operator-fair-tapir" ~token:new_token) = replacement);
     (match play_admin base_path new_token with
      | Error (D.Auth (D.Auth_error.Forbidden _)) -> ()
      | Error error -> fail (D.masc_error_to_string error)
      | Ok _ -> fail "Play must not promote the replacement Worker to Admin");
     check bool "normal MCP still authorizes the current Worker" true (Result.is_ok (mcp base_path new_token)));
  check string "authorization preserves the stored alias bytes" alias_bytes (read alias_file);
  check bool "stored alias remains readable as old credential data" true
    (Auth.load_credential base_path stored_alias = Some old_admin);
  check string "authorization did not delete or mutate the old UUID evidence" old_bytes (read uuid);
  check bool "direct UUID data lookup remains available" true
    (Auth.load_credential base_path (D.Credential_id.to_string
      (match old_admin.id with Some id -> id | None -> fail "fixture UUID vanished")) = Some old_admin)

let test_current_uuid_and_aliases_remain_authoritative () = with_workspace @@ fun base_path ->
  let token, admin, uuid = seed_admin base_path "alpha" in
  let before = read uuid in
  let () = auth_ok (Auth.ensure_credential_alias base_path ~canonical_name:"alpha" ~alias_name:"short-alpha") in
  List.iter (fun agent_name ->
    check bool "current canonical and supported aliases preserve the full Admin" true
      (auth_ok (Auth.verify_token base_path ~agent_name ~token) = admin);
    let () = auth_ok (Auth.check_permission base_path ~agent_name ~token:(Some token)
      ~permission:D.CanAdmin) in ())
    [ "alpha"; Filename.basename uuid |> Filename.remove_extension;
      "short-alpha"; "alpha-fair-tapir"; "keeper-alpha-agent" ];
  check bool "current UUID-backed bearer authenticates" true
    (auth_ok (Auth.find_static_credential_by_token base_path ~token) = admin);
  check string "Play resolves current Admin actor" "alpha" (auth_ok (play_admin base_path token));
  check bool "MCP authorizes current UUID owner" true (Result.is_ok (mcp base_path token));
  check string "alias reads preserve UUID bytes" before (read uuid)

let () = run "credential index named authority" [ "bearer authority", [
  test_case "cold index rejects intact UUID with missing name" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:false Missing_name);
  test_case "warm index rejects intact UUID with missing name" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:true Missing_name);
  test_case "cold index rejects intact UUID with malformed name" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:false Malformed_name);
  test_case "warm index rejects intact UUID with malformed name" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:true Malformed_name);
  test_case "cold index uses current Worker over old Admin UUID" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:false Current_worker);
  test_case "warm index uses current Worker over old Admin UUID" `Quick (fun () -> test_old_uuid_cannot_authorize ~warm:true Current_worker);
  test_case "current UUID owner and supported aliases keep authority" `Quick test_current_uuid_and_aliases_remain_authoritative;
] ]
