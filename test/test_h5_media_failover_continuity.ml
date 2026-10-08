(* [하네스 H5 — task-2187] Provider failover 뒤에도 첨부의 의미와 출처가
   유지되는지를 관측한다.

   Board 계약 goal-harness-continuity-20261007 H5. 측정 대상 경계:

   - 공통 직렬화(content_block_to_json)와 재해독(content_block_of_json)을
     통과한 뒤 Audio/Document block 의 (media_type, source_type, data)
     바이트 동일성 — 의미·출처 유지의 기계 판정 조건
   - base64_media_payload 의 fail-closed: Base64 가 아닌 출처(Url/File_id)
     를 inline 바이너리만 받는 wire 로 재해석하지 않는지
   - text-only 런타임 투영(strip_unsupported_modality)이 audio/document
     를 drop 하고 그 수를 알려주는지, note 가 남는지
   - checkpoint 직렬화(Checkpoint.to_json/of_json) 왕복에서 media 바이트가
     살아남는지 (failover 후 다음 시도가 원본을 다시 받는 근거)

   이 파일은 관측만 하고 PASS/FAIL 판정을 발명하지 않는다. 판정은 이
   하네스가 내는 것이 아니라 계약·증거를 읽는 리뷰어와 검증자의 몫이다. *)

open Alcotest

module Workspace = Masc.Workspace
module Api_common = Llm_provider.Api_common
module Capabilities = Llm_provider.Capabilities
module Types = Agent_core.Types
module Checkpoint = Agent_core.Checkpoint
module Context = Agent_core.Context
module Runtime_agent = Runtime_agent

let log fmt =
  Printf.ksprintf (fun s -> print_endline ("H5 " ^ s)) fmt
;;

let stage name = log "STAGE %s" name
;;

(* ------------------------------------------------------------------ *)
(* 공용 fixture: 마커 바이트가 들어간 audio/document block              *)

let marker_audio_data = "h5-audio-bytes-띄어쓰기-007::" ^ String.make 512 'a'
let marker_document_data = "h5-document-bytes-0007::" ^ String.make 512 'b'

let audio_block ?(source_type = Types.Base64) () =
  Types.audio_block
    ~media_type:"audio/wav"
    ~data:marker_audio_data
    ~source_type
    ()
;;

let document_block ?(source_type = Types.Base64) () =
  Types.document_block
    ~media_type:"application/pdf"
    ~data:marker_document_data
    ~source_type
    ()
;;

let sha256_of_block block =
  Api_common.content_block_to_json block
  |> Yojson.Safe.to_string
  |> Digest.string
  |> Digest.to_hex
;;

let describe_source_type = function
  | Types.Base64 -> "base64"
  | Types.Url -> "url"
  | Types.File_id -> "file_id"
;;

(* block 의 (modality, media_type, source_type, data) 를 관측 문자로. *)
let describe_block block =
  match block with
  | Types.Audio { media_type; data; source_type } ->
    Printf.sprintf "audio media_type=%s source=%s data_len=%d data_sha256_prefix=%s"
      media_type
      (describe_source_type source_type)
      (String.length data)
      (String.sub (sha256_of_block block) 0 16)
  | Types.Document { media_type; data; source_type } ->
    Printf.sprintf "document media_type=%s source=%s data_len=%d data_sha256_prefix=%s"
      media_type
      (describe_source_type source_type)
      (String.length data)
      (String.sub (sha256_of_block block) 0 16)
  | Types.Image _ -> "image"
  | Types.Text _ -> "text"
  | _ -> "other"
;;

let blocks_equal a b =
  let json_of = Api_common.content_block_to_json in
  Yojson.Safe.equal (json_of a) (json_of b)
;;

(* ------------------------------------------------------------------ *)
(* s1: 공통 직렬화 왕복 — 의미·출처의 바이트 동일성                     *)

let s1_serialization_roundtrip () =
  stage "s1: content_block_to_json roundtrip keeps audio/document bytes";
  let cases =
    [ ("audio_base64", audio_block ())
    ; ("document_base64", document_block ())
    ; ("audio_url", audio_block ~source_type:Types.Url ())
    ; ("document_url", document_block ~source_type:Types.Url ())
    ]
  in
  List.iter
    (fun (name, block) ->
       let json = Api_common.content_block_to_json block in
       (* 재해독 경계: content_block_of_json_result 는 decode 오류 합타입을
          result 로 돌려준다. Ok 면 원본과 structural+byte 로 같아야 한다. *)
       let decoded =
         match
           Api_common.content_block_of_json_result json
         with
         | Ok decoded -> decoded
         | Error error ->
           fail (name ^ ": decode failed: " ^ Api_common.content_block_decode_error_to_string error)
       in
       let equal = blocks_equal block decoded in
       let original_sha = sha256_of_block block in
       let decoded_sha = sha256_of_block decoded in
       log "S1 %s roundtrip_equal=%b original_sha=%s decoded_sha=%s bytes_equal=%b"
         name equal original_sha decoded_sha (String.equal original_sha decoded_sha);
       (* JSON 안에서 출처 필드가 그대로 남는지 직접 관측한다. *)
       (match json with
        | `Assoc fields ->
          let source_json = List.assoc_opt "source" fields in
          (match source_json with
           | Some (`Assoc source_fields) ->
             let source_type_field =
               match List.assoc_opt "type" source_fields with
               | Some (`String value) -> value
               | _ -> "absent"
             in
             let media_type_field =
               match List.assoc_opt "media_type" source_fields with
               | Some (`String value) -> value
               | _ -> "absent"
             in
             log "S1_JSON %s source.type=%s media_type=%s" name source_type_field media_type_field
           | _ -> log "S1_JSON %s has no source assoc" name)
        | _ -> log "S1_JSON %s is not an assoc" name))
    cases
