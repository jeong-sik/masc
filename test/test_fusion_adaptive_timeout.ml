(* Fusion legacy budget parsing and timeout observation tests. *)

open Alcotest
open Masc
open Fusion_types

let sample_usage : Fusion_types.usage =
  { Fusion_types.input_tokens = 10; output_tokens = 5 }

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
judge_wave_budget_s = 500.0
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

let adaptive_preset () =
  match Fusion_config.of_toml (parse adaptive_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] -> Fusion_policy.Validated_preset.preset vp
     | _ -> fail "expected exactly one preset")
  | Error es ->
    failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

let test_config_adaptive_timeout_parse () =
  match Fusion_config.of_toml (parse adaptive_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = Fusion_policy.Validated_preset.preset vp in
       check (float 0.001) "meta_timeout_s" 90.0 preset.Fusion_policy.meta_timeout_s;
       check (float 0.001) "judge_wave_budget_s" 500.0
         preset.Fusion_policy.judge_wave_budget_s;
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

let test_runtime_clock_does_not_gate_meta_provider_call () =
  Masc_eio_env.reset_for_test ();
  Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
    let clock = Fusion_orchestrator_judge_wave.make_runtime_clock () in
    match
      Fusion_orchestrator_judge_wave.meta_provider_timeout
        ~preset:(adaptive_preset ())
        clock
    with
    | Ok timeout_s -> check (float 0.001) "configured Provider timeout" 90.0 timeout_s
    | Error (failure, _) ->
      failf "clock unexpectedly gated meta call: %s" (Fusion_types.judge_failure_text failure))

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
    ; ( "clock"
      , [ test_case "missing runtime clock does not gate meta call" `Quick
            test_runtime_clock_does_not_gate_meta_provider_call
        ] )
    ; ( "sink"
      , [ test_case "failed_node_includes_timeout_fields" `Quick
            test_sink_failed_node_includes_timeout_fields
        ] )
    ]
