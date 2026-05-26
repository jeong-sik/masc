(* test/test_oas_error_kind_counter.ml

   #9933: verify that [Keeper_turn_driver.sdk_error_of_masc_internal_error]
   emits [masc_oas_error_total{kind}] once per constructed error so
   Grafana can alert on per-kind rates without parsing the
   free-form BDI blocker string.  Exercises all 9 variants of
   [masc_internal_error] (the single production source of
   [masc_oas_error] payloads). *)

module OWN = Masc_mcp.Keeper_turn_driver
module Prom = Masc_mcp.Prometheus

let typed_cascade_name = Cascade_name.of_string_exn

(* #10285: cascade_name label was added.  Query [(kind, cascade_name)]
   pair.  Tests that only care about kind regardless of cascade pass
   the expected cascade_name explicitly so assertions stay exact. *)
let counter_for ?(cascade_name = "unknown") kind =
  Prom.metric_value_or_zero
    OWN.masc_oas_error_total_metric
    ~labels:[ ("kind", kind); ("cascade_name", cascade_name) ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "canonical oas error total metric name"
    "masc_oas_error_total"
    OWN.masc_oas_error_total_metric

let test_provider_timeout_kind () =
  let kind = "provider_timeout" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Provider_timeout
         {
           budget_sec = 423.8;
           keeper_turn_timeout_sec = 1200.0;
           estimated_input_tokens = 2519;
           source = "turn_budget";
           remaining_turn_budget_sec = Some 300.0;
           min_required_sec = 15.0;
           phase = "test_phase";
         })
  in
  Alcotest.(check (float 0.0001))
    "provider_timeout counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_turn_timeout_kind () =
  let kind = "turn_timeout" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Turn_timeout { elapsed_sec = 1201.0 })
  in
  Alcotest.(check (float 0.0001))
    "turn_timeout counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_cascade_exhausted_kind () =
  let kind = "cascade_exhausted" in
  let cascade_name = "primary" in
  let before = counter_for ~cascade_name kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Cascade_exhausted
         {
           cascade_name = typed_cascade_name cascade_name;
           reason =
             Masc_mcp.Keeper_types.Other_detail "all providers tried";
         })
  in
  Alcotest.(check (float 0.0001))
    "cascade_exhausted{cascade_name=primary} counter +1"
    (before +. 1.0)
    (counter_for ~cascade_name kind)

let test_capacity_backpressure_kind () =
  let kind = "capacity_backpressure" in
  let cascade_name = "primary" in
  let before = counter_for ~cascade_name kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Capacity_backpressure
         {
           cascade_name = typed_cascade_name cascade_name;
           source = OWN.Client_capacity;
           detail = "client capacity key provider_k is full";
           retry_after_sec = None;
         })
  in
  Alcotest.(check (float 0.0001))
    "capacity_backpressure{cascade_name=primary} counter +1"
    (before +. 1.0)
    (counter_for ~cascade_name kind)

let test_resumable_cli_session_kind () =
  let kind = "resumable_cli_session" in
  let cascade_name = "primary" in
  let before = counter_for ~cascade_name kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Resumable_cli_session
         {
           cascade_name = typed_cascade_name cascade_name;
           detail = "session resumable";
           exit_code = Some 130;
         })
  in
  Alcotest.(check (float 0.0001))
    "resumable_cli_session{cascade_name=primary} counter +1"
    (before +. 1.0)
    (counter_for ~cascade_name kind)

let test_no_tool_capable_provider_kind () =
  let kind = "no_tool_capable_provider" in
  let cascade_name = "tool_required" in
  let before = counter_for ~cascade_name kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.No_tool_capable_provider
         {
           cascade_name = typed_cascade_name cascade_name;
           configured_labels = [ "provider_d"; "provider_a" ];
           required_tool_names = [];
           provider_rejections = [];
         })
  in
  Alcotest.(check (float 0.0001))
    "no_tool_capable_provider{cascade_name=tool_required} counter +1"
    (before +. 1.0)
    (counter_for ~cascade_name kind)

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > hay_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let test_no_tool_capable_provider_payload_names_tools_and_rejections () =
  let payload =
    OWN.No_tool_capable_provider
      {
        cascade_name = typed_cascade_name "tool_required";
        configured_labels = [ "agent_code"; "provider_c" ];
        required_tool_names = [ "tool_execute"; "masc_worktree_create" ];
        provider_rejections =
          [
            { OWN.provider_label = "agent_code"; OWN.reason = "codex_keeper_bound_actor_required" };
            { OWN.provider_label = "provider_c"; OWN.reason = "tool_lane_unsupported" };
          ];
      }
  in
  let json = OWN.masc_internal_error_to_json payload in
  let open Yojson.Safe.Util in
  Alcotest.(check (list string))
    "required tools serialized"
    [ "tool_execute"; "masc_worktree_create" ]
    (json |> member "required_tool_names" |> to_list
     |> List.map to_string);
  Alcotest.(check int)
    "configured candidate count serialized"
    2
    (json |> member "configured_candidate_count" |> to_int);
  Alcotest.(check int)
    "rejected candidate count serialized"
    2
    (json |> member "rejected_candidate_count" |> to_int);
  Alcotest.(check (list string))
    "rejection reasons serialized without provider identity"
    [ "codex_keeper_bound_actor_required"; "tool_lane_unsupported" ]
    (json |> member "rejection_reasons" |> to_list |> List.map to_string);
  Alcotest.(check (list (pair string string)))
    "provider rejection identities serialized"
    [ ("agent_code", "codex_keeper_bound_actor_required")
    ; ("provider_c", "tool_lane_unsupported")
    ]
    (json |> member "provider_rejections" |> to_list
     |> List.map (fun item ->
          (item |> member "provider_label" |> to_string,
           item |> member "reason" |> to_string)));
  let err = OWN.sdk_error_of_masc_internal_error payload in
  match OWN.classify_masc_internal_error err with
  | Some parsed -> (
      match OWN.summary_of_masc_internal_error parsed with
      | Some summary ->
          Alcotest.(check bool) "summary names missing worktree tool" true
            (contains_substring summary "masc_worktree_create");
          Alcotest.(check bool) "summary names rejection reason" true
            (contains_substring summary
               "codex_keeper_bound_actor_required");
          Alcotest.(check bool) "summary omits rejected provider identity" false
            (contains_substring summary "cli_tool_a:agent_code")
      | None -> Alcotest.fail "expected no-tool summary")
  | None -> Alcotest.fail "expected no-tool error round-trip"