;;

(* ------------------------------------------------------------------ *)
(* s3: fail-closed — Base64 가 아닌 출처의 재해석 금지                  *)

let s3_fail_closed_sources () =
  stage "s3: non-base64 sources fail closed instead of reinterpretation";
  let cases =
    [ ("audio_url", audio_block ~source_type:Types.Url ())
    ; ("audio_file_id", audio_block ~source_type:Types.File_id ())
    ; ("document_url", document_block ~source_type:Types.Url ())
    ; ("document_file_id", document_block ~source_type:Types.File_id ())
    ]
  in
  List.iter
    (fun (name, block) ->
       let backend = "gemini" in
       let block_name = match block with Types.Audio _ -> "audio" | Types.Document _ -> "document" | _ -> "other" in
       let data =
         match block with
         | Types.Audio { data; _ }
         | Types.Document { data; _ } -> data
         | _ -> ""
       in
       match
         Api_common.base64_media_payload
           ~backend
           ~block:block_name
           ~data
           (match block with
            | Types.Audio { source_type; _ }
            | Types.Document { source_type; _ } -> source_type
            | _ -> Types.Base64)
       with
       | payload ->
         log "S3 %s UNEXPECTED_PASSTHROUGH payload_len=%d (base64 passthrough would lose the origin)"
           name (String.length payload)
       | exception failure ->
         let message = Printexc.to_string failure in
         log "S3 %s REJECTED exception=%s (fail-closed: no reinterpretation)" name message)
    cases
;;

(* ------------------------------------------------------------------ *)
(* s2: text-only 런타임 투영 — strip 개수와 note                        *)

let caps ?(image = false) ?(audio = false) ?(document = false) ?(multimodal = false) () =
  { Llm_provider.Capabilities.default_capabilities with
    supports_image_input = image
  ; supports_audio_input = audio
  ; supports_document_input = document
  ; supports_multimodal_inputs = multimodal
  }
;;

let s2_projection_drops_and_notes () =
  stage "s2: text-only projection strips audio/document with counts and a note";
  let blocks =
    [ Types.Text "turn carrying attachments"
    ; audio_block ()
    ; document_block ()
    ]
  in
  let kept, dropped =
    Runtime_agent.strip_unsupported_modality_blocks (caps ()) blocks
  in
  log "S2 text-only: kept=%d dropped=%s"
    (List.length kept)
    (String.concat ","
       (List.map (fun (modality, count) -> modality ^ "=" ^ string_of_int count) dropped));
  (match Runtime_agent.media_degrade_note ~runtime_id:"text-only.runtime" dropped with
   | None -> log "S2 note=none (unexpected when something was dropped)"
   | Some note -> log "S2 note=%s" note);
  let kept_media, dropped_media =
    Runtime_agent.strip_unsupported_modality_blocks
      (caps ~image:true ~audio:true ~document:true ~multimodal:true ())
      blocks
  in
  log "S2 media-capable: kept=%d dropped=%d (attachments must survive failover onto a capable runtime)"
    (List.length kept_media)
    (List.length dropped_media);
  (* failover 관측: capable 런타임에 도달한 첨부가 원본과 같은지. *)
  let original_audio = audio_block () in
  let original_document = document_block () in
  let survived_audio =
    List.exists (fun b -> blocks_equal b original_audio) kept_media
  in
  let survived_document =
    List.exists (fun b -> blocks_equal b original_document) kept_media
  in
  log "S2_RESULT audio_survives=%b document_survives=%b" survived_audio survived_document
;;

(* ------------------------------------------------------------------ *)
(* s4: checkpoint 직렬화 왕복 — failover 후 다음 시도의 근거            *)

