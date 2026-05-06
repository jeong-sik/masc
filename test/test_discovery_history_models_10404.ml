(** #10404: pre-fix [Discovery_history.endpoint_to_record] kept only the
    head of the loaded model list, recording 'qwen3:8b' for every probe
    while four cascades referenced 'qwen3.6:27b-coding-nvfp4'.  These
    tests pin the new [models : string list] field and verify the head
    backward-compatibility (model_id stays populated). *)

open Alcotest
module DH = Masc_mcp.Discovery_history
module P = Masc_mcp.Prometheus

let make ~models : DH.probe_record = {
  ts = 1777129200.0;
  endpoint_url = "http://127.0.0.1:11434";
  healthy = true;
  model_id = (match models with m :: _ -> Some m | [] -> None);
  models;
  ctx_size = Some 40960;
  total_slots = Some 4;
  busy_slots = Some 0;
  idle_slots = Some 4;
}

let json_string_of (json : Yojson.Safe.t) = Yojson.Safe.to_string json

let test_models_list_is_emitted () =
  let r = make ~models:[
    "qwen3:8b";
    "qwen3.6:27b-coding-nvfp4";
    "qwen3.6:27b-coding-bf16";
    "supergemma4:e4b-abliterated-mlx";
  ] in
  let s = json_string_of (DH.record_to_json r) in
  check bool "models field present" true
    (Astring.String.is_infix ~affix:"\"models\":" s);
  check bool "second model preserved" true
    (Astring.String.is_infix ~affix:"qwen3.6:27b-coding-nvfp4" s);
  check bool "fourth model preserved" true
    (Astring.String.is_infix ~affix:"supergemma4:e4b-abliterated-mlx" s)

let test_model_id_is_head_for_legacy_readers () =
  let r = make ~models:[
    "qwen3:8b";
    "qwen3.6:27b-coding-nvfp4";
  ] in
  let s = json_string_of (DH.record_to_json r) in
  check bool "model_id field still present" true
    (Astring.String.is_infix ~affix:"\"model_id\":\"qwen3:8b\"" s)

let test_empty_models_omits_field () =
  let r = make ~models:[] in
  let s = json_string_of (DH.record_to_json r) in
  check bool "no models field when list empty" false
    (Astring.String.is_infix ~affix:"\"models\":" s);
  check bool "no model_id field when empty" false
    (Astring.String.is_infix ~affix:"\"model_id\":" s)

let test_single_model_round_trip () =
  let r = make ~models:[ "qwen3.6:27b-coding-nvfp4" ] in
  let s = json_string_of (DH.record_to_json r) in
  check bool "single-model models field present" true
    (Astring.String.is_infix ~affix:"\"models\":[\"qwen3.6:27b-coding-nvfp4\"]" s);
  check bool "single-model model_id matches head" true
    (Astring.String.is_infix
       ~affix:"\"model_id\":\"qwen3.6:27b-coding-nvfp4\"" s)

let text_has_literal text literal =
  Astring.String.is_infix ~affix:literal text

let test_failure_observer_increments_metric () =
  let labels = [("site", "unit_test")] in
  let before =
    P.metric_value_or_zero P.metric_discovery_history_failures ~labels ()
  in
  DH.For_testing.observe_failure
    ~site:"unit_test"
    ~base_path:"/tmp/masc-discovery-history"
    (Failure "synthetic discovery history failure");
  let after =
    P.metric_value_or_zero P.metric_discovery_history_failures ~labels ()
  in
  check (float 0.0001) "discovery history failure counted"
    (before +. 1.0)
    after

let test_failure_observer_reraises_cancelled () =
  let raised = ref false in
  (try
     DH.For_testing.observe_failure
       ~site:"unit_test_cancel"
       ~base_path:"/tmp/masc-discovery-history"
       (Eio.Cancel.Cancelled (Failure "synthetic cancel"))
   with Eio.Cancel.Cancelled _ -> raised := true);
  check bool "cancel is re-raised" true !raised

let test_failure_metric_registered () =
  let text = P.to_prometheus_text () in
  check bool "has discovery history failure HELP" true
    (text_has_literal text
       ("# HELP " ^ P.metric_discovery_history_failures ^ " "));
  check bool "has discovery history failure TYPE" true
    (text_has_literal text
       ("# TYPE " ^ P.metric_discovery_history_failures ^ " counter"))

let () =
  run "discovery_history_models_10404" [
    ("model_preservation", [
        test_case "full models list serialised" `Quick
          test_models_list_is_emitted;
        test_case "model_id stays = head for legacy readers" `Quick
          test_model_id_is_head_for_legacy_readers;
        test_case "empty model list omits both fields" `Quick
          test_empty_models_omits_field;
        test_case "single-model round-trip stays consistent" `Quick
          test_single_model_round_trip;
      ]);
    ("failure_observer", [
        test_case "increments metric" `Quick
          test_failure_observer_increments_metric;
        test_case "re-raises cancellation" `Quick
          test_failure_observer_reraises_cancelled;
        test_case "metric registered" `Quick
          test_failure_metric_registered;
      ]);
  ]