let test_no_tool_capable_provider_legacy_rejections_are_redacted () =
  let legacy_json =
    `Assoc
      [
        ("kind", `String "no_tool_capable_provider");
        ("cascade_name", `String "tool_required");
        ("configured_labels", `List [ `String "agent_code"; `String "provider_c" ]);
        ("required_tool_names", `List [ `String "tool_execute" ]);
        ( "provider_rejections",
          `List
            [
              `Assoc
                [
                  ("provider_label", `String "cli_tool_a:agent_code");
                  ("provider_kind", `String "cli_tool_a");
                  ("reason", `String "codex_keeper_bound_actor_required");
                ];
            ] );
      ]
  in
  let raw = "[masc_oas_error] " ^ Yojson.Safe.to_string legacy_json in
  match OWN.classify_masc_internal_error_of_string raw with
  | None -> Alcotest.fail "expected legacy no-tool payload to parse"
  | Some parsed -> (
      let redacted = OWN.masc_internal_error_to_json parsed in
      let open Yojson.Safe.Util in
      Alcotest.(check (list (pair string string)))
        "legacy provider_rejections preserved with identity"
        [ ("cli_tool_a:agent_code", "codex_keeper_bound_actor_required") ]
        (redacted |> member "provider_rejections" |> to_list
         |> List.map (fun item ->
              (item |> member "provider_label" |> to_string,
               item |> member "reason" |> to_string)));
      Alcotest.(check (list string))
        "legacy rejection reason survives"
        [ "codex_keeper_bound_actor_required" ]
        (redacted |> member "rejection_reasons" |> to_list
         |> List.map to_string);
      match OWN.summary_of_masc_internal_error parsed with
      | None -> Alcotest.fail "expected legacy no-tool summary"
      | Some summary ->
          Alcotest.(check bool)
            "legacy summary omits rejected provider identity"
            false
            (contains_substring summary "cli_tool_a:agent_code"))

let test_accept_rejected_kind () =
  let kind = "accept_rejected" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Accept_rejected
         {
           scope = "keeper_turn";
           model = Some "agent_code";
           reason = "accept=false";
         })
  in
  Alcotest.(check (float 0.0001))
    "accept_rejected counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_admission_queue_timeout_kind () =
  let kind = "admission_queue_timeout" in
  let cascade_name = "primary" in
  let before = counter_for ~cascade_name kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Admission_queue_timeout
         {
           keeper_name = "keeper-alpha";
           cascade_name = typed_cascade_name cascade_name;
           wait_sec = 30.0;
         })
  in
  Alcotest.(check (float 0.0001))
    "admission_queue_timeout{cascade_name=primary} counter +1"
    (before +. 1.0)
    (counter_for ~cascade_name kind)

let test_admission_queue_rejected_kind () =
  let kind = "admission_queue_rejected" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Admission_queue_rejected
         { keeper_name = "keeper-alpha"; reason = "queue closed" })
  in
  Alcotest.(check (float 0.0001))
    "admission_queue_rejected counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_ambiguous_post_commit_kind () =
  let kind = "ambiguous_post_commit" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Ambiguous_post_commit
         {
           is_timeout = true;
           tools = [ "keeper_board_post" ];
           original_error = "provider timeout";
         })
  in
  Alcotest.(check (float 0.0001))
    "ambiguous_post_commit counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_kind_isolation () =
  (* Bumping one kind must not move the counter for a different
     kind — the label separation is what lets Grafana split
     [rate(...{kind=~"provider_timeout"}[5m])] cleanly. *)
  let a = "turn_timeout" in
  let b = "provider_timeout" in
  let b_before = counter_for b in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Turn_timeout { elapsed_sec = 42.0 })
  in
  Alcotest.(check (float 0.0001))
    "different kind counter unchanged"
    b_before (counter_for b);
  ignore a

(* #10285: cascade_name label separation -------------------------- *)

let test_resumable_cli_session_per_cascade_isolation () =
  (* The exact #10285 shape: resumable_cli_session events are
     unevenly distributed across 5 cascades.  Bumping
     [governance_judge] must NOT move the counter for
     [cli_tool_c_keeper] — operators rate-alert and demote per cascade. *)
  let kind = "resumable_cli_session" in
  let cascade_a = "governance_judge" in
  let cascade_b = "cli_tool_c_keeper" in
  let b_before = counter_for ~cascade_name:cascade_b kind in
  let a_before = counter_for ~cascade_name:cascade_a kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Resumable_cli_session
         {
           cascade_name = typed_cascade_name cascade_a;
           detail = "exit 1";
           exit_code = Some 1;
         })
  in
  Alcotest.(check (float 0.0001))
    "governance_judge counter advanced"
    (a_before +. 1.0)
    (counter_for ~cascade_name:cascade_a kind);
  Alcotest.(check (float 0.0001))
    "cli_tool_c_keeper counter unchanged by governance_judge bump"
    b_before
    (counter_for ~cascade_name:cascade_b kind)

let test_empty_cascade_name_collapses_to_unknown () =
  (* Defensive: a cascade-aware variant whose payload happens to
     carry an empty cascade_name (whitespace-only allowed) must NOT
     emit a series with [cascade_name=""].  Empty-label rows are
     rejected by some Prometheus scraper configs and collapse in
     Grafana group-by. *)
  let kind = "resumable_cli_session" in
  let unknown_before = counter_for ~cascade_name:"unknown" kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Resumable_cli_session
         {
           cascade_name = typed_cascade_name "  ";
           detail = "exit 1";
           exit_code = Some 1;
         })
  in
  Alcotest.(check (float 0.0001))
    "blank cascade_name routes to 'unknown'"
    (unknown_before +. 1.0)
    (counter_for ~cascade_name:"unknown" kind)

let test_non_cascade_aware_variant_uses_unknown () =
  (* [Turn_timeout] has no cascade_name in its payload; the label
     stays ["unknown"] rather than guessing. *)
  let kind = "turn_timeout" in
  let before = counter_for ~cascade_name:"unknown" kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Turn_timeout { elapsed_sec = 99.0 })
  in
  Alcotest.(check (float 0.0001))
    "non-cascade-aware variant labels cascade_name=unknown"
    (before +. 1.0)
    (counter_for ~cascade_name:"unknown" kind)

let () =
  Alcotest.run "oas_error_kind_counter_9933"
    [
      ( "metric_name",
        [
          Alcotest.test_case "canonical name stable" `Quick
            test_metric_name_stable;
        ] );
      ( "per_kind_increment",
        [
          Alcotest.test_case "provider_timeout" `Quick
            test_provider_timeout_kind;
          Alcotest.test_case "turn_timeout" `Quick
            test_turn_timeout_kind;
          Alcotest.test_case "cascade_exhausted" `Quick
            test_cascade_exhausted_kind;
          Alcotest.test_case "capacity_backpressure" `Quick
            test_capacity_backpressure_kind;
          Alcotest.test_case "resumable_cli_session" `Quick
            test_resumable_cli_session_kind;
          Alcotest.test_case "no_tool_capable_provider" `Quick
            test_no_tool_capable_provider_kind;
          Alcotest.test_case "accept_rejected" `Quick
            test_accept_rejected_kind;
          Alcotest.test_case "admission_queue_timeout" `Quick
            test_admission_queue_timeout_kind;
          Alcotest.test_case "admission_queue_rejected" `Quick
            test_admission_queue_rejected_kind;
          Alcotest.test_case "ambiguous_post_commit" `Quick
            test_ambiguous_post_commit_kind;
        ] );
      ( "isolation",
        [
          Alcotest.test_case "kind labels separate" `Quick
            test_kind_isolation;
        ] );
      ( "cascade_name_label_10285",
        [
          Alcotest.test_case
            "resumable_cli_session per-cascade isolation" `Quick
            test_resumable_cli_session_per_cascade_isolation;
          Alcotest.test_case
            "blank cascade_name collapses to unknown" `Quick
            test_empty_cascade_name_collapses_to_unknown;
          Alcotest.test_case
            "non-cascade-aware variant uses unknown" `Quick
            test_non_cascade_aware_variant_uses_unknown;
        ] );
      ( "structured_payload_13344",
        [
          Alcotest.test_case
            "no_tool_capable_provider names tools and rejection reasons"
            `Quick
            test_no_tool_capable_provider_payload_names_tools_and_rejections;
          Alcotest.test_case
            "legacy no_tool_capable_provider rejection identities redact"
            `Quick
            test_no_tool_capable_provider_legacy_rejections_are_redacted;
        ] );
    ]
