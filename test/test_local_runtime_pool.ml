let test_runtime_id_of_base_url () =
  let id = Local_runtime_pool.runtime_id_of_base_url in
  Alcotest.(check string) "port 19001" "local-19001" (id "http://127.0.0.1:19001");
  Alcotest.(check string) "port 11434" "local-11434" (id "http://127.0.0.1:11434");
  Alcotest.(check string) "no port uses the MD5 prefix" "local-86a9106a"
    (id "http://localhost");
  Alcotest.(check string) "same url, same id" (id "http://example.test")
    (id "http://example.test");
  Alcotest.(check bool) "different urls without a port differ" false
    (String.equal (id "http://localhost") (id "http://example.test"))

let test_missing_discovery_is_scoped_not_fleet_health () =
  let open Yojson.Safe.Util in
  let result = Masc.Tool_local_runtime_verify.runtime_verify_json () in
  Alcotest.(check string) "local verification scope"
    "local_openai_compatible_runtime_pool"
    (result |> member "verification_scope" |> to_string);
  Alcotest.(check bool) "does not block Keeper turns" false
    (result |> member "blocks_keeper_turns" |> to_bool);
  Alcotest.(check string) "fleet provider health is not assessed"
    "not_assessed"
    (result |> member "fleet_provider_health" |> to_string)

let () =
  Alcotest.run "test_local_runtime_pool"
    [
      ( "local_runtime_pool",
        [
          Alcotest.test_case "runtime id from base url" `Quick
            test_runtime_id_of_base_url;
          Alcotest.test_case "missing discovery is local-only" `Quick
            test_missing_discovery_is_scoped_not_fleet_health;
        ] );
    ]
