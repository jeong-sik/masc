(** Unit tests for [Keeper_compaction_llm_summarizer] (RFC-0313-adjacent W2).

    Covers the pure surface: structured-plan parsing/validation
    ([plan_of_json]) and plan application ([apply]). The provider call in
    [make] needs an Eio context + live provider and is exercised by
    integration, not here. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module E = Keeper_compaction_eligible_history
module EP = Keeper_compaction_eligible_llm_planner
module P = Keeper_compaction_eligible_plan

let plan_json ~summary ~kept ~summarized ~dropped : Yojson.Safe.t =
  let ints xs = `List (List.map (fun i -> `Int i) xs) in
  `Assoc
    [ "summary", `String summary
    ; "kept_indices", ints kept
    ; "summarized_indices", ints summarized
    ; "dropped_indices", ints dropped
    ]

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

let temperature_runtime_id = "local.kimi_like"

let temperature_runtime_toml =
  "[providers.local]\n\
   display-name = \"Local\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [providers.fallback]\n\
   display-name = \"Fallback\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11435\"\n\
   \n\
   [models.kimi_like]\n\
   api-name = \"kimi-like\"\n\
   max-context = 1024\n\
   temperature = 1.0\n\
   \n\
   [models.kimi_like.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [local.kimi_like]\n\
   \n\
   [fallback.kimi_like]\n\
   \n\
   [runtime]\n\
   default = \"local.kimi_like\"\n\
   librarian = \"local.kimi_like\"\n\
   \n\
   [runtime.lanes.compaction]\n\
   strategy = \"ordered\"\n\
   candidates = [\"local.kimi_like\", \"fallback.kimi_like\"]\n"

let with_temperature_runtime f =
  let path = Filename.temp_file "compaction_temperature_runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc temperature_runtime_toml;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      match Runtime.save_config_text ~runtime_config_path:path temperature_runtime_toml with
      | Error detail -> Alcotest.failf "runtime config should load: %s" detail
      | Ok () ->
        (match Runtime.get_runtime_by_id temperature_runtime_id with
         | None -> Alcotest.fail "temperature runtime should resolve"
         | Some runtime -> f runtime.Runtime.provider_config))

let test_provider_for_plan_preserves_runtime_temperature () =
  with_temperature_runtime (fun provider_cfg ->
    let cfg =
      C.For_testing.provider_for_plan provider_cfg
    in
    Alcotest.(check (option (float 0.0001)))
      "runtime.toml temperature is preserved"
      (Some 1.0)
      cfg.temperature)

let test_provider_for_plan_preserves_temperature_omission () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"test-model"
      ~base_url:"http://example.invalid"
      ()
  in
  let cfg = C.For_testing.provider_for_plan provider_cfg in
  Alcotest.(check (option (float 0.0001)))
    "temperature remains omitted"
    None
    cfg.temperature

let test_lane_candidates_keep_declared_order () =
  with_temperature_runtime @@ fun _ ->
  let actual =
    C.For_testing.candidate_runtime_ids_for_assignment
      ~keeper_name:"keeper-test"
      ~runtime_id:"compaction"
  in
  Alcotest.(check (option (list string))) "declared candidate order"
    (Some [ "local.kimi_like"; "fallback.kimi_like" ])
    actual

let eligible_source () =
  match
    E.of_messages
      [ Agent_sdk.Types.text_message Agent_sdk.Types.System "protected secret"
      ; Agent_sdk.Types.text_message Agent_sdk.Types.User "eligible detail"
      ]
  with
  | Ok source -> source
  | Error _ -> Alcotest.fail "eligible source should partition"

let response text : Agent_sdk.Types.api_response =
  { id = "eligible-plan"
  ; model = "kimi-like"
  ; stop_reason = Agent_sdk.Types.EndTurn
  ; content = [ Agent_sdk.Types.Text text ]
  ; usage = None
  ; telemetry = None
  }

