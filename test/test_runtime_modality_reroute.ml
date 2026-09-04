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

let decision_to_string : string Runtime_agent.reroute_decision -> string =
  function
  | Runtime_agent.No_reroute_needed -> "no_reroute"
  | Runtime_agent.Reroute { target; reason } ->
      Printf.sprintf "reroute:%s:%s" target reason
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

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let message_with_blocks blocks =
  { Agent_core.Types.role = Agent_core.Types.User
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
   text-only follow-up still carries that image in AGENT_CORE history. *)
let test_initial_message_media_drives_reroute () =
  let initial_messages =
    [ message_with_blocks
        [ Agent_core.Types.Text "previous image turn"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  let required =
    Runtime_agent.For_testing.required_modalities_for_run
      ~initial_messages
      ~goal_blocks:[ Agent_core.Types.Text "follow up" ]
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

(* Regression #33034: a deferred runtime lane commits to a single budgeted
   candidate, so [Keeper_turn_driver] resolves no remaining candidates and this
   decision runs with [candidates = []]. An image turn on a text-only committed
   candidate must land on the [No_capable_runtime] degrade floor — strip the
   media and run text-only — never a reroute (nowhere to go) and never the hard
   multimodal gate. Before the fix the deferred-lane branch short-circuited to
   [No_reroute_needed], which skipped the degrade and let the image dispatch to
   the text-only candidate and fail at the gate. *)
let test_no_candidate_image_hits_degrade_floor () =
  check string "empty candidates image → degrade floor"
    "no_capable:image"
    (decision_to_string
       (decide ~assigned:(caps ()) ~required:[ "image" ] ~candidates:[]))

(* Regression: when no configured runtime can accept media, the final floor gate
   must validate prior history too. Otherwise a text-only follow-up after a
   vision turn leaks image history to the provider and fails as a provider 400
   (for example "messages.content.type is invalid, allowed values: ['text']"). *)
let test_history_media_floor_rejects_before_provider () =
  let initial_messages =
    [ message_with_blocks
        [ Agent_core.Types.Text "previous image turn"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_for_run_against_capabilities
      ~provider_label:"glm-coding.glm-5-turbo"
      (caps ())
      ~initial_messages
      ~goal_blocks:[ Agent_core.Types.Text "follow up" ]
  with
  | Ok () -> fail "expected history image to be rejected before provider dispatch"
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check_contains "mentions unsupported image" ~needle:"unsupported image input" detail;
      check_contains "mentions required modality" ~needle:"required=image" detail;
      check_contains "mentions text-only support" ~needle:"supported=text" detail
  | Error err ->
      failf "expected InvalidConfig, got %s" (Agent_core.Error.to_string err)

(* Regression: AGENT_CORE resume checkpoints are provider input too. A prior image can
   live only in [agent_core_checkpoint.messages], not in MASC [initial_messages]; that
   still must drive reroute/floor validation before the provider sees it. *)
let test_checkpoint_media_drives_reroute_and_floor () =
  let checkpoint_messages =
    [ message_with_blocks
        [ Agent_core.Types.Text "checkpoint image turn"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  let required =
    Runtime_agent.For_testing.required_modalities_for_run_with_checkpoint
      ~initial_messages:[]
      ~checkpoint_messages
      ~goal_blocks:[ Agent_core.Types.Text "text-only follow up" ]
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
      ~goal_blocks:[ Agent_core.Types.Text "text-only follow up" ]
  with
  | Ok () -> fail "expected checkpoint image to be rejected before provider dispatch"
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check_contains "mentions unsupported image" ~needle:"unsupported image input" detail;
      check_contains "mentions required modality" ~needle:"required=image" detail
  | Error err ->
      failf "expected InvalidConfig, got %s" (Agent_core.Error.to_string err)

let test_checkpoint_resume_deduplicates_initial_history () =
  let shared =
    message_with_blocks
      [ Agent_core.Types.Text "shared image history"
      ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
      ]
  in
  let checkpoint_audio =
    message_with_blocks
      [ Agent_core.Types.Text "checkpoint-only audio"
      ; Agent_core.Types.audio_block ~media_type:"audio/wav" ~data:"def" ()
      ]
  in
  let active_messages =
    Runtime_agent.For_testing.messages_for_run_with_checkpoint
      ~initial_messages:[ shared ]
      ~checkpoint_messages:[ shared; checkpoint_audio ]
  in
  check int "shared history is not duplicated" 2 (List.length active_messages);
  check (list string) "required modalities include both sources"
    [ "image"; "audio" ]
    (Runtime_agent.For_testing.required_modalities_for_run_with_checkpoint
       ~initial_messages:[ shared ]
       ~checkpoint_messages:[ shared; checkpoint_audio ]
       ~goal_blocks:[ Agent_core.Types.Text "follow up" ])

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
    (Runtime_agent.For_testing.caps_admit_required_modalities (caps ()) []);
  (* text is a modality every runtime carries, and it is the one string in
     [supported_modalities_of_capabilities] that no content block demands. *)
  check bool "text is admitted by a text-only runtime" true
    (Runtime_agent.For_testing.caps_admit_required_modalities (caps ()) [ "text" ]);
  (* An unrecognised modality reports unsupported, not supported. The producers
     match exhaustively over content_block, so such a string can only arrive
     through producer/consumer drift; answering "supported" there would hand a
     block the runtime cannot process to the provider, while answering
     "unsupported" routes it into the reroute and degrade paths. *)
  check bool "unrecognised modality is not admitted" false
    (Runtime_agent.For_testing.caps_admit_required_modalities
       (caps ~image:true ~audio:true ())
       [ "hologram" ]);
  check bool "unrecognised modality is not masked by a supported sibling" false
    (Runtime_agent.For_testing.caps_admit_required_modalities
       (caps ~image:true ())
       [ "image"; "hologram" ])

(* RFC-0265 follow-up — graceful media degrade. [strip_unsupported_modality_blocks]
   drops the image/audio/document blocks a text-only runtime cannot accept —
   inside tool results as well as at the top level — and reports the per-modality
   drop count; text and tool blocks themselves are retained. *)
let dropped_count modality dropped =
  match List.assoc_opt modality dropped with Some n -> n | None -> 0

let test_strip_drops_unsupported_image () =
  let blocks =
    [ Agent_core.Types.Text "hello"
    ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ()) blocks
  in
  check int "only the text block is kept" 1 (List.length kept);
  check int "one image dropped" 1 (dropped_count "image" dropped)

let test_strip_keeps_supported_image () =
  let blocks =
    [ Agent_core.Types.Text "hi"
    ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ~image:true ()) blocks
  in
  check int "both blocks kept on a vision runtime" 2 (List.length kept);
  check int "nothing dropped" 0 (List.length dropped)

let test_strip_messages_drops_history_image () =
  let messages =
    [ message_with_blocks
        [ Agent_core.Types.Text "prev"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"x" ()
        ]
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_messages (caps ()) messages
  in
  check int "the message is retained" 1 (List.length kept);
  let msg : Agent_core.Types.message = List.hd kept in
  check int "image stripped from message content" 1 (List.length msg.content);
  check int "one image dropped" 1 (dropped_count "image" dropped)

let tool_result_with_blocks blocks =
  Agent_core.Types.ToolResult
    { tool_use_id = "call_1"
    ; content = "tool output"
    ; outcome = Agent_core.Types.Tool_succeeded
    ; json = None
    ; content_blocks = Some blocks
    }

let tool_result_blocks = function
  | Agent_core.Types.ToolResult { content_blocks = Some blocks; _ } -> blocks
  | Agent_core.Types.ToolResult { content_blocks = None; _ }
  | Agent_core.Types.Text _
  | Agent_core.Types.Thinking _
  | Agent_core.Types.ReasoningDetails _
  | Agent_core.Types.RedactedThinking _
  | Agent_core.Types.ToolUse _
  | Agent_core.Types.Image _
  | Agent_core.Types.Document _
  | Agent_core.Types.Audio _ -> fail "expected a ToolResult carrying blocks"

(* The keeper "analyst" died for four days on this shape. A tool result carrying
   an image made [required_modalities_of_content_blocks] report [image], so the
   decision was [No_capable_runtime] and the driver entered the degrade — but the
   strip only looked at top-level blocks, dropped nothing, produced no note, and
   left the image attached. The turn then failed on the provider capability gate
   with "unsupported image input", every turn, with no degrade WARN to say so. *)
let test_strip_descends_into_tool_result () =
  let blocks =
    [ Agent_core.Types.Text "hello"
    ; tool_result_with_blocks
        [ Agent_core.Types.Text "caption"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ()
        ]
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ()) blocks
  in
  check int "text and tool result are both kept" 2 (List.length kept);
  check int "nested image is dropped" 1 (dropped_count "image" dropped);
  let nested = tool_result_blocks (List.nth kept 1) in
  check int "only the nested caption survives" 1 (List.length nested)

let test_strip_keeps_nested_media_a_vision_runtime_accepts () =
  let blocks =
    [ tool_result_with_blocks
        [ Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ~image:true ()) blocks
  in
  check int "the tool result is kept" 1 (List.length kept);
  check int "nothing dropped on a vision runtime" 0 (List.length dropped);
  check int "nested image survives" 1 (List.length (tool_result_blocks (List.hd kept)))

(* The invariant the two walks have to hold together: whatever
   [required_modalities_of_content_blocks] reports as required,
   [strip_unsupported_modality_blocks] can remove — so the stripped blocks pass
   the same capability gate that would otherwise reject the turn. This is the
   assertion that fails when the scan descends into tool results and the strip
   does not. *)
let test_stripped_blocks_pass_the_capability_floor () =
  let blocks =
    [ Agent_core.Types.Text "hello"
    ; tool_result_with_blocks
        [ Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
    ]
  in
  check (list string) "the scan requires image"
    [ "image" ]
    (Runtime_agent.For_testing.required_modalities_of_content_blocks blocks);
  let kept, _dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ()) blocks
  in
  check (list string) "the strip leaves nothing that requires image"
    []
    (Runtime_agent.For_testing.required_modalities_of_content_blocks kept);
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"glm-coding.glm-5-turbo"
      (caps ())
      kept
  with
  | Ok () -> ()
  | Error err ->
      failf
        "stripped blocks must pass the capability floor, got %s"
        (Agent_core.Error.to_string err)

let test_strip_messages_descends_into_tool_result () =
  let messages =
    [ message_with_blocks
        [ tool_result_with_blocks
            [ Agent_core.Types.image_block ~media_type:"image/png" ~data:"x" () ]
        ]
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_messages (caps ()) messages
  in
  check int "the message is retained" 1 (List.length kept);
  check int "nested history image dropped" 1 (dropped_count "image" dropped);
  let msg : Agent_core.Types.message = List.hd kept in
  check int "the tool result is retained" 1 (List.length msg.content);
  check int "its image is gone" 0 (List.length (tool_result_blocks (List.hd msg.content)))

(* A reroute names a runtime that satisfies the required modality. When the only
   entry offered is the assigned runtime's own binding — which by definition does
   not satisfy it, or the decision would have been [No_reroute_needed] — the
   answer is the degrade floor. A reroute to the runtime being rerouted away from
   is not an outcome: the target is selected from a candidate set the assigned
   runtime is removed from, and [reroute_decision] is private, so no other module
   can build one either. *)
let test_incapable_self_candidate_is_the_floor () =
  check string "assigned runtime is never its own reroute target"
    "no_capable:image"
    (decision_to_string
       (decide ~assigned:(caps ()) ~required:[ "image" ]
          ~candidates:[ ("assigned_runtime", caps ()) ]))

let test_degrade_note_some_when_dropped () =
  match
    Runtime_agent.media_degrade_note
      ~runtime_id:"glm-coding.glm-5-turbo"
      [ ("image", 2) ]
  with
  | None -> fail "expected a note when media was dropped"
  | Some note ->
      check_contains "names the runtime" ~needle:"glm-coding.glm-5-turbo" note;
      check_contains "states the omission count" ~needle:"2" note

let test_degrade_note_none_when_empty () =
  check (option string) "no note when nothing dropped" None
    (Runtime_agent.media_degrade_note ~runtime_id:"r" []);
  check (option string) "no note when all counts zero" None
    (Runtime_agent.media_degrade_note ~runtime_id:"r" [ ("image", 0) ])

let test_degrade_manifest_public_projection () =
  let decision =
    Masc.Keeper_turn_driver.For_testing.media_degrade_manifest_decision
      ~runtime_id:"text-runtime"
      [ ("image", 1); ("audio", 2) ]
  in
  let public = Masc.Keeper_runtime_manifest.public_projection_of_decision decision in
  check (option string) "routing action"
    (Some "media_degraded_to_text")
    (match assoc_field "routing_action" public with
     | Some (`String value) -> Some value
     | _ -> None);
  check (option string) "routing reason"
    (Some "no_configured_runtime_accepts_required_media")
    (match assoc_field "routing_reason" public with
     | Some (`String value) -> Some value
     | _ -> None);
  check (option string) "runtime id"
    (Some "text-runtime")
    (match assoc_field "degraded_runtime_id" public with
     | Some (`String value) -> Some value
     | _ -> None);
  check (option int) "drop total"
    (Some 3)
    (match assoc_field "media_dropped_total" public with
     | Some (`Int value) -> Some value
     | _ -> None);
  check (option string) "deterministic count summary"
    (Some "audio=2,image=1")
    (match assoc_field "media_dropped_counts" public with
     | Some (`String value) -> Some value
     | _ -> None);
  check (option string) "payload role is explicit operator evidence"
    (Some "operator_evidence")
    (match assoc_field "payload_role" public with
     | Some (`String value) -> Some value
     | _ -> None)

let test_media_degrade_restores_canonical_replay_prefix () =
  let canonical_history =
    [ message_with_blocks
        [ Agent_core.Types.Text "pre-turn"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"image" ()
        ]
    ]
  in
  let dispatch_history, _dropped =
    Runtime_agent.strip_unsupported_modality_messages
      (caps ())
      canonical_history
  in
  let assistant =
    { Agent_core.Types.role = Agent_core.Types.Assistant
    ; content = [ Agent_core.Types.Text "completed" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  match
    Masc.Keeper_replay_prefix.restore_messages
      (Masc.Keeper_replay_prefix.media_degraded
         ~canonical_prefix:canonical_history
         ~dispatch_prefix:dispatch_history)
      (dispatch_history @ [ assistant ])
  with
  | Error error -> fail (Masc.Keeper_replay_prefix.restore_error_to_string error)
  | Ok restored ->
    check int "canonical history plus current suffix" 2 (List.length restored);
    check bool "original media history is restored" true (List.hd restored = List.hd canonical_history);
    check bool "current assistant suffix is preserved" true (List.nth restored 1 = assistant)

let test_media_degrade_rejects_checkpoint_prefix_drift () =
  let canonical_history = [ message_with_blocks [ Agent_core.Types.Text "canonical" ] ] in
  let dispatch_history = [ message_with_blocks [ Agent_core.Types.Text "dispatch" ] ] in
  let unrelated_checkpoint =
    [ message_with_blocks [ Agent_core.Types.Text "unrelated" ] ]
  in
  match
    Masc.Keeper_replay_prefix.restore_messages
      (Masc.Keeper_replay_prefix.media_degraded
         ~canonical_prefix:canonical_history
         ~dispatch_prefix:dispatch_history)
      unrelated_checkpoint
  with
  | Error _ -> ()
  | Ok _ -> fail "expected dispatch-prefix drift to fail closed"

let test_media_degrade_preserves_already_canonical_checkpoint () =
  let canonical_history =
    [ message_with_blocks
        [ Agent_core.Types.Text "canonical"
        ; Agent_core.Types.image_block ~media_type:"image/png" ~data:"image" ()
        ]
    ]
  in
  let dispatch_history, _dropped =
    Runtime_agent.strip_unsupported_modality_messages
      (caps ())
      canonical_history
  in
  let checkpoint_messages =
    canonical_history @ [ message_with_blocks [ Agent_core.Types.Text "suffix" ] ]
  in
  match
    Masc.Keeper_replay_prefix.restore_messages
      (Masc.Keeper_replay_prefix.media_degraded
         ~canonical_prefix:canonical_history
         ~dispatch_prefix:dispatch_history)
      checkpoint_messages
  with
  | Error error -> fail (Masc.Keeper_replay_prefix.restore_error_to_string error)
  | Ok restored ->
    check
      bool
      "already canonical checkpoint is unchanged"
      true
      (restored = checkpoint_messages)

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
        ; test_case "empty candidates image → degrade floor" `Quick
            test_no_candidate_image_hits_degrade_floor
        ; test_case "incapable self candidate → degrade floor" `Quick
            test_incapable_self_candidate_is_the_floor
        ; test_case "history media floor rejects before provider" `Quick
            test_history_media_floor_rejects_before_provider
        ; test_case "checkpoint media drives reroute and floor" `Quick
            test_checkpoint_media_drives_reroute_and_floor
        ; test_case "checkpoint resume deduplicates initial history" `Quick
            test_checkpoint_resume_deduplicates_initial_history
        ; test_case "deterministic" `Quick test_decision_is_deterministic
        ] )
    ; ( "caps_admit_required_modalities"
      , [ test_case "multi-modality predicate" `Quick
            test_caps_admit_required_modalities
        ] )
    ; ( "media_degrade"
      , [ test_case "strip drops unsupported image" `Quick
            test_strip_drops_unsupported_image
        ; test_case "strip keeps supported image" `Quick
            test_strip_keeps_supported_image
        ; test_case "strip messages drops history image" `Quick
            test_strip_messages_drops_history_image
        ; test_case "strip descends into tool result" `Quick
            test_strip_descends_into_tool_result
        ; test_case "strip keeps nested media a vision runtime accepts" `Quick
            test_strip_keeps_nested_media_a_vision_runtime_accepts
        ; test_case "stripped blocks pass the capability floor" `Quick
            test_stripped_blocks_pass_the_capability_floor
        ; test_case "strip messages descends into tool result" `Quick
            test_strip_messages_descends_into_tool_result
        ; test_case "degrade note when dropped" `Quick
            test_degrade_note_some_when_dropped
        ; test_case "degrade note none when empty" `Quick
            test_degrade_note_none_when_empty
        ; test_case "degrade manifest public projection" `Quick
            test_degrade_manifest_public_projection
        ; test_case "degrade restores canonical replay prefix" `Quick
            test_media_degrade_restores_canonical_replay_prefix
        ; test_case "degrade rejects checkpoint prefix drift" `Quick
            test_media_degrade_rejects_checkpoint_prefix_drift
        ; test_case "degrade preserves an already canonical checkpoint" `Quick
            test_media_degrade_preserves_already_canonical_checkpoint
        ] )
    ]
