(* FUSION adaptive timeout / P0 hardening tests.
   Covers: config parse/validation, pure adjust_judge_timeout semantics,
   OTel counter emission, and sink meta JSON for failed judge nodes. *)

open Alcotest
open Masc
open Fusion_types

let sample_usage : Fusion_types.usage =
  { Fusion_types.input_tokens = 10; output_tokens = 5 }

let sample_synthesis : Fusion_types.judge_synthesis =
  { Fusion_types.consensus = []
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = []
  ; blind_spots = []
  ; resolved_answer = "ok"
  ; decision = Fusion_types.Answer "ok"
  }

let sample_judge model : Fusion_policy.judge_spec =
  { Fusion_policy.jmodel = model
  ; jlabel = ""
  ; jsystem_prompt = "judge"
  ; jweb_tools = false
  ; jmax_output_tokens = None
  ; jtimeout_s = 1.0
  ; jmax_timeout_s = None
  }

let failed_judge_run model failure :
    Fusion_orchestrator_judge_wave.judge_run =
  sample_judge model, model, Error (failure, Fusion_types.zero_usage), 0.0, false

let ok_judge_run model : Fusion_orchestrator_judge_wave.judge_run =
  sample_judge model, model, Ok (sample_synthesis, sample_usage), 0.0, false

let parse s = Otoml.Parser.from_string s

let adaptive_toml =
  {|
[fusion]
enabled = true
default_preset = "adaptive"
[fusion.presets.adaptive]
judge = "meta"
judge_system_prompt = "reconcile"
judge_timeout_s = 120.0
meta_timeout_s = 90.0
adaptive_timeout_factor = 2.0
fallback_judge_model = "fallback-model"
[[fusion.presets.adaptive.panels]]
panel = ["p1"]
panel_system_prompt = "answer"
[[fusion.presets.adaptive.judges]]
model = "judge-a"
system_prompt = "lens A"
timeout_s = 100.0
max_timeout_s = 180.0
[[fusion.presets.adaptive.judges]]
model = "judge-b"
system_prompt = "lens B"
timeout_s = 110.0
|}

let test_config_adaptive_timeout_parse () =
  match Fusion_config.of_toml (parse adaptive_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = Fusion_policy.Validated_preset.preset vp in
       check (float 0.001) "meta_timeout_s" 90.0 preset.Fusion_policy.meta_timeout_s;
       check (float 0.001) "adaptive_timeout_factor" 2.0
         preset.Fusion_policy.adaptive_timeout_factor;
       check (option string) "fallback_judge_model" (Some "fallback-model")
         preset.Fusion_policy.fallback_judge_model;
       (match preset.Fusion_policy.judges with
        | [ ja; _ ] ->
          check (float 0.001) "ja timeout" 100.0 ja.Fusion_policy.jtimeout_s;
          check (option (float 0.001)) "ja max_timeout_s" (Some 180.0)
            ja.Fusion_policy.jmax_timeout_s
        | _ -> fail "expected two judges")
     | _ -> fail "expected exactly one preset")
  | Error es ->
    failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

let test_config_invalid_meta_timeout () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
panel = ["a"]
judge = "j"
panel_system_prompt = "x"
judge_system_prompt = "y"
meta_timeout_s = 0.0
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    check bool "Invalid_meta_timeout present" true
      (List.exists
         (function Fusion_config.Invalid_meta_timeout _ -> true | _ -> false)
         es)
  | Ok _ -> fail "expected Error Invalid_meta_timeout"

let test_config_invalid_adaptive_factor () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
panel = ["a"]
judge = "j"
panel_system_prompt = "x"
judge_system_prompt = "y"
adaptive_timeout_factor = 0.5
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    check bool "Invalid_adaptive_timeout_factor present" true
      (List.exists
         (function Fusion_config.Invalid_adaptive_timeout_factor _ -> true
                 | _ -> false)
         es)
  | Ok _ -> fail "expected Error Invalid_adaptive_timeout_factor"

let test_adjust_judge_timeout_disabled () =
  check (float 0.001) "factor=1.0 returns base" 10.0
    (Fusion_policy.adjust_judge_timeout ~base_s:10.0 ~max_s:None ~factor:1.0
       ~already_timed_out:false)