let test_eligible_planner_uses_resources_schema_and_ordered_failover () =
  with_temperature_runtime @@ fun _ ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let source = eligible_source () in
  let calls = ref [] in
  let complete ~sw:sw' ~net:net' ?clock:clock' ~config ~messages () =
    calls := config.base_url :: !calls;
    Alcotest.(check bool) "exact switch" true (sw == sw');
    Alcotest.(check bool) "exact net" true (net == net');
    Alcotest.(check bool)
      "exact clock"
      true
      (Option.fold ~none:false ~some:(fun value -> value == clock) clock');
    Alcotest.(check bool) "tools disabled" true (config.tool_choice = None);
    Alcotest.(check bool) "parallel tools disabled" true config.disable_parallel_tool_use;
    Alcotest.(check (option (float 0.0001))) "temperature exact" (Some 1.0) config.temperature;
    Alcotest.(check string) "model exact" "kimi-like" config.model_id;
    Alcotest.(check bool)
      "output schema exact"
      true
      (config.output_schema = Some P.output_schema);
    Alcotest.(check bool)
      "response schema exact"
      true
      (match config.response_format with
       | Agent_sdk.Types.JsonSchema schema -> schema = P.output_schema
       | Agent_sdk.Types.JsonMode | Agent_sdk.Types.Off -> false);
    let user_json = Yojson.Safe.to_string (P.input_json source) in
    (match messages with
     | [ _; user ] ->
       Alcotest.(check string)
         "prompt contains only eligible input"
         user_json
         (Agent_sdk.Types.text_of_message user)
     | _ -> Alcotest.fail "expected one system and one eligible-input message");
    Alcotest.(check bool)
      "protected history absent"
      false
      (List.exists
         (fun message -> String.equal (Agent_sdk.Types.text_of_message message) "protected secret")
         messages);
    if String.equal config.base_url "http://localhost:11434"
    then Ok (response "not-json")
    else
      Ok
        (response
           {|{"decisions":[{"unit_index":1,"action":"keep","summary":null}]}|})
  in
  match
    EP.run ~complete ~sw ~net ~clock ~keeper_name:"keeper-test"
      ~assignment_id:"compaction" ~source ()
  with
  | Error _ -> Alcotest.fail "second declared candidate should succeed"
  | Ok success ->
    Alcotest.(check string)
      "selected runtime"
      "fallback.kimi_like"
      success.selected_runtime_id;
    Alcotest.(check (list string))
      "declared provider order"
      [ "http://localhost:11434"; "http://localhost:11435" ]
      (List.rev !calls);
    (match success.failed_candidates with
     | [ { runtime_id = "local.kimi_like"; reason = EP.Structured_response_rejected _ } ] -> ()
     | _ -> Alcotest.fail "first typed candidate failure should be returned")

let test_eligible_planner_returns_ordered_aggregate_failure () =
  with_temperature_runtime @@ fun _ ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let complete ~sw:_ ~net:_ ?clock:_ ~config:_ ~messages:_ () =
    Ok (response "not-json")
  in
  match
    EP.run ~complete ~sw ~net:(Eio.Stdenv.net env)
      ~keeper_name:"keeper-test" ~assignment_id:"compaction"
      ~source:(eligible_source ()) ()
  with
  | Ok _ -> Alcotest.fail "invalid responses should exhaust the lane"
  | Error (EP.Assignment_missing _) -> Alcotest.fail "lane should resolve"
  | Error (EP.Candidates_exhausted { failures; _ }) ->
    Alcotest.(check (list string))
      "all failures retain declared runtime ids"
      [ "local.kimi_like"; "fallback.kimi_like" ]
      (List.map (fun failure -> failure.EP.runtime_id) failures)

(* -- plan_of_json: valid partition accepted -- *)

let test_valid_partition_accepted () =
  let json = plan_json ~summary:"folded" ~kept:[ 3; 4 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  Alcotest.(check bool)
    "a full disjoint partition of [0,5) parses"
    true
    (is_ok (C.plan_of_json ~message_count:5 json))

let test_all_kept_rejected () =
  let json = plan_json ~summary:"n/a" ~kept:[ 0; 1; 2 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "keeping everything is not semantic compaction"
    true
    (is_error (C.plan_of_json ~message_count:3 json))

let test_drop_only_with_kept_accepted () =
  let json = plan_json ~summary:"unused" ~kept:[ 1 ] ~summarized:[] ~dropped:[ 0 ] in
  Alcotest.(check bool)
    "drop-only plans are valid when at least one message remains"
    true
    (is_ok (C.plan_of_json ~message_count:2 json))

(* -- plan_of_json: structural violations rejected (no silent repair) -- *)

let test_out_of_range_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 5 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index >= message_count is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_negative_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ -1; 0 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "a negative index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_duplicate_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index appearing in two lists is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_index_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "a partition that omits an in-range index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_all_dropped_rejected () =
  let json = plan_json ~summary:"S" ~kept:[] ~summarized:[] ~dropped:[ 0; 1 ] in
  Alcotest.(check bool)
    "a non-empty working set must not compact to empty output"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_empty_summary_rejected_when_summarizing () =
  let json = plan_json ~summary:"   " ~kept:[ 1 ] ~summarized:[ 0 ] ~dropped:[] in
  Alcotest.(check bool)
    "a blank summary is rejected when there are summarized indices to fold"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_field_rejected () =
  let json = `Assoc [ "summary", `String "x"; "kept_indices", `List [] ] in
  Alcotest.(check bool)
    "a plan missing summarized_indices/dropped_indices is rejected"
    true
    (is_error (C.plan_of_json ~message_count:0 json))

(* -- apply: reconstruction honours the plan -- *)

let msg role text = Agent_sdk.Types.text_message role text
let texts (ms : Agent_sdk.Types.message list) =
  List.map (fun m -> Agent_sdk.Types.text_of_message m) ms

let sample =
  [ msg Agent_sdk.Types.User "u0"
  ; msg Agent_sdk.Types.Assistant "a1"
  ; msg Agent_sdk.Types.Tool "t2"
  ; msg Agent_sdk.Types.User "u3"
  ]

let test_apply_keeps_summarizes_drops () =
  (* kept: 3 ; summarized: 0,1 ; dropped: 2 *)
  let json = plan_json ~summary:"S" ~kept:[ 3 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    let out_texts = texts out in
    (* summary replaces indices 0,1 at position of first summarized (0);
       index 2 dropped; index 3 kept. Result: [summary; u3]. *)
    Alcotest.(check int) "two messages remain" 2 (List.length out);
    Alcotest.(check bool)
      "first is the compaction summary"
      true
      (match out_texts with
       | s :: _ -> Astring.String.is_infix ~affix:"S" s
                   && Astring.String.is_prefix ~affix:"[COMPACTION_SUMMARY]" s
       | [] -> false);
    Alcotest.(check (list string))
      "kept message survives verbatim after the summary"
      [ "u3" ]
      (List.tl out_texts)

let test_apply_drop_only_preserves_kept () =
  let json = plan_json ~summary:"unused" ~kept:[ 0; 1; 2 ] ~summarized:[] ~dropped:[ 3 ] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    Alcotest.(check (list string))
      "drop-only removes only the selected message"
      [ "u0"; "a1"; "t2" ]
      (texts out)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "provider"
      , [ Alcotest.test_case "runtime temperature is authoritative" `Quick
            test_provider_for_plan_preserves_runtime_temperature
        ; Alcotest.test_case "temperature omission is preserved" `Quick
            test_provider_for_plan_preserves_temperature_omission
        ; Alcotest.test_case "lane candidates keep declared order" `Quick
            test_lane_candidates_keep_declared_order
        ; Alcotest.test_case "eligible planner explicit resources and failover" `Quick
            test_eligible_planner_uses_resources_schema_and_ordered_failover
        ; Alcotest.test_case "eligible planner aggregate failure" `Quick
            test_eligible_planner_returns_ordered_aggregate_failure
        ] )
    ; ( "plan_of_json"
      , [ Alcotest.test_case "valid partition accepted" `Quick test_valid_partition_accepted
        ; Alcotest.test_case "all kept rejected" `Quick test_all_kept_rejected
        ; Alcotest.test_case "drop-only with kept accepted" `Quick
            test_drop_only_with_kept_accepted
        ; Alcotest.test_case "out of range rejected" `Quick test_out_of_range_rejected
        ; Alcotest.test_case "negative rejected" `Quick test_negative_rejected
        ; Alcotest.test_case "duplicate rejected" `Quick test_duplicate_rejected
        ; Alcotest.test_case "missing index rejected" `Quick test_missing_index_rejected
        ; Alcotest.test_case "all dropped rejected" `Quick test_all_dropped_rejected
        ; Alcotest.test_case "empty summary rejected when summarizing" `Quick
            test_empty_summary_rejected_when_summarizing
        ; Alcotest.test_case "missing field rejected" `Quick test_missing_field_rejected
        ] )
    ; ( "apply"
      , [ Alcotest.test_case "keeps/summarizes/drops" `Quick test_apply_keeps_summarizes_drops
        ; Alcotest.test_case "drop-only preserves kept" `Quick
            test_apply_drop_only_preserves_kept
        ] )
    ]
