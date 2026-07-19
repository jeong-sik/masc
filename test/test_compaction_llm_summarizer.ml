(** Unit tests for the source-bound Keeper compaction planner. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module Compact_policy = Keeper_compact_policy
module S = Keeper_structured_output_schema
module T = Agent_sdk.Types
module U = Keeper_compaction_unit

let test_runtime_id = "test.compaction"
let plan_of_json ~units json = C.plan_of_json ~runtime_id:test_runtime_id ~units json

let decision ?summary unit_index action : Yojson.Safe.t =
  `Assoc
    [ S.compaction_plan_field_unit_index, `Int unit_index
    ; S.compaction_plan_field_action, `String action
    ; S.compaction_plan_field_summary, Option.fold ~none:`Null ~some:(fun value -> `String value) summary
    ]

let plan_json decisions : Yojson.Safe.t =
  `Assoc [ S.compaction_plan_field_decisions, `List decisions ]

let keep unit_index = decision unit_index S.compaction_plan_action_keep
let drop unit_index = decision unit_index S.compaction_plan_action_drop
let summarize unit_index summary =
  decision ~summary unit_index S.compaction_plan_action_summarize

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

let message ?name ?tool_call_id ?(metadata = []) role content : T.message =
  { role; content; name; tool_call_id; metadata }

let text role value = message role [ T.Text value ]
let ordinary message = U.Ordinary_message message

let tool_use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "secret", `String id ] }

let tool_result id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = None
    ; content_blocks = None
    }

let closed_cycle id =
  U.Closed_tool_cycle
    [ message T.Assistant [ tool_use id ]
    ; message T.Tool [ tool_result id ]
    ]

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
    let cfg = C.For_testing.provider_for_plan provider_cfg in
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

(* -- #25051 P0: structured-judge lane precedes an ineligible chat runtime --

   On the live fleet, most keepers inherit [runtime].default for chat, which
   is picked for chat throughput and is not guaranteed to support the
   provider-native structured-output schema the compaction plan call needs.
   [runtime].structured_judge, by contrast, is explicitly reserved for
   schema-capable requests (RFC-0307), the same lane board-attention judgment
   and failure judgment already use. These fixtures give "chat" no
   [supports-structured-output] (ineligible, mirrors deepseek-v4-flash in
   config/runtime.toml) and "judge" [supports-structured-output = true]
   (eligible), so the tests below can tell the two candidate sources apart. *)

let ineligible_chat_runtime_id = "lane_split_chat.chat_model"
let eligible_judge_runtime_id = "lane_split_judge.judge_model"

let lane_split_runtime_toml =
  "[providers.lane_split_chat]\n\
   display-name = \"Lane Split Chat\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [providers.lane_split_judge]\n\
   display-name = \"Lane Split Judge\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11436\"\n\
   \n\
   [models.chat_model]\n\
   api-name = \"chat-model\"\n\
   max-context = 1024\n\
   \n\
   [models.chat_model.capabilities]\n\
   supports-structured-output = false\n\
   \n\
   [models.judge_model]\n\
   api-name = \"judge-model\"\n\
   max-context = 1024\n\
   \n\
   [models.judge_model.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [lane_split_chat.chat_model]\n\
   \n\
   [lane_split_judge.judge_model]\n\
   \n\
   [runtime]\n\
   default = \"lane_split_chat.chat_model\"\n\
   structured_judge = \"lane_split_judge.judge_model\"\n"

let with_lane_split_runtime f =
  let path = Filename.temp_file "compaction_lane_split_runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc lane_split_runtime_toml;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      match Runtime.save_config_text ~runtime_config_path:path lane_split_runtime_toml with
      | Error detail -> Alcotest.failf "runtime config should load: %s" detail
      | Ok () -> f ())

let test_ineligible_chat_runtime_alone_has_no_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* Reproduces the #25051 P0 symptom directly: when the keeper's own chat
     runtime is the only seed (the pre-fix behaviour), an ineligible model
     resolves to zero candidates, so the summarizer is permanently
     unavailable for that keeper. *)
  Alcotest.(check (option (list string)))
    "an ineligible seed alone resolves no candidates"
    (Some [])
    (C.For_testing.candidate_runtime_ids_for_assignment
       ~keeper_name:"keeper-test"
       ~runtime_id:ineligible_chat_runtime_id)

