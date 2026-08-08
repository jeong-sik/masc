(** Tests for [Llm_provider.Modality] reorder policy and capability
    integration with Gemma 4 [Visual_first]. *)

open Alcotest
open Llm_provider

let block_kind = function
  | Types.Text _ -> "Text"
  | Types.Image _ -> "Image"
  | Types.Audio _ -> "Audio"
  | Types.Document _ -> "Document"
  | Types.Thinking _ -> "Thinking"
  | Types.ReasoningDetails _ -> "ReasoningDetails"
  | Types.RedactedThinking _ -> "RedactedThinking"
  | Types.ToolUse _ -> "ToolUse"
  | Types.ToolResult _ -> "ToolResult"
;;

let kinds bs = List.map block_kind bs
let mk_text s = Types.Text s

let mk_image () =
  Types.Image { media_type = "image/png"; data = "AAAA"; source_type = Types.Base64 }
;;

let mk_audio () =
  Types.Audio { media_type = "audio/mp3"; data = "BBBB"; source_type = Types.Base64 }
;;

let mk_document () =
  Types.Document
    { media_type = "application/pdf"; data = "CCCC"; source_type = Types.Base64 }
;;

let test_preserve_input_order () =
  let blocks = [ mk_text "before"; mk_image (); mk_text "after" ] in
  let result = Modality.reorder Modality.Preserve_input_order blocks in
  check (list string) "order unchanged" [ "Text"; "Image"; "Text" ] (kinds result)
;;

let test_visual_first_moves_image_ahead () =
  let blocks = [ mk_text "describe"; mk_image () ] in
  let result = Modality.reorder Modality.Visual_first blocks in
  check (list string) "image leads" [ "Image"; "Text" ] (kinds result)
;;

let test_visual_first_stable_within_groups () =
  (* Image, Text, Audio, Text → Visual_first → Image, Audio, Text, Text *)
  let blocks = [ mk_image (); mk_text "t1"; mk_audio (); mk_text "t2"; mk_document () ] in
  let result = Modality.reorder Modality.Visual_first blocks in
  check
    (list string)
    "stable partition by group"
    [ "Image"; "Audio"; "Document"; "Text"; "Text" ]
    (kinds result)
;;

let test_visual_first_no_visuals_is_identity () =
  let blocks = [ mk_text "a"; mk_text "b" ] in
  let result = Modality.reorder Modality.Visual_first blocks in
  check (list string) "no visuals, no change" [ "Text"; "Text" ] (kinds result)
;;

let test_default_capability_is_preserve () =
  let p = Capabilities.default_capabilities.modality_priority in
  match p with
  | Modality.Preserve_input_order -> ()
  | Modality.Visual_first -> Alcotest.fail "default should be Preserve_input_order"
;;

let test_gemma4_capability_is_visual_first () =
  match Capabilities.for_model_id "google/gemma-4-31B-it" with
  | None -> Alcotest.fail "google/gemma-4-31B-it should have a capability entry"
  | Some c ->
    (match c.modality_priority with
     | Modality.Visual_first -> ()
     | Modality.Preserve_input_order ->
       Alcotest.fail
         "google/gemma-4-31B-it should be Visual_first per Gemma 4 best practices")
;;

let test_non_gemma_inherits_preserve () =
  (* Anthropic models stay Preserve_input_order — the default — since
     Anthropic does not call out a modality-order preference. *)
  match Capabilities.for_model_id "claude-sonnet-4-6" with
  | None -> () (* not in model catalog — fine, default applies *)
  | Some c ->
    (match c.modality_priority with
     | Modality.Preserve_input_order -> ()
     | Modality.Visual_first -> Alcotest.fail "claude should not opt into Visual_first")
;;

let () =
  Alcotest.run
    "modality"
    [ ( "reorder"
      , [ test_case "Preserve_input_order is identity" `Quick test_preserve_input_order
        ; test_case
            "Visual_first moves image ahead"
            `Quick
            test_visual_first_moves_image_ahead
        ; test_case
            "Visual_first stable within groups"
            `Quick
            test_visual_first_stable_within_groups
        ; test_case
            "Visual_first no-visuals identity"
            `Quick
            test_visual_first_no_visuals_is_identity
        ] )
    ; ( "capability_wiring"
      , [ test_case
            "default_capabilities = Preserve_input_order"
            `Quick
            test_default_capability_is_preserve
        ; test_case
            "google/gemma-4-31B-it = Visual_first"
            `Quick
            test_gemma4_capability_is_visual_first
        ; test_case
            "non-gemma stays Preserve_input_order"
            `Quick
            test_non_gemma_inherits_preserve
        ] )
    ]
;;
