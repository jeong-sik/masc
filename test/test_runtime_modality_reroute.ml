(* RFC-0265 — capability-driven proactive runtime reroute (modality-gated).

   Pure-decision tests for [Runtime_agent.decide_modality_reroute] and the shared
   [caps_admit_required_modalities] accept predicate. The decision takes data (a
   candidate list) rather than reading the runtime cache, so no [Runtime.init_*]
   is required — the tests are fully deterministic. *)

open Alcotest

let caps ?(image = false) ?(audio = false) ?(multimodal = false) () =
  { Llm_provider.Capabilities.default_capabilities with
    supports_image_input = image
  ; supports_audio_input = audio
  ; supports_multimodal_inputs = multimodal
  }

let decision_to_string : Runtime_agent.reroute_decision -> string = function
  | Runtime_agent.No_reroute_needed -> "no_reroute"
  | Runtime_agent.Reroute { to_runtime_id; reason } ->
      Printf.sprintf "reroute:%s:%s" to_runtime_id reason
  | Runtime_agent.No_capable_runtime { required } ->
      Printf.sprintf "no_capable:%s" (String.concat "," required)

let decide ~assigned ~required ~candidates =
  Runtime_agent.decide_modality_reroute
    ~assigned_caps:assigned
    ~required_modalities:required
    ~candidates

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop index =
      index + needle_len <= haystack_len
      && (String.sub haystack index needle_len = needle || loop (index + 1))
    in
    loop 0

let check_contains label ~needle haystack =
  check bool label true (string_contains haystack needle)

let message_with_blocks blocks =
  { Agent_sdk.Types.role = Agent_sdk.Types.User
  ; content = blocks
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }

(* A text turn ([required = []]) is admitted by any runtime, so it never reroutes
   — the common path stays untouched. *)
let test_text_turn_no_reroute () =
  check string "text turn"
    "no_reroute"
    (decision_to_string (decide ~assigned:(caps ()) ~required:[] ~candidates:[]))

(* An image turn on a vision-capable assigned runtime stays put. *)
let test_image_turn_on_capable_no_reroute () =
  check string "image on vision model"
    "no_reroute"
    (decision_to_string
       (decide ~assigned:(caps ~image:true ()) ~required:[ "image" ]
          ~candidates:[]))

(* Image turn on a text-only assigned runtime reroutes to the first capable
   candidate in the given order (text_b is skipped, vision_c wins over
   vision_d). *)
let test_image_turn_reroutes_to_first_capable () =
  let candidates =
    [ ("text_b", caps ())
    ; ("vision_c", caps ~image:true ())
    ; ("vision_d", caps ~image:true ())
    ]
  in
  check string "reroute to first capable in order"
    "reroute:vision_c:assigned runtime lacks image input"
    (decision_to_string (decide ~assigned:(caps ()) ~required:[ "image" ] ~candidates))

(* Regression: media retained in initial history must drive the same reroute as
   media in the current turn. The dashboard image turn succeeds first; the next
   text-only follow-up still carries that image in OAS history. *)