let test_structured_judge_seed_reaches_eligible_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* The fix: seeding the chain with the structured-judge id first gives the
     chain an eligible candidate even though the keeper's own chat runtime
     (still present as a lower-priority seed) remains ineligible. *)
  Alcotest.(check (list string))
    "structured-judge seed supplies the only eligible candidate, ordered first"
    [ eligible_judge_runtime_id ]
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ eligible_judge_runtime_id; ineligible_chat_runtime_id ])

let test_both_seeds_unresolvable_yields_no_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* No silent fallback: an unresolvable structured-judge id alongside an
     ineligible chat runtime must still resolve to zero candidates, never a
     surprise fallback onto the ineligible model. *)
  Alcotest.(check (list string))
    "no candidate when every seed fails to resolve or is ineligible"
    []
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ "no.such.runtime"; ineligible_chat_runtime_id ])

let test_duplicate_seed_collapses_to_one_candidate () =
  with_lane_split_runtime @@ fun () ->
  Alcotest.(check (list string))
    "the same runtime id named twice as a seed is tried once"
    [ eligible_judge_runtime_id ]
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ eligible_judge_runtime_id; eligible_judge_runtime_id ])

let make_test_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok m -> m
  | Error e -> Alcotest.failf "meta fixture failed: %s" e

