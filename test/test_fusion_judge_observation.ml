(* Fusion judge fallback, timeout observation, and sink projection tests. *)

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
  ; jtimeout_s = 1.0
  }

let failed_judge_run model failure :
    Fusion_orchestrator_judge_wave.judge_run =
  sample_judge model, model, Error (failure, Fusion_types.zero_usage), 0.0, false

let ok_judge_run model : Fusion_orchestrator_judge_wave.judge_run =
  sample_judge model, model, Ok (sample_synthesis, sample_usage), 0.0, false

let parse s = Otoml.Parser.from_string s

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
  run "fusion_judge_observation"
    [ ( "config"
      , [ test_case "invalid_meta_timeout" `Quick test_config_invalid_meta_timeout ] )
    ; ( "fallback"
      , [ test_case "timeout wave appends fallback" `Quick
            test_timeout_first_wave_appends_fallback
        ; test_case "provider failure skips fallback" `Quick
            test_timeout_first_wave_skips_fallback_on_provider_error
        ] )
    ; ( "sink"
      , [ test_case "failed_node_includes_timeout_fields" `Quick
            test_sink_failed_node_includes_timeout_fields
        ] )
    ]
