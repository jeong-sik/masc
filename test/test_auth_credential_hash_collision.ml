(* test/test_auth_credential_hash_collision.ml

   PR-MASC-4: full credential comparison on shared token hash.

   Pins the pure comparison function and the lookup behavior:
   - Equal credentials -> Equal
   - Same hash, different agent_name -> Different with structured log
   - Same hash, different role -> Different
   - Unknown token -> Error
   - Single hash match -> Ok
   - Artificially equal hashes on distinct credentials -> Error *)

let token_hash_prefix = "deadbeef1234"

let base_credential ~agent_name ~role =
  { Masc_domain.id = None
  ; agent_id = None
  ; agent_name
  ; token = "samehashforall"
  ; role
  ; created_at = "2026-06-24T00:00:00Z"
  ; expires_at = None
  }

let test_compare_equal_credentials () =
  let a = base_credential ~agent_name:"alice" ~role:Masc_domain.Worker in
  let b = base_credential ~agent_name:"alice" ~role:Masc_domain.Worker in
  match Auth.compare_credentials ~token_hash_prefix a b with
  | Equal -> ()
  | Different _ -> Alcotest.fail "expected Equal for identical credentials"

let test_compare_different_agent_name () =
  let a = base_credential ~agent_name:"alice" ~role:Masc_domain.Worker in
  let b = base_credential ~agent_name:"bob" ~role:Masc_domain.Worker in
  match Auth.compare_credentials ~token_hash_prefix a b with
  | Equal -> Alcotest.fail "expected Different for distinct agent_name"
  | Different log ->
    Alcotest.(check string) "left agent" "alice" log.left_agent;
    Alcotest.(check string) "right agent" "bob" log.right_agent;
    Alcotest.(check bool) "has agent_name diff" true
      (List.exists
         (function
           | Auth.Agent_name _ -> true
           | _ -> false)
         log.field_diffs)

let test_compare_different_role () =
  let a = base_credential ~agent_name:"alice" ~role:Masc_domain.Worker in
  let b = base_credential ~agent_name:"alice" ~role:Masc_domain.Admin in
  match Auth.compare_credentials ~token_hash_prefix a b with
  | Equal -> Alcotest.fail "expected Different for distinct role"
  | Different log ->
    Alcotest.(check bool) "has role diff" true
      (List.exists
         (function
           | Auth.Role _ -> true
           | _ -> false)
         log.field_diffs)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun e -> rm_rf (Filename.concat path e));
      Unix.rmdir path)
    else
      Sys.remove path

let with_temp_base f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-hash-collision-%06x" (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () -> f base)

let write_cred ~base ~agent_name ~role ~token_hash =
  (* Write through the production writer so a credential schema change breaks
     this fixture at compile time instead of at [of_yojson] runtime. The
     hand-written JSON this replaces omitted [id]/[agent_id]/[expires_at], which
     the decoder requires as keys even where the record type defaults them. *)
  let cred : Masc_domain.agent_credential =
    { id = None
    ; agent_id = None
    ; agent_name
    ; token = token_hash
    ; role = role
    ; created_at = "2026-06-24T00:00:00Z"
    ; expires_at = None
    }
  in
  Auth.save_credential base cred

let test_unknown_token_is_mismatch () =
  with_temp_base (fun base ->
    let raw = "known_raw_token_collision" in
    let hash = Auth.sha256_hash raw in
    write_cred ~base ~agent_name:"alice" ~role:Masc_domain.Worker ~token_hash:hash;
    match Auth.find_credential_by_token base ~token:"totally-unknown-token" with
    | Ok cred ->
      Alcotest.fail
        (Printf.sprintf "expected mismatch for unknown token, got %s" cred.agent_name)
    | Error _ -> ())

let test_single_match_returns_ok () =
  with_temp_base (fun base ->
    let raw = "single_match_collision" in
    let hash = Auth.sha256_hash raw in
    write_cred ~base ~agent_name:"alice" ~role:Masc_domain.Worker ~token_hash:hash;
    match Auth.find_credential_by_token base ~token:raw with
    | Ok cred -> Alcotest.(check string) "resolved agent" "alice" cred.agent_name
    | Error e ->
      Alcotest.fail
        (Printf.sprintf "expected Ok for single match, got %s" (Masc_domain.show_masc_error e)))

let test_artificially_equal_hashes_reject () =
  with_temp_base (fun base ->
    let raw = "shared_raw_token_collision" in
    let hash = Auth.sha256_hash raw in
    write_cred ~base ~agent_name:"alice" ~role:Masc_domain.Worker ~token_hash:hash;
    write_cred ~base ~agent_name:"bob" ~role:Masc_domain.Worker ~token_hash:hash;
    match Auth.find_credential_by_token base ~token:raw with
    | Ok cred ->
      Alcotest.fail
        (Printf.sprintf "expected collision error, got Ok for %s" cred.agent_name)
    | Error _ -> ())

let () =
  Random.self_init ();
  Alcotest.run "auth_credential_hash_collision"
    [ ( "compare_credentials"
      , [ Alcotest.test_case "equal credentials" `Quick test_compare_equal_credentials
        ; Alcotest.test_case "different agent_name" `Quick test_compare_different_agent_name
        ; Alcotest.test_case "different role" `Quick test_compare_different_role
        ] )
    ; ( "find_credential_by_token"
      , [ Alcotest.test_case "unknown token -> Error" `Quick test_unknown_token_is_mismatch
        ; Alcotest.test_case "single match -> Ok" `Quick test_single_match_returns_ok
        ; Alcotest.test_case "artificially equal hashes -> Error" `Quick
            test_artificially_equal_hashes_reject
        ] )
    ]
