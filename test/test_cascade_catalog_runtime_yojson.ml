(** Regression test for [Cascade_catalog_runtime.candidate_probe_to_yojson].

    Pins the post-PR-#15070 behaviour: the boot-log JSON serializer for
    catalog candidates emits the *real* identity fields ([model_string],
    [provider_kind], [model_id], [base_url]) from the probe record, not
    the [public_runtime_*_label] placeholder that #15040 had wired in.

    The Runtime Lens redaction is intentional at external boundaries
    (Prometheus labels via [record_probe_metrics], the dashboard OAS
    bridge, [Keeper_unified_metrics.redacted_*]), but the boot log is an
    internal observability surface — operators need real provider /
    model identity to verify the loaded cascade.toml. If a future PR
    reapplies the lens at this serializer, this test fails first. *)

open Masc_mcp
module C = Cascade_catalog_runtime

let probe ?(status = C.Probe_ok) ~model_string ~provider_kind ~model_id ~base_url
    () : C.candidate_probe =
  { model_string; provider_kind; model_id; base_url; status }

let assoc_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | other ->
      Alcotest.failf "expected string at key %S, got %s" key
        (Yojson.Safe.to_string other)

let assoc_member key json = Yojson.Safe.Util.member key json

let test_probe_ok_real_identity () =
  let p =
    probe ~status:C.Probe_ok
      ~model_string:"ollama_cloud.ollama-cloud-deepseek-v4-pro"
      ~provider_kind:"ollama_http"
      ~model_id:"deepseek-v4-pro:cloud"
      ~base_url:"https://ollama.com"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string is real"
    "ollama_cloud.ollama-cloud-deepseek-v4-pro"
    (assoc_string "model_string" json);
  Alcotest.(check string)
    "provider_kind is real" "ollama_http"
    (assoc_string "provider_kind" json);
  Alcotest.(check string)
    "model_id is real" "deepseek-v4-pro:cloud"
    (assoc_string "model_id" json);
  Alcotest.(check string)
    "base_url is real" "https://ollama.com"
    (assoc_string "base_url" json);
  Alcotest.(check string) "status is ok" "ok" (assoc_string "status" json);
  match assoc_member "error" json with
  | `Null -> ()
  | other ->
      Alcotest.failf "expected `Null at error, got %s"
        (Yojson.Safe.to_string other)

let test_probe_not_applicable_real_identity () =
  let p =
    probe
      ~status:(C.Probe_not_applicable "cloud probe not run at boot")
      ~model_string:"claude_code.claude-auto"
      ~provider_kind:"anthropic_cli"
      ~model_id:"auto"
      ~base_url:""
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives not_applicable status" "claude_code.claude-auto"
    (assoc_string "model_string" json);
  Alcotest.(check string)
    "provider_kind survives" "anthropic_cli"
    (assoc_string "provider_kind" json);
  Alcotest.(check string)
    "model_id survives" "auto"
    (assoc_string "model_id" json);
  Alcotest.(check string) "base_url survives empty" ""
    (assoc_string "base_url" json);
  Alcotest.(check string)
    "status is not_applicable" "not_applicable"
    (assoc_string "status" json);
  Alcotest.(check string)
    "error message preserved" "cloud probe not run at boot"
    (assoc_string "error" json)

let test_probe_error_real_identity () =
  let p =
    probe
      ~status:(C.Probe_error "endpoint unreachable")
      ~model_string:"ollama.local-default"
      ~provider_kind:"ollama_http"
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:11434"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives error status" "ollama.local-default"
    (assoc_string "model_string" json);
  Alcotest.(check string) "model_id survives" "qwen3.5"
    (assoc_string "model_id" json);
  Alcotest.(check string)
    "base_url survives" "http://127.0.0.1:11434"
    (assoc_string "base_url" json);
  Alcotest.(check string) "status is error" "error"
    (assoc_string "status" json);
  Alcotest.(check string)
    "error message preserved" "endpoint unreachable"
    (assoc_string "error" json)

let test_probe_skipped_real_identity () =
  let p =
    probe
      ~status:(C.Probe_skipped "endpoint not probed")
      ~model_string:"glm-coding.glm-5-1"
      ~provider_kind:"openai_http"
      ~model_id:"glm-5.1"
      ~base_url:"https://api.z.ai/api/coding/paas/v4"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  Alcotest.(check string)
    "model_string survives skipped status" "glm-coding.glm-5-1"
    (assoc_string "model_string" json);
  Alcotest.(check string) "status is skipped" "skipped"
    (assoc_string "status" json)

(* Anti-regression: assert specifically that the placeholder strings used
   pre-#15070 do NOT appear in the JSON when the probe carries real
   values. If a future PR reapplies the Runtime Lens here, this test
   detects it directly. *)
let test_no_runtime_placeholder_when_identity_is_real () =
  let p =
    probe ~status:C.Probe_ok
      ~model_string:"specific.model"
      ~provider_kind:"specific_provider"
      ~model_id:"specific-id"
      ~base_url:"https://specific.example/"
      ()
  in
  let json = C.candidate_probe_to_yojson p in
  let text = Yojson.Safe.to_string json in
  let contains_placeholder =
    let placeholder = "\"runtime\"" in
    let placeholder_value_in_identity_field =
      List.exists
        (fun key ->
          let needle = Printf.sprintf "\"%s\":%s" key placeholder in
          let exists s sub =
            let nlen = String.length sub and slen = String.length s in
            let rec loop i =
              i + nlen <= slen && (String.sub s i nlen = sub || loop (i + 1))
            in
            loop 0
          in
          exists text needle)
        [ "model_string"; "provider_kind"; "model_id" ]
    in
    placeholder_value_in_identity_field
  in
  Alcotest.(check bool)
    "no Runtime Lens placeholder leaked into identity fields" false
    contains_placeholder

