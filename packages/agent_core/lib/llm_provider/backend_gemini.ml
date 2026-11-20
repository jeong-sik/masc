(** Gemini native API request building and response parsing.

    Wire format: contents/parts, systemInstruction, thinkingConfig,
    functionDeclarations.  Ref: ai.google.dev/api/generate-content

    @since 0.72.0 *)

open Types

type request_artifact = string Request_artifact_internal.t

let request_payload = Request_artifact_internal.payload
let request_output_token_receipt = Request_artifact_internal.output_token_receipt

exception Gemini_api_error of string

(* ── Helpers ────────────────────────────────────────── *)

(* The Gemini API has no parallel-function-call disable. [functionCallingConfig]
   supports only [mode] (AUTO/ANY/VALIDATED/NONE) and [allowedFunctionNames] --
   there is no equivalent of OpenAI [parallel_tool_calls:false] or Anthropic
   [tool_choice.disable_parallel_tool_use]. A caller's [disable_parallel_tool_use]
   therefore cannot be honored on the wire and is dropped; we surface that
   asymmetry once per model rather than ignoring it silently. Verified 2026-06-03
   against ai.google.dev/gemini-api/docs/function-calling.
   Stored as an atomic list so the check works with or without an Eio scheduler. *)
let parallel_disable_warned : string list Atomic.t = Atomic.make []

let warn_parallel_disable_unsupported ~model_id =
  let warned = Atomic.get parallel_disable_warned in
  if not (List.mem model_id warned)
  then (
    let rec mark () =
      let old = Atomic.get parallel_disable_warned in
      if List.mem model_id old
      then ()
      else if Atomic.compare_and_set parallel_disable_warned old (model_id :: old)
      then
        Diag.warn
          "backend_gemini"
          "disable_parallel_tool_use requested for model %s but the Gemini API has no \
           parallel-disable option (functionCallingConfig supports only mode and \
           allowedFunctionNames); ignoring."
          model_id
      else mark ()
    in
    mark ())
;;

