open Alcotest

module Usage = Runtime_provider_usage_window

let decode decoder json =
  match decoder (Yojson.Safe.from_string json) with
  | Ok report -> report
  | Error detail -> fail (Usage.decode_error_to_string detail)

let scope name = Runtime_quota_window.scope_of_credential ~provider_id:name None

let test_cap_removed_and_empty_report () =
  let scope = scope "snapshot_credit_lifecycle" in
  let cap = decode Usage.decode_openrouter_key
      {|{"data":{"limit":20,"limit_remaining":0}}|} in
  Usage.record ~scope ~observed_at:100. cap;
  let uncapped = decode Usage.decode_openrouter_key
      {|{"data":{"limit":null,"usage":21.5}}|} in
  Usage.record ~scope ~observed_at:101. uncapped;
  (match Usage.state ~scope with
   | Reported ({ window = { utilization = Usd { used; limit = None }; _ }; _ }, []) ->
       check (float 0.0001) "the removed cap leaves only uncapped USD use" 21.5 used
   | _ -> fail "old credit limit survived its removal");
  Usage.record ~scope ~observed_at:102.
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|});
  Usage.record ~scope ~observed_at:100.5 cap;
  match Usage.state ~scope with
  | Reported_no_windows { observed_at; source = Openrouter_key_read } ->
      check (float 0.) "empty report is retained and stale cap cannot return" 102. observed_at
  | _ -> fail "a removed cap returned or the empty report was lost"

let test_disabled_antigravity_bucket () =
  let scope = scope "snapshot_antigravity_lifecycle" in
  let report disabled = decode Usage.decode_antigravity_usage (Printf.sprintf
      {|{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"week","window":"weekly","remaining_fraction":0},{"id":"short","window":"5h","remaining_fraction":0,"disabled":%b}]}]}}}|}
      disabled) in
  Usage.record ~scope ~observed_at:100. (report false);
  Usage.record ~scope ~observed_at:101. (report true);
  match Usage.state ~scope with
  | Reported ({ window = { limit_id = Some "week"; _ }; _ }, []) -> ()
  | _ -> fail "disabled Antigravity bucket is still displayed"

let test_sparse_codex_update () =
  let scope = scope "snapshot_codex_sparse" in
  let report json = decode Usage.decode_codex_rate_limits_updated json in
  Usage.record ~scope ~observed_at:100.
    (report {|{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}|});
  Usage.record ~scope ~observed_at:101.
    (report {|{"rateLimits":{"primary":null,"secondary":{"usedPercent":21,"windowDurationMins":10080}}}|});
  match Usage.state ~scope with
  | Reported ({ window = { kind = Five_hour; utilization = Percent 100; _ }; _ },
      [{ window = { kind = Seven_day; utilization = Percent 21; _ }; _ }]) -> ()
  | _ -> fail "sparse update erased an unstated window"

let () =
  run "provider usage snapshots"
    [ "account lifecycle",
      [ test_case "removed credit cap and empty report" `Quick test_cap_removed_and_empty_report
      ; test_case "disabled Antigravity bucket" `Quick test_disabled_antigravity_bucket
      ; test_case "sparse Codex update" `Quick test_sparse_codex_update ] ]