(* ───────────────────────────────────────────────────────────────────
   Companion coverage: Cascade_legacy_runner.cascade_observation_to_json
   pins the same Runtime Lens carve-out for the audit-log surface
   (second site fixed in PR #15070's second commit f567e57272). The
   non-redacted serializer must emit real model_id / model_label on
   attempts and fallback events; the redacted variant for keeper
   external metrics lives in Keeper_unified_metrics.
   ─────────────────────────────────────────────────────────────────── *)

module LR = Cascade_legacy_runner
module KP = Keeper_cascade_profile

let mk_attempt ~model_id ~model_label : LR.cascade_attempt =
  {
    attempt_index = 0;
    model_id;
    model_label = Some model_label;
    latency_ms = Some 42;
    error = None;
  }

let mk_fallback_event ~from_id ~to_id : LR.cascade_fallback_event =
  {
    from_model_id = from_id;
    from_model_label = Some (from_id ^ "/label");
    to_model_id = to_id;
    to_model_label = Some (to_id ^ "/label");
    reason = "capability_gate";
  }

let mk_observation ?(attempts = []) ?(fallback_events = []) () :
    LR.cascade_observation =
  {
    cascade_name = KP.runtime_name_of_string "tier.test_observation_real_id";
    strategy = Some "failover";
    configured_labels = [ "Edit"; "Write" ];
    candidate_models = [ "claude_code.claude-auto"; "ollama_cloud.qwen3.5" ];
    primary_model = Some "claude_code.claude-auto";
    selected_model = Some "ollama_cloud.qwen3.5";
    selected_model_raw = Some "qwen3.5";
    selected_index = Some 1;
    fallback_hops = Some 1;
    fallback_applied = true;
    attempts;
    fallback_events;
    attempt_details_available = true;
    attempt_details_source = "oas_metrics_callbacks";
  }

let nth_attempt_model_id json idx =
  let attempts = Yojson.Safe.Util.member "attempts" json in
  let attempt = List.nth (Yojson.Safe.Util.to_list attempts) idx in
  assoc_string "model_id" attempt

let test_observation_attempts_emit_real_model_id () =
  let attempt0 =
    mk_attempt ~model_id:"ollama_cloud.ollama-cloud-deepseek-v4-pro"
      ~model_label:"deepseek-v4-pro:cloud"
  in
  let attempt1 =
    mk_attempt ~model_id:"claude_code.claude-auto" ~model_label:"auto"
  in
  let obs = mk_observation ~attempts:[ attempt0; attempt1 ] () in
  let json = LR.cascade_observation_to_json obs in
  Alcotest.(check string)
    "attempt[0].model_id real"
    "ollama_cloud.ollama-cloud-deepseek-v4-pro"
    (nth_attempt_model_id json 0);
  Alcotest.(check string)
    "attempt[1].model_id real" "claude_code.claude-auto"
    (nth_attempt_model_id json 1)

let test_observation_fallback_events_emit_real_ids () =
  let event =
    mk_fallback_event ~from_id:"claude_code.claude-auto"
      ~to_id:"ollama_cloud.qwen3.5"
  in
  let obs = mk_observation ~fallback_events:[ event ] () in
  let json = LR.cascade_observation_to_json obs in
  let events = Yojson.Safe.Util.member "fallback_events" json in
  let event0 = List.hd (Yojson.Safe.Util.to_list events) in
  Alcotest.(check string)
    "fallback.from_model_id real" "claude_code.claude-auto"
    (assoc_string "from_model_id" event0);
  Alcotest.(check string)
    "fallback.to_model_id real" "ollama_cloud.qwen3.5"
    (assoc_string "to_model_id" event0)

let test_observation_no_runtime_placeholder () =
  let attempt = mk_attempt ~model_id:"distinct.model" ~model_label:"distinct" in
  let event =
    mk_fallback_event ~from_id:"distinct.from" ~to_id:"distinct.to"
  in
  let obs =
    mk_observation ~attempts:[ attempt ] ~fallback_events:[ event ] ()
  in
  let text = Yojson.Safe.to_string (LR.cascade_observation_to_json obs) in
  let contains s sub =
    let nlen = String.length sub and slen = String.length s in
    let rec loop i =
      i + nlen <= slen && (String.sub s i nlen = sub || loop (i + 1))
    in
    loop 0
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "no placeholder substring %s" needle)
        false (contains text needle))
    [
      "\"model_id\":\"runtime\"";
      "\"from_model_id\":\"runtime\"";
      "\"to_model_id\":\"runtime\"";
    ]

let case name f = Alcotest.test_case name `Quick f

let () =
  Alcotest.run "Cascade catalog runtime YOJSON"
    [
      ( "candidate_probe real identity",
        [
          case "Probe_ok emits real identity"
            test_probe_ok_real_identity;
          case "Probe_not_applicable emits real identity"
            test_probe_not_applicable_real_identity;
          case "Probe_error emits real identity"
            test_probe_error_real_identity;
          case "Probe_skipped emits real identity"
            test_probe_skipped_real_identity;
        ] );
      ( "candidate_probe anti-regression",
        [
          case "no Runtime Lens placeholder in identity fields"
            test_no_runtime_placeholder_when_identity_is_real;
        ] );
      ( "cascade_observation audit-log real identity",
        [
          case "attempts[*].model_id is real"
            test_observation_attempts_emit_real_model_id;
          case "fallback_events[*].from/to_model_id is real"
            test_observation_fallback_events_emit_real_ids;
          case "no runtime placeholder for model identity"
            test_observation_no_runtime_placeholder;
        ] );
    ]
