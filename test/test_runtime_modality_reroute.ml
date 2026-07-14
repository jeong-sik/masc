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

let source_path path =
  if Filename.is_relative path then
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root path
    | None -> path
  else path

let read_file path = In_channel.with_open_text (source_path path) In_channel.input_all

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

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

let test_checkpoint_resume_deduplicates_initial_history () =
  let shared =
    message_with_blocks
      [ Agent_sdk.Types.Text "shared image history"
      ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
      ]
  in
  let checkpoint_audio =
    message_with_blocks
      [ Agent_sdk.Types.Text "checkpoint-only audio"
      ; Agent_sdk.Types.audio_block ~media_type:"audio/wav" ~data:"def" ()
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
       ~goal_blocks:[ Agent_sdk.Types.Text "follow up" ])

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

(* RFC-0265 follow-up — graceful media degrade. [strip_unsupported_modality_blocks]
   drops the top-level image/audio/document blocks a text-only runtime cannot
   accept and reports the per-modality drop count; text/tool blocks are retained. *)
let dropped_count modality dropped =
  match List.assoc_opt modality dropped with Some n -> n | None -> 0

let test_strip_drops_unsupported_image () =
  let blocks =
    [ Agent_sdk.Types.Text "hello"
    ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ()) blocks
  in
  check int "only the text block is kept" 1 (List.length kept);
  check int "one image dropped" 1 (dropped_count "image" dropped)

let test_strip_keeps_supported_image () =
  let blocks =
    [ Agent_sdk.Types.Text "hi"
    ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ()
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
        [ Agent_sdk.Types.Text "prev"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"x" ()
        ]
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_messages (caps ()) messages
  in
  check int "the message is retained" 1 (List.length kept);
  let msg : Agent_sdk.Types.message = List.hd kept in
  check int "image stripped from message content" 1 (List.length msg.content);
  check int "one image dropped" 1 (dropped_count "image" dropped)

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
  check (option string) "payload role remains internal" None
    (match assoc_field "payload_role" public with
     | Some (`String value) -> Some value
     | _ -> None)

let test_media_degrade_restores_canonical_replay_prefix () =
  let canonical_history =
    [ message_with_blocks
        [ Agent_sdk.Types.Text "pre-turn"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"image" ()
        ]
    ]
  in
  let dispatch_history, _dropped =
    Runtime_agent.strip_unsupported_modality_messages
      (caps ())
      canonical_history
  in
  let assistant =
    { Agent_sdk.Types.role = Agent_sdk.Types.Assistant
    ; content = [ Agent_sdk.Types.Text "completed" ]
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
  let canonical_history = [ message_with_blocks [ Agent_sdk.Types.Text "canonical" ] ] in
  let dispatch_history = [ message_with_blocks [ Agent_sdk.Types.Text "dispatch" ] ] in
  let unrelated_checkpoint =
    [ message_with_blocks [ Agent_sdk.Types.Text "unrelated" ] ]
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
        [ Agent_sdk.Types.Text "canonical"
        ; Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"image" ()
        ]
    ]
  in
  let dispatch_history, _dropped =
    Runtime_agent.strip_unsupported_modality_messages
      (caps ())
      canonical_history
  in
  let checkpoint_messages =
    canonical_history @ [ message_with_blocks [ Agent_sdk.Types.Text "suffix" ] ]
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

let test_driver_degrade_branch_emits_manifest () =
  let source = read_file "lib/keeper/keeper_turn_driver.ml" in
  check bool "degrade branch emits manifest" true
    (string_contains source "emit_runtime_manifest"
     && string_contains source "~status:\"degraded\""
     && string_contains source "media_degrade_manifest_decision"
     && string_contains source "Keeper_runtime_manifest.Runtime_routed")

let test_runtime_agent_oas_tool_hook_fails_typed_not_failwith () =
  let source = read_file "lib/runtime/runtime_agent.ml" in
  check bool "legacy failwith hook removed" false
    (string_contains source "failwith \"oas_tool_of_masc_hook is not set\"");
  check bool "typed unset hook error present" true
    (string_contains source "runtime_agent_oas_tool_hook_unset")

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
        ; test_case "driver degrade branch emits manifest" `Quick
            test_driver_degrade_branch_emits_manifest
        ; test_case "runtime agent OAS tool hook typed failure" `Quick
            test_runtime_agent_oas_tool_hook_fails_typed_not_failwith
        ] )
    ]
