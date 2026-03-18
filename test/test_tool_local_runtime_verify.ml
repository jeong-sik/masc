open Alcotest

let test_provider_health_reachable_accepts_json_health () =
  check bool "json health body counts as reachable" true
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 200)
       ~body:(Some {|{"status":"ok"}|}));
  check bool "plain text health body counts as reachable" true
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 200)
       ~body:(Some "ok"));
  check bool "non-200 is unreachable" false
    (Masc_mcp.Tool_local_runtime.provider_health_reachable ~status:(Some 503)
       ~body:(Some {|{"status":"error"}|}))

let test_classify_runtime_blocker_prefers_slot_count_when_health_ok () =
  let blocker, detail =
    Masc_mcp.Tool_local_runtime.classify_runtime_blocker ~provider_reachable:true
      ~slot_reachable:true
      ~expected_model:(Some "qwen3.5-35b-a3b-ud-q8-xl")
      ~actual_model_id:(Some "qwen3.5-35b-a3b-ud-q8-xl")
      ~expected_slots:(Some 12) ~actual_slots_total:4
      ~expected_ctx:(Some 262144) ~actual_ctx:(Some 262144)
  in
  check (option string) "slot blocker" (Some "slot_count_insufficient")
    blocker;
  check bool "detail mentions expected slots" true
    (match detail with
    | Some msg -> String.contains msg '1' && String.contains msg '4'
    | None -> false)

let () =
  run "tool_local_runtime_verify"
    [
      ( "provider_health_reachable",
        [
          test_case "accepts json health payload" `Quick
            test_provider_health_reachable_accepts_json_health;
        ] );
      ( "runtime_blocker",
        [
          test_case "slot shortage beats provider_unreachable" `Quick
            test_classify_runtime_blocker_prefers_slot_count_when_health_ok;
        ] );
    ]