let test_compact_policy_prefers_structured_judge_over_chat_runtime () =
  with_lane_split_runtime @@ fun () ->
  (* End-to-end proof at the Keeper_compact_policy call site (not just the
     summarizer's candidate resolution): a keeper with no explicit runtime
     assignment inherits [runtime].default for chat (ineligible here), yet
     the candidate-id list built for the compaction plan call still puts the
     structured-judge runtime first. Counterfactual: on the pre-#25051 code,
     [Compact_policy.For_testing] does not exist (single [runtime_id] sourced
     solely from the keeper's own chat assignment), so this fails to compile
     on that base — verified by stashing this fix and re-running the build. *)
  let meta = make_test_meta "lane-split-keeper" in
  Alcotest.(check (list string))
    "structured-judge runtime precedes the keeper's own chat runtime"
    [ eligible_judge_runtime_id; ineligible_chat_runtime_id ]
    (Compact_policy.For_testing.compaction_runtime_ids meta)



let eligibility_units =
  [ ordinary (text T.System "system")
  ; ordinary (text T.User "user")
  ; ordinary (text T.Tool "tool")
  ; ordinary (text T.Assistant "eligible")
  ; ordinary (text T.Assistant "   ")
  ; ordinary (message T.Assistant [ T.Text "text"; T.RedactedThinking "opaque" ])
  ; ordinary (message ~name:"named" T.Assistant [ T.Text "named" ])
  ; ordinary (message ~tool_call_id:"call" T.Assistant [ T.Text "linked" ])
  ; ordinary (message ~metadata:[ "source", `String "producer" ] T.Assistant [ T.Text "meta" ])
  ; closed_cycle "closed"
  ]

let test_only_plain_assistant_text_is_eligible () =
  Alcotest.(check bool) "mixed source has eligible text" true
    (C.has_eligible_units eligibility_units);
  List.iteri
    (fun index unit_ ->
      Alcotest.(check bool)
        (Printf.sprintf "unit %d eligibility" index)
        (index = 3)
        (C.has_eligible_units [ unit_ ]))
    eligibility_units

let validation_units =
  [ ordinary (text T.System "protected-system")
  ; ordinary (text T.Assistant "first")
  ; closed_cycle "protected-cycle"
  ; ordinary (text T.User "protected-user")
  ; ordinary (text T.Assistant "second")
  ]

let test_valid_source_decisions_accepted () =
  let result =
    plan_of_json
      ~units:validation_units
      (plan_json [ summarize 1 "first summary"; keep 4 ])
  in
  match result with
  | Error detail -> Alcotest.failf "valid source-bound plan rejected: %s" detail
  | Ok plan ->
    Alcotest.(check string) "runtime source is bound" test_runtime_id
      (C.selected_runtime_id plan);
    Alcotest.(check (list int)) "summarized source index" [ 1 ]
      (C.summarized_indices plan);
    Alcotest.(check (list int)) "nothing dropped" [] (C.dropped_indices plan)

let test_runtime_identity_is_not_normalized () =
  let exact_runtime_id = "  exact.runtime  " in
  match
    C.plan_of_json
      ~runtime_id:exact_runtime_id
      ~units:validation_units
      (plan_json [ summarize 1 "first summary"; keep 4 ])
  with
  | Error detail -> Alcotest.failf "exact runtime identity rejected: %s" detail
  | Ok plan ->
    Alcotest.(check string) "runtime identity remains exact" exact_runtime_id
      (C.selected_runtime_id plan)

let test_all_kept_rejected () =
  Alcotest.(check bool) "all-kept is not compaction" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ keep 1; keep 4 ])))

let test_drop_with_kept_accepted () =
  Alcotest.(check bool) "drop plus keep is a valid change" true
    (is_ok
       (plan_of_json ~units:validation_units (plan_json [ drop 1; keep 4 ])))

let test_protected_index_rejected () =
  Alcotest.(check bool) "provider cannot target protected source index" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ summarize 0 "x"; keep 4 ])))

let test_missing_eligible_index_rejected () =
  Alcotest.(check bool) "every eligible source needs a decision" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ summarize 1 "x" ])))

let test_duplicate_index_rejected () =
  Alcotest.(check bool) "duplicate source decision rejected" true
    (is_error
       (plan_of_json
          ~units:validation_units
          (plan_json [ summarize 1 "x"; drop 1; keep 4 ])))

let test_all_dropped_rejected () =
  Alcotest.(check bool) "planner cannot remove every eligible unit" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ drop 1; drop 4 ])))

let test_action_summary_contract_rejected () =
  let invalid =
    [ decision ~summary:"unexpected" 1 S.compaction_plan_action_keep
    ; decision ~summary:"unexpected" 1 S.compaction_plan_action_drop
    ; decision 1 S.compaction_plan_action_summarize
    ; summarize 1 "   "
    ; decision 1 "unknown-action"
    ]
  in
  List.iter
    (fun invalid_decision ->
      Alcotest.(check bool) "invalid action/summary pair" true
        (is_error
           (plan_of_json
              ~units:validation_units
              (plan_json [ invalid_decision; keep 4 ]))))
    invalid

let test_unknown_and_duplicate_fields_rejected () =
  let unknown_top =
    `Assoc
      [ S.compaction_plan_field_decisions, `List [ summarize 1 "x"; keep 4 ]
      ; "unexpected", `Null
      ]
  in
  let duplicate_top =
    `Assoc
      [ S.compaction_plan_field_decisions, `List [ summarize 1 "x"; keep 4 ]
      ; S.compaction_plan_field_decisions, `List []
      ]
  in
  let unknown_decision =
    `Assoc
      [ S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_action, `String S.compaction_plan_action_summarize
      ; S.compaction_plan_field_summary, `String "x"
      ; "unexpected", `Null
      ]
  in
  let duplicate_decision =
    `Assoc
      [ S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_action, `String S.compaction_plan_action_summarize
      ; S.compaction_plan_field_summary, `String "x"
      ]
  in
  List.iter
    (fun json ->
      Alcotest.(check bool) "non-canonical object rejected" true
        (is_error (plan_of_json ~units:validation_units json)))
    [ `Assoc []
    ; unknown_top
    ; duplicate_top
    ; plan_json [ unknown_decision; keep 4 ]
    ; plan_json [ duplicate_decision; keep 4 ]
    ]

let test_request_excludes_protected_content () =
  let units =
    [ ordinary (text T.System "SECRET_SYSTEM")
    ; ordinary (text T.User "SECRET_USER")
    ; closed_cycle "SECRET_TOOL"
    ; ordinary
        (message T.Assistant
           [ T.Text "SECRET_MIXED"; T.Thinking { content = "SECRET_THINKING"; signature = None } ])
    ; ordinary
        (message ~metadata:[ "secret", `Bool true ] T.Assistant [ T.Text "SECRET_METADATA" ])
    ; ordinary (text T.Assistant "VISIBLE_ASSISTANT")
    ]
  in
  let request = C.For_testing.messages_for_plan ~units in
  let wire = request |> List.map T.text_of_message |> String.concat "\n" in
  Alcotest.(check bool) "eligible assistant text crosses boundary" true
    (Astring.String.is_infix ~affix:"VISIBLE_ASSISTANT" wire);
  List.iter
    (fun secret ->
      Alcotest.(check bool) (secret ^ " remains private") false
        (Astring.String.is_infix ~affix:secret wire))
    [ "SECRET_SYSTEM"
    ; "SECRET_USER"
    ; "SECRET_TOOL"
    ; "SECRET_MIXED"
    ; "SECRET_THINKING"
    ; "SECRET_METADATA"
    ]

let test_apply_preserves_protected_units_and_source_order () =
  let system = text T.System "system" in
  let first = text T.Assistant "first" in
  let cycle = closed_cycle "cycle" in
  let user = text T.User "user" in
  let metadata_assistant =
    message ~metadata:[ "producer", `String "exact" ] T.Assistant [ T.Text "metadata" ]
  in
  let second = text T.Assistant "second" in
  let thinking =
    message T.Assistant
      [ T.Thinking { content = "private"; signature = Some "signed" } ]
  in
  let units =
    [ ordinary system
    ; ordinary first
    ; cycle
    ; ordinary user
    ; ordinary metadata_assistant
    ; ordinary second
    ; ordinary thinking
    ]
  in
  match
    plan_of_json
      ~units
      (plan_json [ summarize 1 "first summary"; summarize 5 "second summary" ])
  with
  | Error detail -> Alcotest.failf "expected valid plan: %s" detail
  | Ok plan ->
    let summary =
      { first with content = [ T.Text "first summary" ] }
    in
    let second_summary =
      { second with content = [ T.Text "second summary" ] }
    in
    let expected =
      [ system; summary ]
      @ (match cycle with U.Closed_tool_cycle messages -> messages | Ordinary_message _ -> [])
      @ [ user; metadata_assistant; second_summary; thinking ]
    in
    Alcotest.(check bool) "protected source constructors and order are exact" true
      (C.apply plan = expected)

(* Deterministic structural floor (RFC-compaction-deterministic-floor PR-2). *)
let floor_head = Compact_policy.For_testing.floor_protected_head_units
let floor_tail = Compact_policy.For_testing.floor_protected_tail_units
let floor_unit_text i = Printf.sprintf "u%d" i
let floor_units n = List.init n (fun i -> ordinary (text T.Assistant (floor_unit_text i)))

let floor_message_text (m : T.message) =
  match m.content with
  | [ T.Text value ] -> value
  | _ -> "<non-text>"

let test_floor_drops_middle_protects_head_and_tail () =
  let total = floor_head + floor_tail + 5 in
  let units = floor_units total in
  match
    Compact_policy.For_testing.deterministic_floor_for_testing
      ~units
      ~protected_suffix:[]
  with
  | None -> Alcotest.fail "floor must engage when the prefix has a middle span"
  | Some (kept, dropped) ->
    Alcotest.(check int)
      "dropped count equals the middle span"
      (total - floor_head - floor_tail)
      dropped;
    let expected =
      List.init floor_head (fun i -> floor_unit_text i)
      @ List.init floor_tail (fun i -> floor_unit_text (total - floor_tail + i))
    in
    Alcotest.(check (list string))
      "head and tail units survive in order; the middle is dropped"
      expected
      (List.map floor_message_text kept)

let test_floor_preserves_protected_suffix () =
  let total = floor_head + floor_tail + 3 in
  let units = floor_units total in
  let suffix = [ text T.User "suffix-marker" ] in
  match
    Compact_policy.For_testing.deterministic_floor_for_testing
      ~units
      ~protected_suffix:suffix
  with
  | None -> Alcotest.fail "floor must engage"
  | Some (kept, _dropped) ->
    (match List.rev kept with
     | last :: _ ->
       Alcotest.(check string)
         "the protected suffix is appended after the kept units"
         "suffix-marker"
         (floor_message_text last)
     | [] -> Alcotest.fail "kept messages must be non-empty")

let test_floor_noop_without_middle_span () =
  let units = floor_units (floor_head + floor_tail) in
  Alcotest.(check bool)
    "floor does not engage when there is no middle span to drop"
    true
    (Compact_policy.For_testing.deterministic_floor_for_testing
       ~units
       ~protected_suffix:[]
     = None)

(* Evidence-safety: the floor must never drop a tool cycle or a System unit,
   because Keeper_compaction_evidence requires invariant tool counts and system
   instructions are foundational. Only the middle User/Assistant unit is dropped. *)
let test_floor_preserves_tool_cycles_and_system () =
  let head = floor_units floor_head in
  let tail =
    List.init floor_tail (fun i -> ordinary (text T.Assistant (Printf.sprintf "t%d" i)))
  in
  let middle = [ closed_cycle "cyc"; ordinary (text T.System "sys"); ordinary (text T.User "usr") ] in
  let units = head @ middle @ tail in
  match
    Compact_policy.For_testing.deterministic_floor_for_testing
      ~units
      ~protected_suffix:[]
  with
  | None -> Alcotest.fail "floor must engage with a droppable middle unit"
  | Some (kept, dropped) ->
    Alcotest.(check int) "only the middle User message is dropped" 1 dropped;
    let kept_texts = List.map floor_message_text kept in
    Alcotest.(check bool) "middle User unit is dropped" false (List.mem "usr" kept_texts);
    Alcotest.(check bool) "middle System unit is preserved" true (List.mem "sys" kept_texts);
    Alcotest.(check bool)
      "tool cycle is preserved (a Tool-role message remains)"
      true
      (List.exists (fun (m : T.message) -> m.role = T.Tool) kept)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "provider"
      , [ Alcotest.test_case "runtime temperature is authoritative" `Quick
            test_provider_for_plan_preserves_runtime_temperature
        ; Alcotest.test_case "temperature omission is preserved" `Quick
            test_provider_for_plan_preserves_temperature_omission
        ; Alcotest.test_case "lane candidates keep declared order" `Quick
            test_lane_candidates_keep_declared_order
        ] )
    ; ( "deterministic_floor"
      , [ Alcotest.test_case "drops the middle, protects head and tail" `Quick
            test_floor_drops_middle_protects_head_and_tail
        ; Alcotest.test_case "preserves the protected suffix" `Quick
            test_floor_preserves_protected_suffix
        ; Alcotest.test_case "no-op without a middle span" `Quick
            test_floor_noop_without_middle_span
        ; Alcotest.test_case "preserves tool cycles and system units" `Quick
            test_floor_preserves_tool_cycles_and_system
        ] )
    ; ( "structured_judge_lane_split_25051"
      , [ Alcotest.test_case "ineligible chat runtime alone has no candidate" `Quick
            test_ineligible_chat_runtime_alone_has_no_candidate
        ; Alcotest.test_case "structured-judge seed reaches an eligible candidate" `Quick
            test_structured_judge_seed_reaches_eligible_candidate
        ; Alcotest.test_case "both seeds unresolvable yields no candidate" `Quick
            test_both_seeds_unresolvable_yields_no_candidate
        ; Alcotest.test_case "duplicate seed collapses to one candidate" `Quick
            test_duplicate_seed_collapses_to_one_candidate
        ; Alcotest.test_case "compact policy prefers structured judge over chat runtime" `Quick
            test_compact_policy_prefers_structured_judge_over_chat_runtime
        ] )
    ; ( "eligibility"
      , [ Alcotest.test_case "plain Assistant text only" `Quick
            test_only_plain_assistant_text_is_eligible
        ; Alcotest.test_case "protected content never reaches provider" `Quick
            test_request_excludes_protected_content
        ] )
    ; ( "plan_of_json"
      , [ Alcotest.test_case "valid source decisions accepted" `Quick
            test_valid_source_decisions_accepted
        ; Alcotest.test_case "runtime identity is not normalized" `Quick
            test_runtime_identity_is_not_normalized
        ; Alcotest.test_case "all kept rejected" `Quick test_all_kept_rejected
        ; Alcotest.test_case "drop with kept accepted" `Quick
            test_drop_with_kept_accepted
        ; Alcotest.test_case "protected index rejected" `Quick
            test_protected_index_rejected
        ; Alcotest.test_case "missing eligible index rejected" `Quick
            test_missing_eligible_index_rejected
        ; Alcotest.test_case "duplicate index rejected" `Quick
            test_duplicate_index_rejected
        ; Alcotest.test_case "all dropped rejected" `Quick test_all_dropped_rejected
        ; Alcotest.test_case "action summary contract rejected" `Quick
            test_action_summary_contract_rejected
        ; Alcotest.test_case "unknown and duplicate fields rejected" `Quick
            test_unknown_and_duplicate_fields_rejected
        ] )
    ; ( "apply"
      , [ Alcotest.test_case "protected units and source order stay exact" `Quick
            test_apply_preserves_protected_units_and_source_order
        ] )
    ]