let test_adjust_judge_timeout_extend () =
  check (float 0.001) "extend capped by max_s" 15.0
    (Fusion_policy.adjust_judge_timeout ~base_s:10.0 ~max_s:(Some 15.0)
       ~factor:2.0 ~already_timed_out:true)

let test_timeout_first_wave_appends_fallback () =
  let fallback_calls = ref 0 in
  let fallback = ok_judge_run "fallback-model" in
  let runs =
    [ failed_judge_run "judge-a" Fusion_types.Timeout
    ; failed_judge_run "judge-b" Fusion_types.Timeout
    ]
  in
  let with_fallback =
    Fusion_orchestrator_judge_wave.with_timeout_fallback
      ~run_fallback_judge:(fun () ->
        incr fallback_calls;
        Some fallback)
      runs
  in
  check int "fallback called once" 1 !fallback_calls;
  check int "fallback appended" 3 (List.length with_fallback);
  match List.rev with_fallback with
  | (_, id, Ok _, _, _) :: _ -> check string "fallback id" "fallback-model" id
  | _ -> fail "expected appended successful fallback"

let test_timeout_first_wave_skips_fallback_on_provider_error () =
  let fallback_calls = ref 0 in
  let runs =
    [ failed_judge_run "judge-a" Fusion_types.Timeout
    ; failed_judge_run "judge-b" (Fusion_types.Provider_error "hard failure")
    ]
  in
  let without_fallback =
    Fusion_orchestrator_judge_wave.with_timeout_fallback
      ~run_fallback_judge:(fun () ->
        incr fallback_calls;
        Some (ok_judge_run "fallback-model"))
      runs
  in
  check int "fallback not called" 0 !fallback_calls;
  check int "original runs kept" 2 (List.length without_fallback)

let test_record_adaptive_timeout_emits () =
  let before =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_adaptive_timeout_extensions_total
      ()
  in
  Fusion_metrics.record_adaptive_timeout ();
  let after =
    Otel_metric_store.metric_value_or_zero
      Fusion_metrics.metric_fusion_adaptive_timeout_extensions_total
      ()
  in
  check (float 0.0) "adaptive timeout counter incremented" (before +. 1.0) after

let test_sink_failed_node_includes_timeout_fields () =
  let node =
    Fusion_types.Judge_failed
      { Fusion_types.failed_role = First "j"
      ; failure = Fusion_types.Timeout
      ; usage = sample_usage
      ; elapsed_s = 5.0
      }
  in
  let json = Fusion_sink.judge_node_meta node in
  match json with
  | `Assoc fields ->
    let get_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Some f
      | _ -> None
    in
    let get_bool key =
      match List.assoc_opt key fields with
      | Some (`Bool b) -> Some b
      | _ -> None
    in
    check (option (float 0.001)) "elapsed_s" (Some 5.0) (get_float "elapsed_s");
    check (option bool) "timed_out" (Some true) (get_bool "timed_out")
  | _ -> fail "expected Assoc"

let () =
  run "fusion_adaptive_timeout"
    [ ( "config"
      , [ test_case "adaptive_timeout_parse" `Quick test_config_adaptive_timeout_parse
        ; test_case "invalid_meta_timeout" `Quick test_config_invalid_meta_timeout
        ; test_case "invalid_adaptive_factor" `Quick
            test_config_invalid_adaptive_factor
        ] )
    ; ( "adjust_judge_timeout"
      , [ test_case "disabled" `Quick test_adjust_judge_timeout_disabled
        ; test_case "extend" `Quick test_adjust_judge_timeout_extend
        ] )
    ; ( "fallback"
      , [ test_case "timeout wave appends fallback" `Quick
            test_timeout_first_wave_appends_fallback
        ; test_case "provider failure skips fallback" `Quick
            test_timeout_first_wave_skips_fallback_on_provider_error
        ] )
    ; ( "metrics"
      , [ test_case "record_adaptive_timeout emits counter" `Quick
            test_record_adaptive_timeout_emits
        ] )
    ; ( "sink"
      , [ test_case "failed_node_includes_timeout_fields" `Quick
            test_sink_failed_node_includes_timeout_fields
        ] )
    ]