let checkpoint_with_messages messages =
  { Checkpoint.version = Checkpoint.checkpoint_version
  ; session_id = "h5-media-checkpoint"
  ; agent_name = "h5-agent"
  ; model = "h5-model"
  ; system_prompt = None
  ; messages
  ; usage = Types.empty_usage
  ; turn_count = 1
  ; created_at = 0.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Types.Off
  ; cache_system_prompt = false
  ; context = Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let media_message () =
  { Types.role = Types.User
  ; content = [ Types.Text "attachments"; audio_block (); document_block () ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let s4_checkpoint_roundtrip () =
  stage "s4: checkpoint to_json/of_json roundtrip keeps media bytes";
  let canonical = [ media_message () ] in
  let checkpoint = checkpoint_with_messages canonical in
  match
    Checkpoint.of_json (Checkpoint.to_json checkpoint)
  with
  | Error error ->
    fail ("checkpoint roundtrip failed: " ^ Agent_core.Error.to_string error)
  | Ok reloaded ->
    let audio_in_reloaded =
      List.exists
        (fun (message : Types.message) ->
           List.exists
             (function
               | Types.Audio _ -> true
               | _ -> false)
             message.content)
        reloaded.messages
    in
    let document_in_reloaded =
      List.exists
        (fun (message : Types.message) ->
           List.exists
             (function
               | Types.Document _ -> true
               | _ -> false)
             message.content)
        reloaded.messages
    in
    let audio_block_of messages =
      List.find_map
        (fun (message : Types.message) ->
           List.find_map
             (function
               | Types.Audio _ as block -> Some block
               | _ -> None)
             message.content)
        messages
    in
    let document_block_of messages =
      List.find_map
        (fun (message : Types.message) ->
           List.find_map
             (function
               | Types.Document _ as block -> Some block
               | _ -> None)
             message.content)
        messages
    in
    let audio_equal =
      match audio_block_of reloaded.messages with
      | Some block -> blocks_equal block (audio_block ())
      | None -> false
    in
    let document_equal =
      match document_block_of reloaded.messages with
      | Some block -> blocks_equal block (document_block ())
      | None -> false
    in
    log "S4 audio_present=%b document_present=%b audio_equal=%b document_equal=%b"
      audio_in_reloaded document_in_reloaded audio_equal document_equal;
    log "S4_RESULT canonical_sha=%s reloaded_sha=%s bytes_equal=%b"
      (sha256_of_block (audio_block ()))
      (Option.fold ~none:"missing" ~some:sha256_of_block (audio_block_of reloaded.messages))
      (String.equal
         (sha256_of_block (audio_block ()))
         (Option.fold ~none:"missing" ~some:sha256_of_block (audio_block_of reloaded.messages)))
;;

(* ------------------------------------------------------------------ *)
(* s5: failover 시나리오 종합 — 실측 기록                              *)

let s5_failover_summary () =
  stage "s5: failover summary (composed from the measured boundaries)";
  (* head(text-only) 실패 → fallback(media-capable) 이 같은 첨부를 받는
     시나리오를 구성 경계들로 재현한다:
     1. head 투영: strip+note (S2에서 실측)
     2. fallback 투영: 원본 유지 (S2 S2_RESULT)
     3. fallback이 받은 block 은 checkpoint 왕복(S4)과 직렬화 왕복(S1)을
        통과한 것과 같은 바이트여야 한다. *)
  let messages = [ media_message () ] in
  let kept_for_head, dropped_for_head =
    Runtime_agent.strip_unsupported_modality_messages (caps ()) messages
  in
  let kept_for_fallback, dropped_for_fallback =
    Runtime_agent.strip_unsupported_modality_messages
      (caps ~image:true ~audio:true ~document:true ~multimodal:true ())
      messages
  in
  let head_note = Runtime_agent.media_degrade_note ~runtime_id:"head.text" dropped_for_head in
  let fallback_note = Runtime_agent.media_degrade_note ~runtime_id:"fallback.media" dropped_for_fallback in
  let fallback_audio =
    List.find_map
      (fun (message : Types.message) ->
         List.find_map
           (function
             | Types.Audio _ as block -> Some block
             | _ -> None)
           message.content)
      kept_for_fallback
  in
  let fallback_audio_bytes =
    match fallback_audio with
    | Some block -> blocks_equal block (audio_block ())
    | None -> false
  in
  log "S5 head_dropped=%s head_note_present=%b fallback_dropped=%d fallback_note_present=%b fallback_audio_byte_equal=%b"
    (String.concat ","
       (List.map (fun (m, n) -> m ^ "=" ^ string_of_int n) dropped_for_head))
    (match head_note with Some _ -> true | None -> false)
    (List.length dropped_for_fallback)
    (match fallback_note with Some _ -> true | None -> false)
    fallback_audio_bytes
;;

(* dune (test) 스탠자는 인자 없이 실행하므로, 인자가 없으면 전체 시나리오를
   돈다 — runtest 기본 alias 에서 exit 2 가 나지 않게 한다. *)
let () =
  let scenario = if Array.length Sys.argv < 2 then "all" else Sys.argv.(1) in
  match scenario with
  | "all" ->
    s1_serialization_roundtrip ();
    s3_fail_closed_sources ();
    s2_projection_drops_and_notes ();
    s4_checkpoint_roundtrip ();
    s5_failover_summary ()
  | other -> fail ("unknown scenario: " ^ other)
