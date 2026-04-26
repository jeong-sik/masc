(** #10404: pre-fix [Discovery_history.endpoint_to_record] kept only the
    head of the loaded model list, recording 'qwen3:8b' for every probe
    while four cascades referenced 'qwen3.6:27b-coding-nvfp4'.  These
    tests pin the new [models : string list] field and verify the head
    backward-compatibility (model_id stays populated). *)

open Alcotest
module DH = Masc_mcp.Discovery_history

let make ~models : DH.probe_record =
  { ts = 1777129200.0
  ; endpoint_url = "http://127.0.0.1:11434"
  ; healthy = true
  ; model_id =
      (match models with
       | m :: _ -> Some m
       | [] -> None)
  ; models
  ; ctx_size = Some 40960
  ; total_slots = Some 4
  ; busy_slots = Some 0
  ; idle_slots = Some 4
  }
;;

let json_string_of (json : Yojson.Safe.t) = Yojson.Safe.to_string json

let test_models_list_is_emitted () =
  let r =
    make
      ~models:
        [ "qwen3:8b"
        ; "qwen3.6:27b-coding-nvfp4"
        ; "qwen3.6:27b-coding-bf16"
        ; "supergemma4:e4b-abliterated-mlx"
        ]
  in
  let s = json_string_of (DH.record_to_json r) in
  check bool "models field present" true (Astring.String.is_infix ~affix:"\"models\":" s);
  check
    bool
    "second model preserved"
    true
    (Astring.String.is_infix ~affix:"qwen3.6:27b-coding-nvfp4" s);
  check
    bool
    "fourth model preserved"
    true
    (Astring.String.is_infix ~affix:"supergemma4:e4b-abliterated-mlx" s)
;;

let test_model_id_is_head_for_legacy_readers () =
  let r = make ~models:[ "qwen3:8b"; "qwen3.6:27b-coding-nvfp4" ] in
  let s = json_string_of (DH.record_to_json r) in
  check
    bool
    "model_id field still present"
    true
    (Astring.String.is_infix ~affix:"\"model_id\":\"qwen3:8b\"" s)
;;

let test_empty_models_omits_field () =
  let r = make ~models:[] in
  let s = json_string_of (DH.record_to_json r) in
  check
    bool
    "no models field when list empty"
    false
    (Astring.String.is_infix ~affix:"\"models\":" s);
  check
    bool
    "no model_id field when empty"
    false
    (Astring.String.is_infix ~affix:"\"model_id\":" s)
;;

let test_single_model_round_trip () =
  let r = make ~models:[ "qwen3.6:27b-coding-nvfp4" ] in
  let s = json_string_of (DH.record_to_json r) in
  check
    bool
    "single-model models field present"
    true
    (Astring.String.is_infix ~affix:"\"models\":[\"qwen3.6:27b-coding-nvfp4\"]" s);
  check
    bool
    "single-model model_id matches head"
    true
    (Astring.String.is_infix ~affix:"\"model_id\":\"qwen3.6:27b-coding-nvfp4\"" s)
;;

let () =
  run
    "discovery_history_models_10404"
    [ ( "model_preservation"
      , [ test_case "full models list serialised" `Quick test_models_list_is_emitted
        ; test_case
            "model_id stays = head for legacy readers"
            `Quick
            test_model_id_is_head_for_legacy_readers
        ; test_case
            "empty model list omits both fields"
            `Quick
            test_empty_models_omits_field
        ; test_case
            "single-model round-trip stays consistent"
            `Quick
            test_single_model_round_trip
        ] )
    ]
;;