let test_initial_message_media_drives_reroute () =
  let initial_messages =
    [ message_with_blocks
        [ Agent_sdk.Types.Text "previous image turn"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  let required =
    Runtime_agent.For_testing.required_modalities_for_run
      ~initial_messages
      ~goal_blocks:[ Agent_sdk.Types.Text "follow up" ]
  in
  check string "history image reroutes"
    "reroute:vision_c:assigned runtime lacks image input"
    (decision_to_string
       (decide
          ~assigned:(caps ())
          ~required
          ~candidates:[ ("text_b", caps ()); ("vision_c", caps ~image:true ()) ]))

(* Candidate ordering is the caller's contract: with the same capable set in a
   different order, the first listed wins. This pins media_failover precedence. *)
let test_candidate_order_is_honored () =
  check string "first listed capable wins"
    "reroute:vision_d:assigned runtime lacks image input"
    (decision_to_string
       (decide ~assigned:(caps ()) ~required:[ "image" ]
          ~candidates:
            [ ("vision_d", caps ~image:true ())
            ; ("vision_c", caps ~image:true ())
            ]))

(* No configured runtime admits the modality → floor: the assigned runtime stands
   and the loud capability gate rejects downstream. *)
let test_no_capable_runtime_floor () =
  check string "no capable → floor"
    "no_capable:image"
    (decision_to_string
       (decide ~assigned:(caps ()) ~required:[ "image" ]
          ~candidates:[ ("text_b", caps ()); ("audio_c", caps ~audio:true ()) ]))

(* Regression: when no configured runtime can accept media, the final floor gate
   must validate prior history too. Otherwise a text-only follow-up after a
   vision turn leaks image history to the provider and fails as a provider 400
   (for example "messages.content.type is invalid, allowed values: ['text']"). *)
let test_history_media_floor_rejects_before_provider () =
  let initial_messages =
    [ message_with_blocks
        [ Agent_sdk.Types.Text "previous image turn"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_for_run_against_capabilities
      ~provider_label:"glm-coding.glm-5-turbo"
      (caps ())
      ~initial_messages
      ~goal_blocks:[ Agent_sdk.Types.Text "follow up" ]
  with
  | Ok () -> fail "expected history image to be rejected before provider dispatch"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check_contains "mentions unsupported image" ~needle:"unsupported image input" detail;
      check_contains "mentions required modality" ~needle:"required=image" detail;
      check_contains "mentions text-only support" ~needle:"supported=text" detail
  | Error err ->
      failf "expected InvalidConfig, got %s" (Agent_sdk.Error.to_string err)

(* Regression: OAS resume checkpoints are provider input too. A prior image can
   live only in [oas_checkpoint.messages], not in MASC [initial_messages]; that
   still must drive reroute/floor validation before the provider sees it. *)
let test_checkpoint_media_drives_reroute_and_floor () =
  let checkpoint_messages =
    [ message_with_blocks
        [ Agent_sdk.Types.Text "checkpoint image turn"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  let required =
    Runtime_agent.For_testing.required_modalities_for_run_with_checkpoint
      ~initial_messages:[]
      ~checkpoint_messages
      ~goal_blocks:[ Agent_sdk.Types.Text "text-only follow up" ]
  in
  check (list string) "checkpoint image required" [ "image" ] required;
  check string "checkpoint image reroutes"
    "reroute:vision_c:assigned runtime lacks image input"
    (decision_to_string
       (decide
          ~assigned:(caps ())
          ~required
          ~candidates:[ ("text_b", caps ()); ("vision_c", caps ~image:true ()) ]));
  match
    Runtime_agent.For_testing
    .validate_content_blocks_for_run_against_capabilities_with_checkpoint
      ~provider_label:"glm-coding.glm-5-turbo"
      (caps ())
      ~initial_messages:[]
      ~checkpoint_messages
      ~goal_blocks:[ Agent_sdk.Types.Text "text-only follow up" ]
  with
  | Ok () -> fail "expected checkpoint image to be rejected before provider dispatch"
  | Error (Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check_contains "mentions unsupported image" ~needle:"unsupported image input" detail;
      check_contains "mentions required modality" ~needle:"required=image" detail
  | Error err ->
      failf "expected InvalidConfig, got %s" (Agent_sdk.Error.to_string err)

(* The decision is a pure function: identical inputs yield identical output. *)
let test_decision_is_deterministic () =
  let candidates = [ ("text_b", caps ()); ("vision_c", caps ~image:true ()) ] in
  let d1 = decide ~assigned:(caps ()) ~required:[ "image" ] ~candidates in
  let d2 = decide ~assigned:(caps ()) ~required:[ "image" ] ~candidates in
  check string "identical inputs → identical decision"
    (decision_to_string d1)
    (decision_to_string d2)

(* The shared accept predicate: a runtime admits a multi-modality turn only when
   it supports every required modality; missing one rejects. *)
let test_caps_admit_required_modalities () =
  check bool "image+audio runtime admits image+audio" true
    (Runtime_agent.For_testing.caps_admit_required_modalities
       (caps ~image:true ~audio:true ())
       [ "image"; "audio" ]);
  check bool "image-only runtime rejects image+audio" false
    (Runtime_agent.For_testing.caps_admit_required_modalities
       (caps ~image:true ())
       [ "image"; "audio" ]);
  check bool "empty required is always admitted" true
    (Runtime_agent.For_testing.caps_admit_required_modalities (caps ()) [])

let () =
  run "rfc0265_modality_reroute"
    [ ( "decide_modality_reroute"
      , [ test_case "text turn no reroute" `Quick test_text_turn_no_reroute
        ; test_case "image on capable no reroute" `Quick
            test_image_turn_on_capable_no_reroute
        ; test_case "reroute to first capable" `Quick
            test_image_turn_reroutes_to_first_capable
        ; test_case "initial message media drives reroute" `Quick
            test_initial_message_media_drives_reroute
        ; test_case "candidate order honored" `Quick test_candidate_order_is_honored
        ; test_case "no capable floor" `Quick test_no_capable_runtime_floor
        ; test_case "history media floor rejects before provider" `Quick
            test_history_media_floor_rejects_before_provider
        ; test_case "checkpoint media drives reroute and floor" `Quick
            test_checkpoint_media_drives_reroute_and_floor
        ; test_case "deterministic" `Quick test_decision_is_deterministic
        ] )
    ; ( "caps_admit_required_modalities"
      , [ test_case "multi-modality predicate" `Quick
            test_caps_admit_required_modalities
        ] )
    ]
