(** Unit tests for [Masc_mcp.Cascade_saturation_signal].

    RFC-0153 Phase A.1. Phase A.1 단독 module은 행동 변경이 없으므로
    test는 *직렬화 + equality + exhaustive kind* 검증만 수행. caller
    integration 은 Phase A.2 의 별도 test 가 다룬다. *)

module S = Masc_mcp.Cascade_saturation_signal

let s = Alcotest.testable S.pp S.equal

let kind_t : S.kind Alcotest.testable =
  let pp ppf k = Format.fprintf ppf "%s" (S.kind_to_string k) in
  let eq a b =
    match (a, b) with
    | S.K_provider_rate_limited, S.K_provider_rate_limited
    | K_time_cap_fired, K_time_cap_fired
    | K_all_tiers_filtered_after_cycles, K_all_tiers_filtered_after_cycles
    | K_inflight_capacity_full, K_inflight_capacity_full ->
        true
    | _ -> false
  in
  Alcotest.testable pp eq

(* Sample values used across tests *)

let sample_provider_rate_limited =
  S.Provider_rate_limited
    { provider_id = "runpod_mtp"; retry_after_ms = Some 1200 }

let sample_time_cap_fired =
  S.Time_cap_fired
    { observed_latency_ms = 300100;
      cap_ms = 300000;
      provider_id = Some "glm-coding";
    }

let sample_time_cap_fired_no_provider =
  S.Time_cap_fired
    { observed_latency_ms = 305000;
      cap_ms = 300000;
      provider_id = None;
    }

let sample_all_filtered =
  S.All_tiers_filtered_after_cycles
    { cascade_name = "strict_tool_candidates"; cycle_count = 3 }

let sample_inflight_full =
  S.Inflight_capacity_full
    { tier_id = "strict_tool_candidates"; max_inflight = 8 }

let all_samples =
  [ sample_provider_rate_limited;
    sample_time_cap_fired;
    sample_time_cap_fired_no_provider;
    sample_all_filtered;
    sample_inflight_full;
  ]

(* {1 equality} *)

let test_equal_reflexive () =
  List.iter (fun v -> Alcotest.check s "equal-reflexive" v v) all_samples

let test_equal_distinct () =
  let pairs =
    [ (sample_provider_rate_limited, sample_time_cap_fired);
      (sample_time_cap_fired, sample_time_cap_fired_no_provider);
      (sample_all_filtered, sample_inflight_full);
    ]
  in
  List.iter
    (fun (a, b) ->
      Alcotest.check Alcotest.bool "distinct-not-equal" false (S.equal a b))
    pairs

(* {1 kind exhaustiveness} *)

let test_kind_mapping () =
  Alcotest.check kind_t "provider_rate_limited" S.K_provider_rate_limited
    (S.kind sample_provider_rate_limited);
  Alcotest.check kind_t "time_cap_fired" S.K_time_cap_fired
    (S.kind sample_time_cap_fired);
  Alcotest.check kind_t "all_tiers_filtered_after_cycles"
    S.K_all_tiers_filtered_after_cycles (S.kind sample_all_filtered);
  Alcotest.check kind_t "inflight_capacity_full" S.K_inflight_capacity_full
    (S.kind sample_inflight_full)

let test_kind_to_string () =
  Alcotest.(check string)
    "provider_rate_limited" "provider_rate_limited"
    (S.kind_to_string S.K_provider_rate_limited);
  Alcotest.(check string)
    "time_cap_fired" "time_cap_fired"
    (S.kind_to_string S.K_time_cap_fired);
  Alcotest.(check string)
    "all_tiers_filtered_after_cycles" "all_tiers_filtered_after_cycles"
    (S.kind_to_string S.K_all_tiers_filtered_after_cycles);
  Alcotest.(check string)
    "inflight_capacity_full" "inflight_capacity_full"
    (S.kind_to_string S.K_inflight_capacity_full)

(* {1 log/metric string format} *)

let test_log_strings_contain_kind () =
  List.iter
    (fun v ->
      let log = S.to_log_string v in
      let kind = S.kind_to_string (S.kind v) in
      let starts_with prefix str =
        String.length str >= String.length prefix
        && String.sub str 0 (String.length prefix) = prefix
      in
      Alcotest.(check bool)
        ("log-line starts with kind " ^ kind)
        true (starts_with kind log))
    all_samples

let test_metric_label_matches_kind () =
  List.iter
    (fun v ->
      Alcotest.(check string)
        "metric label = kind string"
        (S.kind_to_string (S.kind v))
        (S.to_metric_label v))
    all_samples

(* {1 yojson round-trip} *)

let test_yojson_round_trip () =
  List.iter
    (fun v ->
      let j = S.to_yojson v in
      match S.of_yojson j with
      | Ok decoded -> Alcotest.check s "yojson round-trip" v decoded
      | Error e -> Alcotest.failf "yojson decode failed: %s" e)
    all_samples

let test_yojson_unknown_kind_rejected () =
  let bogus = `Assoc [ ("kind", `String "definitely_not_a_real_kind") ] in
  match S.of_yojson bogus with
  | Ok _ -> Alcotest.fail "expected Error on unknown kind"
  | Error _ -> ()

let test_yojson_missing_field_rejected () =
  let bogus =
    `Assoc [ ("kind", `String "time_cap_fired"); ("cap_ms", `Int 300000) ]
  in
  match S.of_yojson bogus with
  | Ok _ -> Alcotest.fail "expected Error on missing field"
  | Error _ -> ()

(* {1 driver} *)

let suite =
  [ ( "equal",
      [ Alcotest.test_case "reflexive" `Quick test_equal_reflexive;
        Alcotest.test_case "distinct" `Quick test_equal_distinct;
      ] );
    ( "kind",
      [ Alcotest.test_case "mapping" `Quick test_kind_mapping;
        Alcotest.test_case "to_string" `Quick test_kind_to_string;
      ] );
    ( "format",
      [ Alcotest.test_case "log starts with kind" `Quick
          test_log_strings_contain_kind;
        Alcotest.test_case "metric label = kind" `Quick
          test_metric_label_matches_kind;
      ] );
    ( "yojson",
      [ Alcotest.test_case "round trip" `Quick test_yojson_round_trip;
        Alcotest.test_case "unknown kind rejected" `Quick
          test_yojson_unknown_kind_rejected;
        Alcotest.test_case "missing field rejected" `Quick
          test_yojson_missing_field_rejected;
      ] );
  ]

let () = Alcotest.run "cascade_saturation_signal" suite