(* Gemini publishes one thinking wire: [thinkingLevel], a name from the
   model's declared effort vocabulary. *)
let accepted_efforts_for_config (config : Provider_config.t) =
  let caps =
    match Provider_config.capabilities_for_config_model config with
    | Some caps -> caps
    | None ->
      invalid_arg
        (Printf.sprintf
           "Backend_gemini.build_request: model %S has no declared thinking-control \
            contract"
           config.model_id)
  in
  match caps.accepted_reasoning_efforts with
  | Some (_ :: _ as accepted) -> accepted
  | None | Some [] ->
    invalid_arg
      (Printf.sprintf
         "Backend_gemini.build_request: model %S declares no thinkingLevel vocabulary"
         config.model_id)
;;

let thinking_level_of_effort ~accepted effort =
  if List.mem effort accepted
  then Reasoning_effort.to_string effort
  else
    invalid_arg
      (Printf.sprintf
         "Backend_gemini.build_request: reasoning_effort %S is not declared for this \
          Gemini thinkingLevel wire"
         (Reasoning_effort.to_string effort))
;;

let thinking_config_of_config (config : Provider_config.t) =
  match config.enable_thinking, config.reasoning_effort with
  | None, None -> None
  | _ ->
    let accepted = accepted_efforts_for_config config in
    (match config.enable_thinking, config.reasoning_effort with
     | Some false, _ ->
       invalid_arg
         "Backend_gemini.build_request: enable_thinking=false has no exact Gemini \
          thinkingLevel representation"
     | Some true, Some effort ->
       Some
         (`Assoc
             [ "thinkingLevel", `String (thinking_level_of_effort ~accepted effort)
             ; "includeThoughts", `Bool true
             ])
     | Some true, None -> Some (`Assoc [ "includeThoughts", `Bool true ])
     | None, Some effort ->
       Some
         (`Assoc [ "thinkingLevel", `String (thinking_level_of_effort ~accepted effort) ])
     | None, None -> None)
;;

let gemini_role_of_agent_core = function
  | User | System | Tool -> "user"
  | Assistant -> "model"
;;

let gemini_thought_signature_kind = "gemini_thought_signature"
let gemini_part_thought_signature_kind = "gemini_part_thought_signature"

type gemini_part_signature_target =
  | Gemini_text_part
  | Gemini_thought_part
  | Gemini_image_part
  | Gemini_audio_part
  | Gemini_document_part

let gemini_part_signature_target_to_string = function
  | Gemini_text_part -> "text"
  | Gemini_thought_part -> "thought"
  | Gemini_image_part -> "image"
  | Gemini_audio_part -> "audio"
  | Gemini_document_part -> "document"
;;

let gemini_part_signature_target_of_string = function
  | "text" -> Some Gemini_text_part
  | "thought" -> Some Gemini_thought_part
  | "image" -> Some Gemini_image_part
  | "audio" -> Some Gemini_audio_part
  | "document" -> Some Gemini_document_part
  | _ -> None
;;

let string_field_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) when not (Api_common.string_is_blank s) -> Some s
     | Some _ | None -> None)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let gemini_thought_signature_payload ~tool_use_id ~thought_signature =
  Yojson.Safe.to_string
    (`Assoc
        [ "provider", `String "gemini"
        ; "kind", `String gemini_thought_signature_kind
        ; "tool_use_id", `String tool_use_id
        ; "thoughtSignature", `String thought_signature
        ])
;;

let gemini_thought_signature_carrier ~tool_use_id ~thought_signature =
  RedactedThinking (gemini_thought_signature_payload ~tool_use_id ~thought_signature)
;;

let gemini_part_thought_signature_payload ~target ~thought_signature =
  Provider_replay.encode_exact_next_block
    ~payload:
      (`Assoc
          [ "provider", `String "gemini"
          ; "kind", `String gemini_part_thought_signature_kind
          ; "target", `String (gemini_part_signature_target_to_string target)
          ; "thoughtSignature", `String thought_signature
          ])
;;

let gemini_part_thought_signature_carrier ~target ~thought_signature =
  RedactedThinking (gemini_part_thought_signature_payload ~target ~thought_signature)
;;

let exact_string_field_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> Some s
     | Some _ | None -> None)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let thought_signature_of_part = function
  | `Assoc fields ->
    (match List.assoc_opt "thoughtSignature" fields with
     | None | Some `Null -> None
     | Some (`String value) when not (Api_common.string_is_blank value) -> Some value
     | Some (`String _) ->
       raise (Gemini_api_error "Gemini response contains a blank thoughtSignature")
     | Some _ ->
       raise (Gemini_api_error "Gemini response contains a non-string thoughtSignature"))
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let gemini_thought_signature_of_redacted data =
  try
    let json = Yojson.Safe.from_string data in
    match string_field_opt "provider" json, string_field_opt "kind" json with
    | Some "gemini", Some kind when String.equal kind gemini_thought_signature_kind ->
      (match
         ( string_field_opt "tool_use_id" json
         , match exact_string_field_opt "thoughtSignature" json with
           | Some s -> Some s
           | None -> exact_string_field_opt "thought_signature" json )
       with
       | Some tool_use_id, Some thought_signature -> Some (tool_use_id, thought_signature)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;

type gemini_part_signature_decode =
  | Not_gemini_part_signature
  | Decoded_gemini_part_signature of gemini_part_signature_target * string
  | Malformed_gemini_part_signature

let gemini_part_signature_payload_mentions_gemini = function
  | `Assoc fields ->
    List.exists
      (function
        | "provider", `String "gemini" -> true
        | "kind", `String kind -> String.equal kind gemini_part_thought_signature_kind
        | _ -> false)
      fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> false
;;

let decode_gemini_part_thought_signature data =
  match Provider_replay.decode data with
  | Provider_replay.Not_replay -> Not_gemini_part_signature
  | Provider_replay.Malformed_replay _ -> Malformed_gemini_part_signature
  | Provider_replay.Replay
      { retention = Provider_replay.Exact_next_block; payload = json } ->
    if not (gemini_part_signature_payload_mentions_gemini json)
    then Not_gemini_part_signature
    else (
      match
        Provider_replay.exact_object_fields
          ~allowed:[ "provider"; "kind"; "target"; "thoughtSignature" ]
          json
      with
      | Error _ -> Malformed_gemini_part_signature
      | Ok fields ->
        let json = `Assoc fields in
        (match string_field_opt "provider" json, string_field_opt "kind" json with
         | Some "gemini", Some kind
           when String.equal kind gemini_part_thought_signature_kind ->
           (match
              ( Option.bind
                  (string_field_opt "target" json)
                  gemini_part_signature_target_of_string
              , exact_string_field_opt "thoughtSignature" json )
            with
            | Some target, Some thought_signature
              when not (Api_common.string_is_blank thought_signature) ->
              Decoded_gemini_part_signature (target, thought_signature)
            | _ -> Malformed_gemini_part_signature)
         | Some "gemini", _ -> Malformed_gemini_part_signature
         | _, Some kind when String.equal kind gemini_part_thought_signature_kind ->
           Malformed_gemini_part_signature
         | _ -> Not_gemini_part_signature))
;;

let validate_projected_thought_signatures (messages : message list) =
  List.iteri
    (fun message_index (message : message) ->
       List.iteri
         (fun block_index -> function
            | RedactedThinking data ->
              (match gemini_thought_signature_of_redacted data with
               | Some _ -> ()
               | None ->
                 (match decode_gemini_part_thought_signature data with
                  | Decoded_gemini_part_signature _ -> ()
                  | Not_gemini_part_signature | Malformed_gemini_part_signature ->
                    raise
                      (Gemini_api_error
                         (Printf.sprintf
                            "Gemini history contains an invalid thoughtSignature carrier \
                             at history index %d block %d"
                            message_index
                            block_index))))
            | Text _
            | Thinking _
            | ReasoningDetails _
            | ToolUse _
            | ToolResult _
            | Image _
            | Document _
            | Audio _ -> ())
         message.content)
    messages
;;

module String_map = Map.Make (String)

let gemini_tool_signatures_of_blocks blocks =
  List.fold_left
    (fun acc -> function
      | RedactedThinking data ->
        (match gemini_thought_signature_of_redacted data with
         | Some (tool_use_id, signature) -> String_map.add tool_use_id signature acc
         | None -> acc)
      | Text _
      | Thinking _
      | ReasoningDetails _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> acc)
    String_map.empty
    blocks
;;

(* ── Content block -> Gemini part ───────────────────── *)

let inline_data_part ~block ~media_type source =
  let data = Api_common.base64_media_payload ~backend:"gemini" ~block source in
  Some
    (`Assoc
        [ "inlineData", `Assoc [ "mimeType", `String media_type; "data", `String data ] ])
;;

let media_content_block_of_inline_data = function
  | `Assoc fields ->
    let required_non_blank name =
      match List.assoc_opt name fields with
      | Some (`String value) when not (Api_common.string_is_blank value) -> value
      | Some (`String _) ->
        raise
          (Gemini_api_error (Printf.sprintf "Gemini inlineData contains a blank %s" name))
      | Some _ | None ->
        raise
          (Gemini_api_error
             (Printf.sprintf "Gemini inlineData is missing string field %s" name))
    in
    let media_type = required_non_blank "mimeType" in
    let data = required_non_blank "data" in
    let top_level =
      match String.split_on_char '/' media_type with
      | top_level :: subtype_parts
        when (not (Api_common.string_is_blank top_level))
             && subtype_parts <> []
             && List.for_all
                  (fun part -> not (Api_common.string_is_blank part))
                  subtype_parts -> String.lowercase_ascii top_level
      | _ ->
        raise
          (Gemini_api_error
             (Printf.sprintf "Gemini inlineData has invalid MIME type %S" media_type))
    in
    (match top_level with
     | "image" -> Gemini_image_part, Image { media_type; source = Base64 data }
     | "audio" -> Gemini_audio_part, Audio { media_type; source = Base64 data }
     | _ -> Gemini_document_part, Document { media_type; source = Base64 data })
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    raise (Gemini_api_error "Gemini inlineData must be an object")
;;

let blocks_with_part_signature ~target ~block = function
  | Some thought_signature ->
    [ gemini_part_thought_signature_carrier ~target ~thought_signature; block ]
  | None -> [ block ]
;;

(* FunctionResponsePart carries media, while the response object carries text
   and structured tool data. References bind each nested media position to a
   part of this exact correlated response, without manufacturing a User row. *)
let function_response_payload ~supports_function_response_parts ~content ~outcome
      ~json ~content_blocks =
  let rec reserve_json names = function
    | `Assoc fields ->
      let names = match List.assoc_opt "$ref" fields with
        | Some (`String name) -> String_map.add name () names
        | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) -> names in
      List.fold_left (fun names (_, value) -> reserve_json names value) names fields
    | `List values -> List.fold_left reserve_json names values
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> names
  in
  let rec reserve_blocks names blocks = List.fold_left (fun names -> function
    | ToolResult {json; content_blocks; _} ->
      reserve_blocks (reserve_json names (Option.value json ~default:`Null))
        (Option.value content_blocks ~default:[])
    | Image _ | Document _ | Audio _ -> names
    | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _) as block ->
      reserve_json names (Api_common.content_block_to_json block)) names blocks in
  let reserved_names = reserve_blocks
    (reserve_json String_map.empty (Option.value json ~default:`Null))
    (Option.value content_blocks ~default:[]) in
  let parts = ref [] in
  let position = ref 0 in
  let rec fresh_name () =
    let name = Printf.sprintf "attachment-%d" !position in
    incr position;
    if String_map.mem name reserved_names then fresh_name () else name
  in
  let media ~kind ~media_type source =
    if not supports_function_response_parts then
      raise (Gemini_api_error
        "Gemini function response media parts are not declared for this model");
    let display_name = fresh_name () in
    let data = Api_common.base64_media_payload ~backend:"gemini"
      ~block:kind source in
    parts := `Assoc ["inlineData", `Assoc
      ["mimeType", `String media_type; "data", `String data;
       "displayName", `String display_name]] :: !parts;
    `Assoc ["type", `String kind; "media_type", `String media_type;
            "source", `Assoc ["$ref", `String display_name]]
  in
  let rec nested = function
    | Image {media_type; source} -> media ~kind:"image" ~media_type source
    | Audio {media_type; source} -> media ~kind:"audio" ~media_type source
    | Document {media_type; source} -> media ~kind:"document" ~media_type source
    | ToolResult {tool_use_id; content; outcome; json; content_blocks} ->
      `Assoc (["type", `String "tool_result";
               "tool_use_id", `String tool_use_id] @
        response_fields ~content ~outcome ~json ~content_blocks)
    | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _) as block ->
      Api_common.content_block_to_json block
  and response_fields ~content ~outcome ~json ~content_blocks =
    ["result", `String (Utf8_sanitize.sanitize content);
     "is_error", `Bool (tool_result_outcome_is_error outcome)]
    @ (match json with None -> [] | Some data -> ["data", data])
    @ (match content_blocks with
       | None -> []
       | Some blocks -> ["content_blocks", `List (List.map nested blocks)])
  in
  let response = `Assoc (response_fields ~content ~outcome ~json ~content_blocks) in
  response, List.rev !parts
;;

let part_of_content_block ~supports_function_response_parts tool_signatures
      (block, tool_result_name) =
  match block with
  | Text s -> Some (`Assoc [ "text", `String (Utf8_sanitize.sanitize s) ])
  | Thinking { content; _ } ->
    Some
      (`Assoc [ "thought", `Bool true; "text", `String (Utf8_sanitize.sanitize content) ])
  | ReasoningDetails _ -> None
  | Image { media_type; source } ->
    inline_data_part ~block:"image" ~media_type source
  | Audio { media_type; source } ->
    inline_data_part ~block:"audio" ~media_type source
  | Document { media_type; source } ->
    inline_data_part ~block:"document" ~media_type source
  | ToolUse { id; name; input } ->
    let fields =
      [ "functionCall", `Assoc [ "id", `String id; "name", `String name; "args", input ] ]
    in
    let fields =
      match String_map.find_opt id tool_signatures with
      | Some signature -> ("thoughtSignature", `String signature) :: fields
      | None -> fields
    in
    Some (`Assoc fields)
  | ToolResult { tool_use_id; content; outcome; json; content_blocks } ->
    let name =
      match tool_result_name with
      | Some name -> name
      | None ->
        invalid_arg
          (Printf.sprintf
             "Backend_gemini.contents_of_messages: ToolResult identity %S has no \
              resolved tool name"
             tool_use_id)
    in
    let response, parts = function_response_payload ~supports_function_response_parts
      ~content ~outcome ~json ~content_blocks in
    let fields = ["id", `String tool_use_id; "name", `String name;
                  "response", response] in
    let fields = match parts with
      | [] -> fields
      | _ :: _ -> fields @ ["parts", `List parts] in
    Some (`Assoc ["functionResponse", `Assoc fields])
  | RedactedThinking _ -> None
;;

let signature_target_of_content_block = function
  | Text _ -> Some Gemini_text_part
  | Thinking _ -> Some Gemini_thought_part
  | Image _ -> Some Gemini_image_part
  | Audio _ -> Some Gemini_audio_part
  | Document _ -> Some Gemini_document_part
  | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _ -> None
;;

let same_signature_target left right =
  match left with
  | Gemini_text_part ->
    (match right with
     | Gemini_text_part -> true
     | Gemini_thought_part | Gemini_image_part | Gemini_audio_part | Gemini_document_part
       -> false)
  | Gemini_thought_part ->
    (match right with
     | Gemini_thought_part -> true
     | Gemini_text_part | Gemini_image_part | Gemini_audio_part | Gemini_document_part ->
       false)
  | Gemini_image_part ->
    (match right with
     | Gemini_image_part -> true
     | Gemini_text_part | Gemini_thought_part | Gemini_audio_part | Gemini_document_part
       -> false)
  | Gemini_audio_part ->
    (match right with
     | Gemini_audio_part -> true
     | Gemini_text_part | Gemini_thought_part | Gemini_image_part | Gemini_document_part
       -> false)
  | Gemini_document_part ->
    (match right with
     | Gemini_document_part -> true
     | Gemini_text_part | Gemini_thought_part | Gemini_image_part | Gemini_audio_part ->
       false)
;;

let attach_thought_signature thought_signature = function
  | `Assoc fields -> `Assoc (("thoughtSignature", `String thought_signature) :: fields)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    raise
      (Gemini_api_error
         "Gemini part serializer produced a non-object for a thoughtSignature target")
;;

let parts_of_content_blocks ~role ~supports_function_response_parts tool_signatures blocks =
  (* Gemini requires an opaque [thoughtSignature] to be replayed on the exact
     model part that carried it. AGENT_CORE represents that otherwise-unmodeled field
     as a [RedactedThinking] block immediately before its target. Adjacency is
     the structural identity: if a reducer breaks it, fail the request rather
     than attaching the signature to a different part or silently dropping it. *)
  let malformed_carrier expected actual =
    let actual =
      match actual with
      | Some target -> gemini_part_signature_target_to_string target
      | None -> "unsupported"
    in
    raise
      (Gemini_api_error
         (Printf.sprintf
            "Gemini thoughtSignature carrier targets %s but its adjacent content block \
             is %s"
            (gemini_part_signature_target_to_string expected)
            actual))
  in
  let rec loop acc = function
    | (RedactedThinking data, _) :: ((target_block, _) as target) :: rest ->
      (match decode_gemini_part_thought_signature data with
       | Not_gemini_part_signature -> loop acc (target :: rest)
       | Malformed_gemini_part_signature ->
         raise
           (Gemini_api_error
              "Malformed Gemini thoughtSignature carrier in conversation history")
       | Decoded_gemini_part_signature (expected_target, thought_signature) ->
         (match role with
          | Assistant -> ()
          | User | System | Tool ->
            raise
              (Gemini_api_error
                 "Gemini thoughtSignature carrier is only valid on an assistant/model \
                  message"));
         let actual_target = signature_target_of_content_block target_block in
         (match actual_target with
          | Some actual_target when same_signature_target expected_target actual_target ->
            (match part_of_content_block ~supports_function_response_parts tool_signatures target with
             | Some part ->
               loop (attach_thought_signature thought_signature part :: acc) rest
             | None -> malformed_carrier expected_target (Some actual_target))
          | Some _ | None -> malformed_carrier expected_target actual_target))
    | [ (RedactedThinking data, _) ] ->
      (match decode_gemini_part_thought_signature data with
       | Decoded_gemini_part_signature (expected_target, _) ->
         malformed_carrier expected_target None
       | Malformed_gemini_part_signature ->
         raise
           (Gemini_api_error
              "Malformed Gemini thoughtSignature carrier in conversation history")
       | Not_gemini_part_signature -> List.rev acc)
    | (((Text _ | Thinking _ | ReasoningDetails _ | ToolUse _ | ToolResult _
         | Image _ | Document _ | Audio _), _) as block) :: rest ->
      let acc =
        match part_of_content_block ~supports_function_response_parts tool_signatures block with
        | Some part -> part :: acc
        | None -> acc
      in
      loop acc rest
    | [] -> List.rev acc
  in
  loop [] blocks
;;

(* ── Message list -> (contents, systemInstruction option) ── *)

(* For models without native response media, move only images to a labelled
   followup. Keep the result tree, including nested summaries/JSON/outcomes,
   in the correlated response and leave the same position label in that tree. *)
let with_function_response_image_followups messages =
  let project_result root_tool_use_id block =
    let rec project path outcome = function
      | Image _ as image ->
        let label = Text ("Image from tool result " ^ Yojson.Safe.to_string
          (`Assoc ["tool_use_id", `String root_tool_use_id;
                   "content_path", `List (List.map (fun index -> `Int index) (List.rev path));
                   "is_error", `Bool (tool_result_outcome_is_error outcome)])) in
        label, [label; image]
      | ToolResult ({outcome; content_blocks = Some blocks; _} as result) ->
        let blocks, images = List.split (List.mapi
          (fun index block -> project (index :: path) outcome block) blocks) in
        ToolResult {result with content_blocks = Some blocks}, List.concat images
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
        | ToolUse _ | Document _ | Audio _ | ToolResult {content_blocks = None; _}) as block ->
        block, []
    in
    project [] Tool_succeeded block
  in
  let flush pending reversed = match pending with
    | [] -> reversed
    | _ :: _ ->
      { origin = Tool_result_followup; role = User; content = List.rev pending;
        name = None; tool_call_id = None; metadata = [] } :: reversed
  in
  let rec loop reversed pending = function
    | [] -> List.rev (flush pending reversed)
    | ({role = Tool; _} as message) :: rest ->
      let content, pending = List.fold_left (fun (content, pending) block ->
        let block, images = match block with
          | ToolResult {tool_use_id; _} -> project_result tool_use_id block
          | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
            | ToolUse _ | Image _ | Document _ | Audio _) -> block, [] in
        block :: content, List.rev_append images pending) ([], pending) message.content in
      loop ({message with content = List.rev content} :: reversed) pending rest
    | ({role = System | User | Assistant; _} as message) :: rest ->
      loop (message :: flush pending reversed) [] rest
  in
  loop [] [] messages
;;

let contents_of_messages ~supports_function_response_parts (messages : message list) =
  let messages =
    if supports_function_response_parts then messages
    else with_function_response_image_followups messages
  in
  let messages = Api_common.merge_tool_result_followup_user_messages messages in
  let projection =
    match Tool_result_projection.of_messages messages with
    | Ok projection -> projection
    | Error error ->
      invalid_arg
        ("Backend_gemini.contents_of_messages: "
         ^ Tool_result_projection.error_to_string error)
  in
  let system_parts = ref [] in
  let contents = ref [] in
  List.iter
    (fun resolved_message ->
       let msg = Tool_result_projection.original_message resolved_message in
       let resolved_content = Tool_result_projection.content resolved_message in
       let tool_signatures = gemini_tool_signatures_of_blocks msg.content in
       match msg.role with
       | System ->
         let parts =
           parts_of_content_blocks ~role:msg.role ~supports_function_response_parts
             tool_signatures resolved_content
         in
         system_parts := !system_parts @ parts
       | User | Assistant | Tool ->
         let parts =
           parts_of_content_blocks ~role:msg.role ~supports_function_response_parts
             tool_signatures resolved_content
         in
         if parts <> []
         then
           contents
           := `Assoc
                [ "role", `String (gemini_role_of_agent_core msg.role); "parts", `List parts ]
              :: !contents)
    (Tool_result_projection.messages projection);
  let system_instruction =
    match !system_parts with
    | [] -> None
    | parts -> Some (`Assoc [ "parts", `List parts ])
  in
  List.rev !contents, system_instruction
;;

(* ── Tool schema -> Gemini functionDeclarations ─────── *)

let build_function_declaration = function
  | `Assoc fields ->
    let name =
      match List.assoc_opt "name" fields with
      | Some (`String s) -> s
      | _ -> "tool"
    in
    let description =
      match List.assoc_opt "description" fields with
      | Some (`String s) -> s
      | _ -> ""
    in
    let parameters =
      match List.assoc_opt "input_schema" fields with
      | Some schema -> schema
      | None ->
        (match List.assoc_opt "parameters" fields with
         | Some schema -> schema
         | None -> `Assoc [])
    in
    `Assoc
      [ "name", `String name
      ; "description", `String description
      ; "parameters", parameters
      ]
  | other -> other
;;

(* ── Build request body ─────────────────────────────── *)

let capabilities_of_config config =
  match Provider_config.capabilities_for_config_model config with
  | Some caps -> caps
  | None -> Capabilities.gemini_capabilities
;;

(* Older or undeclared models can still receive the existing labelled image
   followup. Document/audio data has no such native function-response carrier
   without this separate declaration. Preserve the original and make that
   omission explicit in both preflight and the serialized result. *)
let project_function_response_media messages =
  let omitted kind media_type =
    Printf.sprintf
      "[%s omitted: this model does not declare media in function responses (media_type %s)]"
      kind media_type
  in
  let rec nested = function
    | Document {media_type; _} ->
      let note = omitted "document" media_type in Text note, [note]
    | Audio {media_type; _} ->
      let note = omitted "audio" media_type in Text note, [note]
    | ToolResult ({content_blocks = Some blocks; _} as result) ->
      let blocks, notes = List.split (List.map nested blocks) in
      let notes = List.concat notes in
      let content = match notes with
        | [] -> result.content
        | _ :: _ -> String.concat "\n" (result.content :: notes) in
      ToolResult {result with content; content_blocks = Some blocks}, notes
    | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
      | ToolUse _ | Image _ | ToolResult {content_blocks = None; _}) as block -> block, []
  in
  List.map (fun (message : 'source Types.message_with) ->
    let content = List.map (function
      | ToolResult _ as block -> fst (nested block)
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
        | ToolUse _ | Image _ | Document _ | Audio _) as block -> block)
      message.content in
    {message with content}) messages
;;

(* Document and audio admission are shared by preflight projection and request
   building. Running audio capability degradation before
   [project_function_response_media] ensures a model without
   [supports_audio_input] reports the audio-input omission instead of the
   secondary function-response-parts omission. The diagnostic [observe] stays
   at the dispatch site. *)
let project_history ?(tools_present = false) config messages =
  let caps = capabilities_of_config config in
  let messages, _documents_degraded =
    Api_common.degrade_document_messages
      ~wire_form:Api_common.Document_inline_data
      ~supports_document_input:caps.supports_document_input
      messages
  in
  let messages, _audio_degraded =
    Api_common.degrade_audio_messages
      ~supports_audio_input:caps.supports_audio_input
      messages
  in
  let messages =
    if caps.supports_function_response_parts then messages
    else project_function_response_media messages
  in
  Reasoning_history_projection.project_for_provider_config
    ~tools_present
    ~assistant_has_payload:(fun content -> content <> [])
    ~reasoning_block_supported:(function
      | Thinking _ | RedactedThinking _ -> true
      | ReasoningDetails _
      | Text _
      | ToolUse _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> false)
    config
    messages
;;

let build_request_artifact
      ?(stream = false)
      ~(config : Provider_config.t)
      ~(messages : message list)
      ?(tools : Yojson.Safe.t list = [])
      ()
  =
  ignore stream;
  (* Gemini streaming is URL-based, not body-based *)
  (match Provider_config.validate_reasoning_effort_request config with
   | Ok () -> ()
   | Error reason -> invalid_arg ("Backend_gemini.build_request: " ^ reason));
  let output_token_receipt =
    Backend_openai_request.output_token_receipt
      ~envelope:
        (Provider_http_codec.output_token_envelope
           Provider_http_codec.gemini_generate_content)
      config
  in
  let projected_messages =
    match project_history ~tools_present:(tools <> []) config messages with
    | Error error ->
      invalid_arg
        ("Backend_gemini.build_request: "
         ^ Reasoning_history_projection.error_to_string error)
    | Ok projection ->
      Reasoning_history_projection.observe ~component:"backend_gemini" ~stream projection;
      validate_projected_thought_signatures projection.messages;
      projection.messages
  in
  (* Images must not reach [contents_of_messages] — and through it
     [with_image_followups] — against a model that does not declare
     [supports_image_input]: the projection would emit an inlineData part
     the endpoint rejects or drops. Degrading to a named placeholder keeps
     the turn live, mirroring the OpenAI-compatible request boundary. *)
  let projected_messages =
    let caps = capabilities_of_config config in
    let projected_messages, _images_degraded =
      Api_common.degrade_image_messages
        ~supports_image_input:caps.supports_image_input
        projected_messages
    in
    (* Documents and audio already passed their capability boundaries in
       [project_history] before [project_function_response_media]. *)
    projected_messages
  in
  let contents, system_instruction =
    contents_of_messages
      ~supports_function_response_parts:(capabilities_of_config config).supports_function_response_parts
      projected_messages
  in
  (* Prepend system_prompt from config if present *)
  let system_instruction =
    match config.system_prompt, system_instruction with
    | Some s, None when not (Api_common.string_is_blank s) ->
      let s = Utf8_sanitize.sanitize s in
      Some (`Assoc [ "parts", `List [ `Assoc [ "text", `String s ] ] ])
    | Some s, Some (`Assoc fields) when not (Api_common.string_is_blank s) ->
      let s = Utf8_sanitize.sanitize s in
      let existing_parts =
        match List.assoc_opt "parts" fields with
        | Some (`List ps) -> ps
        | _ -> []
      in
      let config_part = `Assoc [ "text", `String s ] in
      Some (`Assoc [ "parts", `List (config_part :: existing_parts) ])
    | _, si -> si
  in
  let body = [ "contents", `List contents ] in
  let body =
    match system_instruction with
    | Some si -> ("systemInstruction", si) :: body
    | None -> body
  in
  (* generationConfig *)
  let gen_config = ref [] in
  (* Shared budget policy (caller override clamped to catalog ceiling,
     omitted when both are unknown) — [maxOutputTokens] is optional on
     generateContent, and omission lets Gemini apply the model's own
     limit instead of an invented 16384. *)
  (match Types.output_token_receipt_effective output_token_receipt with
   | Some mt -> gen_config := ("maxOutputTokens", `Int mt) :: !gen_config
   | None -> ());
  let dialect = Reasoning_dialect.for_provider_config config in
  let caps =
    match Provider_config.capabilities_for_config_model config with
    | Some c -> c
    | None -> Capabilities.gemini_capabilities
  in
  (match config.temperature with
   | Some t ->
     gen_config
     := Backend_openai_request.add_sampling_field
          dialect
          config
          Capabilities.Temperature
          (`Float t)
          !gen_config
   | None -> ());
  (match config.top_p with
   | Some p ->
     gen_config
     := Backend_openai_request.add_sampling_field
          ~wire_field:"topP"
          dialect
          config
          Capabilities.Top_p
          (`Float p)
          !gen_config
   | None -> ());
  (match config.top_k with
   | Some k when caps.supports_top_k ->
     gen_config
     := Backend_openai_request.add_sampling_field
          ~wire_field:"topK"
          dialect
          config
          Capabilities.Top_k
          (`Int k)
          !gen_config
   | Some _ ->
     Backend_openai_request.warn_capability_drop ~model_id:config.model_id ~field:"top_k"
   | None -> ());
  (* Seed — Gemini API supports seed in generationConfig *)
  (match caps.supports_seed, config.seed with
   | true, Some seed -> gen_config := ("seed", `Int seed) :: !gen_config
   | false, Some _ ->
     invalid_arg
       (Printf.sprintf
          "Backend_gemini.build_request: model %S does not support seed"
          config.model_id)
   | true, None | false, None -> ());
  (match thinking_config_of_config config with
   | Some thinking_config ->
     gen_config := ("thinkingConfig", thinking_config) :: !gen_config
   | None -> ());
  let text_response_format =
    match config.response_format with
    | Types.JsonSchema schema ->
      Some (`Assoc [ "mimeType", `String "APPLICATION_JSON"
                  ; "schema", Types.json_schema_domain schema ])
    | Types.JsonMode -> Some (`Assoc [ "mimeType", `String "APPLICATION_JSON" ])
    | Types.Off -> None
  in
  (match text_response_format with
   | Some text ->
     gen_config := ("responseFormat", `Assoc [ "text", text ]) :: !gen_config
   | None -> ());
  let body = ("generationConfig", `Assoc !gen_config) :: body in
  (* Tools *)
  let body =
    match tools with
    | [] -> body
    | ts ->
      if config.disable_parallel_tool_use
      then warn_parallel_disable_unsupported ~model_id:config.model_id;
      let func_decls = List.map build_function_declaration ts in
      ("tools", `List [ `Assoc [ "functionDeclarations", `List func_decls ] ]) :: body
  in
  (* Tool config (tool_choice) *)
  let body =
    match config.tool_choice with
    | Some Auto ->
      ("toolConfig", `Assoc [ "functionCallingConfig", `Assoc [ "mode", `String "AUTO" ] ])
      :: body
    | Some Any ->
      ("toolConfig", `Assoc [ "functionCallingConfig", `Assoc [ "mode", `String "ANY" ] ])
      :: body
    | Some None_ ->
      ("toolConfig", `Assoc [ "functionCallingConfig", `Assoc [ "mode", `String "NONE" ] ])
      :: body
    | Some (Tool name) ->
      ( "toolConfig"
      , `Assoc
          [ ( "functionCallingConfig"
            , `Assoc
                [ "mode", `String "ANY"; "allowedFunctionNames", `List [ `String name ] ]
            )
          ] )
      :: body
    | None -> body
  in
  Request_artifact_internal.create
    ~payload:(Yojson.Safe.to_string (`Assoc body))
    ~output_token_receipt
;;

let build_request ?stream ~config ~messages ?tools () =
  build_request_artifact ?stream ~config ~messages ?tools () |> request_payload
;;

(* ── Parse response ─────────────────────────────────── *)

let stop_reason_of_finish_reason ~has_tool_use finish_reason =
  match String.uppercase_ascii finish_reason with
  | "STOP" -> if has_tool_use then StopToolUse else EndTurn
  | "MAX_TOKENS" -> MaxTokens
  | "SAFETY"
  | "RECITATION"
  | "LANGUAGE"
  | "BLOCKLIST"
  | "PROHIBITED_CONTENT"
  | "SPII"
  | "IMAGE_SAFETY"
  | "IMAGE_PROHIBITED_CONTENT"
  | "IMAGE_RECITATION"
  | "ESCALATION" -> Refusal
  | other -> Unknown other
;;

let parse_response json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Null | `Assoc [] ->
    let candidates = json |> member "candidates" in
    let candidate =
      match candidates with
      | `List (c :: _) -> c
      | _ -> json (* fallback for unexpected shapes *)
    in
    let content_obj = candidate |> member "content" in
    let parts =
      match content_obj |> member "parts" with
      | `List ps -> ps
      | _ -> []
    in
    let content =
      List.concat_map
        (fun part ->
           let part_thought_signature = thought_signature_of_part part in
           match part |> member "text" with
           | `String s ->
             let is_thought = Cli_common_json.member_bool "thought" part in
             let target, block =
               if is_thought
               then Gemini_thought_part, Thinking { signature = None; content = s }
               else Gemini_text_part, Text s
             in
             blocks_with_part_signature ~target ~block part_thought_signature
           | _ ->
             (match part |> member "functionCall" with
              | `Assoc _ as fc ->
                let name = fc |> member "name" |> to_string in
                let args = fc |> member "args" in
                let id =
                  match string_field_opt "id" fc with
                  | Some id -> id
                  | None -> Api_common.fresh_tool_use_id ()
                in
                let tool_use = ToolUse { id; name; input = args } in
                (match part_thought_signature with
                 | Some thought_signature ->
                   [ gemini_thought_signature_carrier ~tool_use_id:id ~thought_signature
                   ; tool_use
                   ]
                 | None -> [ tool_use ])
              | _ ->
                (match part |> member "inlineData" with
                 | `Assoc _ as inline_data ->
                   let target, block = media_content_block_of_inline_data inline_data in
                   blocks_with_part_signature ~target ~block part_thought_signature
                 | `Null ->
                   (match part_thought_signature with
                    | Some _ ->
                      raise
                        (Gemini_api_error
                           "Gemini thoughtSignature is attached to an unsupported Part")
                    | None -> [])
                 | _ -> raise (Gemini_api_error "Gemini inlineData must be an object"))))
        parts
    in
    let finish_reason =
      candidate
      |> member "finishReason"
      |> to_string_option
      |> Option.value ~default:"FINISH_REASON_UNSPECIFIED"
    in
    let has_tool_use =
      (* The typed content-block match makes Gemini stop-reason inference
         exhaustive without relying on provider text. *)
      List.exists
        (fun (block : Types.content_block) ->
           match block with
           | ToolUse _ -> true
           | Text _
           | Thinking _
           | ReasoningDetails _
           | RedactedThinking _
           | ToolResult _
           | Image _
           | Document _
           | Audio _ -> false)
        content
    in
    let stop_reason = stop_reason_of_finish_reason ~has_tool_use finish_reason in
    let um = json |> member "usageMetadata" in
    let raw_cache_read =
      if um = `Null
      then None
      else um |> member "cachedContentTokenCount" |> to_int_option
    in
    let usage =
      if um = `Null
      then None
      else
        Some
          { input_tokens = Cli_common_json.member_int "promptTokenCount" um
          ; output_tokens = Cli_common_json.member_int "candidatesTokenCount" um
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = Option.value raw_cache_read ~default:0
          ; cost_usd = None
          }
    in
    let model_str = Cli_common_json.member_str "modelVersion" json in
    { id = ""; model = model_str; unreadable_tool_uses = []; stop_reason; content; usage
    ; telemetry =
        Some
          (Types.with_reported_cache_usage
             ~cache_creation_input_tokens:None
             ~cache_read_input_tokens:raw_cache_read
             (Some (Types.with_reported_model ~model:model_str None))) }
  | err ->
    let msg =
      err
      |> member "message"
      |> to_string_option
      |> Option.value ~default:"Unknown Gemini API error"
    in
    raise (Gemini_api_error msg)
;;
