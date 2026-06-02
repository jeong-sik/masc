(* #9786: [Auth.audit_token_uniqueness] surfaces credentials
   sharing the same bearer token hash.  Tests pin:
   - empty store / unique tokens → []
   - two creds with same hash → one group with both names
   - three creds, two share / one unique → only the shared pair
   - returned hash is a 12-char prefix (not the full hash) *)

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
      (Printf.sprintf "masc-9786-%06x" (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () -> f base)

(* Create a credential file directly under [<base>/.masc/auth/agents/].
   Bypasses the Auth API on purpose so we can craft duplicates
   without [save_raw_token_credential] re-hashing. *)
let write_cred ~base ~agent_name ~token_hash =
  let agents_dir =
    Filename.concat base ".masc/auth/agents"
  in
  let rec mkdirs p =
    if Sys.file_exists p then ()
    else begin
      mkdirs (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error _ -> ()
    end
  in
  mkdirs agents_dir;
  let path = Filename.concat agents_dir (agent_name ^ ".json") in
  let json =
    Printf.sprintf
      "{\"agent_name\":%S,\"token\":%S,\"role\":\"worker\",\"created_at\":\"2026-04-25T00:00:00Z\"}"
      agent_name token_hash
  in
  let oc = open_out path in
  output_string oc json;
  close_out oc

let test_empty_store_returns_empty () =
  with_temp_base (fun base ->
    let groups = Masc_mcp.Auth.audit_token_uniqueness base in
    Alcotest.(check int) "empty store" 0 (List.length groups))

let test_unique_tokens_return_empty () =
  with_temp_base (fun base ->
    write_cred ~base ~agent_name:"alpha" ~token_hash:"hash_alpha_12345678";
    write_cred ~base ~agent_name:"beta"  ~token_hash:"hash_beta_12345678_";
    let groups = Masc_mcp.Auth.audit_token_uniqueness base in
    Alcotest.(check int) "no duplicate groups" 0 (List.length groups))

let test_shared_token_surfaces_pair () =
  with_temp_base (fun base ->
    let shared = "shared_token_hash_value_with_enough_length" in
    write_cred ~base ~agent_name:"keeper-sangsu-agent" ~token_hash:shared;
    write_cred ~base ~agent_name:"nick0cave-sage-heron" ~token_hash:shared;
    let groups = Masc_mcp.Auth.audit_token_uniqueness base in
    match groups with
    | [ (prefix, agents) ] ->
        Alcotest.(check int) "exactly 2 agents in group"
          2 (List.length agents);
        Alcotest.(check (list string)) "agents sorted"
          [ "keeper-sangsu-agent"; "nick0cave-sage-heron" ]
          agents;
        Alcotest.(check int) "prefix is 12 chars"
          12 (String.length prefix);
        Alcotest.(check string) "prefix matches token start"
          "shared_token" prefix
    | _ ->
        Alcotest.failf "expected exactly 1 duplicate group, got %d"
          (List.length groups))

let test_mixed_unique_and_shared () =
  with_temp_base (fun base ->
    write_cred ~base ~agent_name:"unique-1" ~token_hash:"unique_hash_AAA_long";
    let shared = "shared_hash_BBB_long_enough_value" in
    write_cred ~base ~agent_name:"shared-a" ~token_hash:shared;
    write_cred ~base ~agent_name:"shared-b" ~token_hash:shared;
    write_cred ~base ~agent_name:"unique-2" ~token_hash:"unique_hash_CCC_long";
    let groups = Masc_mcp.Auth.audit_token_uniqueness base in
    Alcotest.(check int) "one duplicate group" 1 (List.length groups);
    match groups with
    | [ (_, agents) ] ->
        Alcotest.(check (list string)) "shared pair"
          [ "shared-a"; "shared-b" ] agents
    | _ -> Alcotest.fail "unreachable")

let () =
  Random.self_init ();
  Alcotest.run "auth_token_uniqueness_audit_9786" [
    "audit", [
      Alcotest.test_case "empty store" `Quick
        test_empty_store_returns_empty;
      Alcotest.test_case "unique tokens → empty" `Quick
        test_unique_tokens_return_empty;
      Alcotest.test_case "shared token surfaces pair" `Quick
        test_shared_token_surfaces_pair;
      Alcotest.test_case "mixed unique + shared" `Quick
        test_mixed_unique_and_shared;
    ];
  ]
