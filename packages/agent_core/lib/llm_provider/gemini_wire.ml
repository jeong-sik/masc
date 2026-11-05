(* See gemini_wire.mli for module rationale. *)

open Types

type gemini_terminal_reason =
  | Gemini_candidate_finish_reason of string
  | Gemini_prompt_block_reason of string

type gemini_chunk =
  { gem_model : string option
  ; gem_parts : Yojson.Safe.t list
  ; gem_finish_reason : gemini_terminal_reason option
  ; gem_usage : api_usage option
  }

type gemini_unsupported_part =
  | Gemini_executable_code
  | Gemini_code_execution_result
  | Gemini_tool_call
  | Gemini_tool_response
  | Gemini_function_response
  | Gemini_file_data
  | Gemini_audio_transcription
  | Gemini_streaming_function_call_arguments
  | Gemini_streaming_function_call_continuation

type gemini_unsupported_response = Gemini_multiple_candidates of { count : int }

type gemini_sse_parse_result =
  | Gemini_chunk of gemini_chunk
  | Gemini_provider_error of
      { message : string
      ; error_type : string option
      ; provider_status : Types.provider_status option
      ; report : Types.provider_report
      ; raw : string
      }
  | Gemini_unsupported_part of
      { part : gemini_unsupported_part
      ; raw : string
      }
  | Gemini_unsupported_response of
      { response : gemini_unsupported_response
      ; raw : string
      }
  | Gemini_parse_failed of
      { reason : string
      ; raw : string
      }

let gemini_field ~path key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s:missing" path key))
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_object ~path = function
  | `Assoc _ as value -> Ok value
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_list ~path = function
  | `List values -> Ok values
  | value ->
    Error (Printf.sprintf "%s:not_array(got %s)" path (Json_util.json_type_name value))
;;

let gemini_optional_string ~path key json =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_string(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let gemini_required_string ~path key json =
  match gemini_field ~path key json with
  | Ok (`String value) when not (Api_common.string_is_blank value) -> Ok value
  | Ok (`String _) -> Error (Printf.sprintf "%s.%s:blank" path key)
  | Ok value ->
    Error
      (Printf.sprintf
         "%s.%s:not_string(got %s)"
         path
         key
         (Json_util.json_type_name value))
  | Error _ as error -> error
;;

let gemini_optional_int_default_zero ~path key json =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok 0
  | Some (`Int value) -> Ok value
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s:not_integer" path key))
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_integer(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let gemini_part_metadata_object_fields =
  [ "partMetadata"; "mediaResolution"; "videoMetadata" ]
;;

let gemini_part_metadata_fields =
  [ "thought"; "thoughtSignature" ] @ gemini_part_metadata_object_fields
;;

let validate_gemini_part_metadata ~path part =
  let ( let* ) = Result.bind in
  let* () =
    match Json_util.assoc_member_opt "thought" part with
    | None | Some `Null | Some (`Bool _) -> Ok ()
    | Some value ->
      Error
        (Printf.sprintf
           "%s.thought:not_boolean(got %s)"
           path
           (Json_util.json_type_name value))
  in
  let* () =
    match Json_util.assoc_member_opt "thoughtSignature" part with
    | None | Some `Null -> Ok ()
    | Some (`String value) when not (Api_common.string_is_blank value) -> Ok ()
    | Some (`String _) -> Error (Printf.sprintf "%s.thoughtSignature:blank" path)
    | Some value ->
      Error
        (Printf.sprintf
           "%s.thoughtSignature:not_string(got %s)"
           path
           (Json_util.json_type_name value))
  in
  let rec validate_objects = function
    | [] -> Ok ()
    | key :: rest ->
      (match Json_util.assoc_member_opt key part with
       | None | Some `Null | Some (`Assoc _) -> validate_objects rest
       | Some value ->
         Error
           (Printf.sprintf
              "%s.%s:not_object(got %s)"
              path
              key
              (Json_util.json_type_name value)))
  in
  validate_objects gemini_part_metadata_object_fields
;;

let gemini_supported_part_payloads = [ "text"; "functionCall"; "inlineData" ]

let validate_gemini_part ~position part =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "gemini.candidates[0].content.parts[%d]" position in
  let* fields =
    match part with
    | `Assoc fields -> Ok fields
    | value ->
      Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
  in
  let part = `Assoc fields in
  let* () =
    let unsupported_field =
      List.find_opt
        (fun (key, _) ->
           not
             (List.mem key (gemini_supported_part_payloads @ gemini_part_metadata_fields)))
        fields
    in
    match unsupported_field with
    | Some (key, _) -> Error (Printf.sprintf "%s.%s:unsupported_field" path key)
    | None -> Ok ()
  in
  let* () = validate_gemini_part_metadata ~path part in
  let payloads =
    List.filter_map
      (fun key ->
         match Json_util.assoc_member_opt key part with
         | None -> None
         | Some value -> Some (key, value))
      gemini_supported_part_payloads
  in
  match payloads with
  | [] -> Error (path ^ ":missing_supported_payload")
  | [ ("text", `String _) ] -> Ok ()
  | [ ("text", value) ] ->
    Error
      (Printf.sprintf "%s.text:not_string(got %s)" path (Json_util.json_type_name value))
  | [ ("functionCall", (`Assoc function_call_fields as function_call)) ] ->
    let unsupported_field =
      List.find_opt
        (fun (key, _) -> not (List.mem key [ "id"; "name"; "args"; "willContinue" ]))
        function_call_fields
    in
    let* () =
      match unsupported_field with
      | Some (key, _) ->
        Error (Printf.sprintf "%s.functionCall.%s:unsupported_field" path key)
      | None -> Ok ()
    in
    let* _id = gemini_optional_string ~path:(path ^ ".functionCall") "id" function_call in
    let* _ = gemini_required_string ~path:(path ^ ".functionCall") "name" function_call in
    let* () =
      match Json_util.assoc_member_opt "args" function_call with
      | None | Some `Null | Some (`Assoc _) -> Ok ()
      | Some value ->
        Error
          (Printf.sprintf
             "%s.functionCall.args:not_object(got %s)"
             path
             (Json_util.json_type_name value))
    in
    let* () =
      match Json_util.assoc_member_opt "willContinue" function_call with
      | None | Some `Null | Some (`Bool _) -> Ok ()
      | Some value ->
        Error
          (Printf.sprintf
             "%s.functionCall.willContinue:not_boolean(got %s)"
             path
             (Json_util.json_type_name value))
    in
    Ok ()
  | [ ("functionCall", value) ] ->
    Error
      (Printf.sprintf
         "%s.functionCall:not_object(got %s)"
         path
         (Json_util.json_type_name value))
  | [ ("inlineData", `Assoc _) ] -> Ok ()
  | [ ("inlineData", value) ] ->
    Error
      (Printf.sprintf
         "%s.inlineData:not_object(got %s)"
         path
         (Json_util.json_type_name value))
  | [ (key, _) ] -> Error (Printf.sprintf "%s.%s:unsupported_payload" path key)
  | _ :: _ :: _ -> Error (path ^ ":multiple_payloads")
;;

type gemini_payload_failure =
  | Gemini_payload_malformed of string
  | Gemini_payload_unsupported_part of gemini_unsupported_part
  | Gemini_payload_unsupported_response of gemini_unsupported_response

type gemini_unsupported_payload_kind =
  | Gemini_executable_code_payload
  | Gemini_code_execution_result_payload
  | Gemini_tool_call_payload
  | Gemini_tool_response_payload
  | Gemini_function_response_payload
  | Gemini_file_data_payload
  | Gemini_audio_transcription_payload

let gemini_unsupported_payload_kind_wire_name = function
  | Gemini_executable_code_payload -> "executableCode"
  | Gemini_code_execution_result_payload -> "codeExecutionResult"
  | Gemini_tool_call_payload -> "toolCall"
  | Gemini_tool_response_payload -> "toolResponse"
  | Gemini_function_response_payload -> "functionResponse"
  | Gemini_file_data_payload -> "fileData"
  | Gemini_audio_transcription_payload -> "audioTranscription"
;;

let gemini_unsupported_part_of_payload_kind = function
  | Gemini_executable_code_payload -> Gemini_executable_code
  | Gemini_code_execution_result_payload -> Gemini_code_execution_result
  | Gemini_tool_call_payload -> Gemini_tool_call
  | Gemini_tool_response_payload -> Gemini_tool_response
  | Gemini_function_response_payload -> Gemini_function_response
  | Gemini_file_data_payload -> Gemini_file_data
  | Gemini_audio_transcription_payload -> Gemini_audio_transcription
;;

let gemini_unsupported_part_wire_name = function
  | Gemini_executable_code ->
    gemini_unsupported_payload_kind_wire_name Gemini_executable_code_payload
  | Gemini_code_execution_result ->
    gemini_unsupported_payload_kind_wire_name Gemini_code_execution_result_payload
  | Gemini_tool_call -> gemini_unsupported_payload_kind_wire_name Gemini_tool_call_payload
  | Gemini_tool_response ->
    gemini_unsupported_payload_kind_wire_name Gemini_tool_response_payload
  | Gemini_function_response ->
    gemini_unsupported_payload_kind_wire_name Gemini_function_response_payload
  | Gemini_file_data -> gemini_unsupported_payload_kind_wire_name Gemini_file_data_payload
  | Gemini_audio_transcription ->
    gemini_unsupported_payload_kind_wire_name Gemini_audio_transcription_payload
  | Gemini_streaming_function_call_arguments -> "functionCall.partialArgs"
  | Gemini_streaming_function_call_continuation -> "functionCall.willContinue"
;;

let gemini_unsupported_response_wire_name = function
  | Gemini_multiple_candidates _ -> "candidates"
;;

let gemini_unsupported_payload_kinds =
  [ Gemini_executable_code_payload
  ; Gemini_code_execution_result_payload
  ; Gemini_tool_call_payload
  ; Gemini_tool_response_payload
  ; Gemini_function_response_payload
  ; Gemini_file_data_payload
  ; Gemini_audio_transcription_payload
  ]
;;

let gemini_unsupported_part_fields =
  List.map gemini_unsupported_payload_kind_wire_name gemini_unsupported_payload_kinds
  @ gemini_part_metadata_fields
;;

let gemini_validate_allowed_fields ~path ~allowed fields =
  match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
  | Some (key, _) -> Error (Printf.sprintf "%s.%s:unsupported_field" path key)
  | None -> Ok ()
;;

let gemini_object_fields ~path = function
  | `Assoc fields -> Ok fields
  | value ->
    Error (Printf.sprintf "%s:not_object(got %s)" path (Json_util.json_type_name value))
;;

let gemini_optional_object ~path key json =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null | Some (`Assoc _) -> Ok ()
  | Some value ->
    Error
      (Printf.sprintf
         "%s.%s:not_object(got %s)"
         path
         key
         (Json_util.json_type_name value))
;;

let validate_gemini_unsupported_part_envelope ~path fields =
  let ( let* ) = Result.bind in
  let* () =
    gemini_validate_allowed_fields ~path ~allowed:gemini_unsupported_part_fields fields
  in
  validate_gemini_part_metadata ~path (`Assoc fields)
;;

let gemini_unsupported_part_of_json ~position part =
  let path = Printf.sprintf "gemini.candidates[0].content.parts[%d]" position in
  match part with
  | `Assoc fields ->
    let streaming_function_call =
      match List.assoc_opt "functionCall" fields with
      | Some (`Assoc function_call_fields) ->
        if List.mem_assoc "partialArgs" function_call_fields
        then Some Gemini_streaming_function_call_arguments
        else if List.assoc_opt "willContinue" function_call_fields = Some (`Bool true)
        then Some Gemini_streaming_function_call_continuation
        else None
      | Some _ | None -> None
    in
    (match streaming_function_call with
     | Some unsupported_part ->
       Some
         (let ( let* ) = Result.bind in
          let* () =
            gemini_validate_allowed_fields
              ~path
              ~allowed:(gemini_supported_part_payloads @ gemini_part_metadata_fields)
              fields
          in
          let* () = validate_gemini_part_metadata ~path (`Assoc fields) in
          let function_call_path = path ^ ".functionCall" in
          let* function_call_fields =
            match List.assoc_opt "functionCall" fields with
            | Some value -> gemini_object_fields ~path:function_call_path value
            | None -> Error (function_call_path ^ ":missing")
          in
          let* () =
            gemini_validate_allowed_fields
              ~path:function_call_path
              ~allowed:[ "id"; "name"; "args"; "partialArgs"; "willContinue" ]
              function_call_fields
          in
          let function_call = `Assoc function_call_fields in
          let* _id = gemini_optional_string ~path:function_call_path "id" function_call in
          let* _name =
            gemini_optional_string ~path:function_call_path "name" function_call
          in
          let* () =
            gemini_optional_object ~path:function_call_path "args" function_call
          in
          let* () =
            match Json_util.assoc_member_opt "partialArgs" function_call with
            | None | Some `Null | Some (`List _) -> Ok ()
            | Some value ->
              Error
                (Printf.sprintf
                   "%s.partialArgs:not_array(got %s)"
                   function_call_path
                   (Json_util.json_type_name value))
          in
          let* () =
            match Json_util.assoc_member_opt "willContinue" function_call with
            | None | Some `Null | Some (`Bool _) -> Ok ()
            | Some value ->
              Error
                (Printf.sprintf
                   "%s.willContinue:not_boolean(got %s)"
                   function_call_path
                   (Json_util.json_type_name value))
          in
          Ok unsupported_part)
     | None ->
       let payloads =
         List.filter_map
           (fun kind ->
              let key = gemini_unsupported_payload_kind_wire_name kind in
              match List.assoc_opt key fields with
              | Some value -> Some (kind, value)
              | None -> None)
           gemini_unsupported_payload_kinds
       in
       (match payloads with
        | [] -> None
        | _ :: _ :: _ -> Some (Error (path ^ ":multiple_payloads"))
        | [ (Gemini_executable_code_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* code_fields =
               gemini_object_fields ~path:(path ^ ".executableCode") value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:(path ^ ".executableCode")
                 ~allowed:[ "id"; "language"; "code" ]
                 code_fields
             in
             let code = `Assoc code_fields in
             let* _id =
               gemini_optional_string ~path:(path ^ ".executableCode") "id" code
             in
             let* _language =
               gemini_required_string ~path:(path ^ ".executableCode") "language" code
             in
             let* _code =
               gemini_required_string ~path:(path ^ ".executableCode") "code" code
             in
             Ok Gemini_executable_code)
        | [ (Gemini_code_execution_result_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* result_fields =
               gemini_object_fields ~path:(path ^ ".codeExecutionResult") value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:(path ^ ".codeExecutionResult")
                 ~allowed:[ "id"; "outcome"; "output" ]
                 result_fields
             in
             let result = `Assoc result_fields in
             let* _id =
               gemini_optional_string ~path:(path ^ ".codeExecutionResult") "id" result
             in
             let* _outcome =
               gemini_required_string
                 ~path:(path ^ ".codeExecutionResult")
                 "outcome"
                 result
             in
             let* _output =
               gemini_optional_string
                 ~path:(path ^ ".codeExecutionResult")
                 "output"
                 result
             in
             Ok Gemini_code_execution_result)
        | [ (Gemini_tool_call_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let tool_call_path = path ^ ".toolCall" in
             let* tool_call_fields = gemini_object_fields ~path:tool_call_path value in
             let* () =
               gemini_validate_allowed_fields
                 ~path:tool_call_path
                 ~allowed:[ "id"; "toolType"; "args" ]
                 tool_call_fields
             in
             let tool_call = `Assoc tool_call_fields in
             let* _id = gemini_required_string ~path:tool_call_path "id" tool_call in
             let* _tool_type =
               gemini_required_string ~path:tool_call_path "toolType" tool_call
             in
             let* () = gemini_optional_object ~path:tool_call_path "args" tool_call in
             Ok Gemini_tool_call)
        | [ (Gemini_tool_response_payload, value) ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let tool_response_path = path ^ ".toolResponse" in
             let* tool_response_fields =
               gemini_object_fields ~path:tool_response_path value
             in
             let* () =
               gemini_validate_allowed_fields
                 ~path:tool_response_path
                 ~allowed:[ "id"; "toolType"; "response" ]
                 tool_response_fields
             in
             let tool_response = `Assoc tool_response_fields in
             let* _id =
               gemini_required_string ~path:tool_response_path "id" tool_response
             in
             let* _tool_type =
               gemini_required_string ~path:tool_response_path "toolType" tool_response
             in
             let* () =
               gemini_optional_object ~path:tool_response_path "response" tool_response
             in
             Ok Gemini_tool_response)
        | [ ( (( Gemini_function_response_payload
               | Gemini_file_data_payload
               | Gemini_audio_transcription_payload ) as kind)
            , value )
          ] ->
          let ( let* ) = Result.bind in
          Some
            (let* () = validate_gemini_unsupported_part_envelope ~path fields in
             let* _ =
               gemini_object_fields
                 ~path:(path ^ "." ^ gemini_unsupported_payload_kind_wire_name kind)
                 value
             in
             Ok (gemini_unsupported_part_of_payload_kind kind))))
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let parse_gemini_json json : (gemini_chunk, gemini_payload_failure) result =
  let malformed result =
    Result.map_error (fun reason -> Gemini_payload_malformed reason) result
  in
  let gemini_optional_string ~path key json =
    malformed (gemini_optional_string ~path key json)
  in
  let gemini_optional_finish_reason ~path json =
    match gemini_optional_string ~path "finishReason" json with
    | Ok (Some "") -> Ok None
    | (Ok None | Ok (Some _) | Error _) as result -> result
  in
  let gemini_required_string ~path key json =
    malformed (gemini_required_string ~path key json)
  in
  let gemini_field ~path key json = malformed (gemini_field ~path key json) in
  let gemini_list ~path json = malformed (gemini_list ~path json) in
  let gemini_object ~path json = malformed (gemini_object ~path json) in
  let gemini_optional_int_default_zero ~path key json =
    malformed (gemini_optional_int_default_zero ~path key json)
  in
  let ( let* ) = Result.bind in
  let* () =
    match json with
    | `Assoc _ -> Ok ()
    | value ->
      Error
        (Gemini_payload_malformed
           (Printf.sprintf
              "gemini_sse_payload:not_object(got %s)"
              (Json_util.json_type_name value)))
  in
  let* model_version = gemini_optional_string ~path:"gemini" "modelVersion" json in
  let* candidates =
    match Json_util.assoc_member_opt "candidates" json with
    | None | Some `Null -> Ok []
    | Some candidates -> gemini_list ~path:"gemini.candidates" candidates
  in
  let* candidate, gem_finish_reason =
    match candidates with
    | [ candidate ] ->
      let* candidate = gemini_object ~path:"gemini.candidates[0]" candidate in
      let* finish_reason =
        gemini_optional_finish_reason ~path:"gemini.candidates[0]" candidate
      in
      Ok
        ( candidate
        , Option.map (fun reason -> Gemini_candidate_finish_reason reason) finish_reason
        )
    | _ :: _ ->
      Error
        (Gemini_payload_unsupported_response
           (Gemini_multiple_candidates { count = List.length candidates }))
    | [] ->
      let* prompt_feedback = gemini_field ~path:"gemini" "promptFeedback" json in
      let* prompt_feedback =
        gemini_object ~path:"gemini.promptFeedback" prompt_feedback
      in
      let* block_reason =
        gemini_required_string ~path:"gemini.promptFeedback" "blockReason" prompt_feedback
      in
      Ok (`Assoc [], Some (Gemini_prompt_block_reason block_reason))
  in
  let terminal_without_content = Option.is_some gem_finish_reason in
  let* parts =
    match Json_util.assoc_member_opt "content" candidate with
    | (None | Some `Null) when terminal_without_content -> Ok []
    | None -> Error (Gemini_payload_malformed "gemini.candidates[0].content:missing")
    | Some content ->
      let* content = gemini_object ~path:"gemini.candidates[0].content" content in
      (match Json_util.assoc_member_opt "parts" content with
       | (None | Some `Null) when terminal_without_content -> Ok []
       | None ->
         Error (Gemini_payload_malformed "gemini.candidates[0].content.parts:missing")
       | Some parts_value ->
         gemini_list ~path:"gemini.candidates[0].content.parts" parts_value)
  in
  let rec validate_parts position unsupported_part = function
    | [] -> Ok unsupported_part
    | part :: rest ->
      (match gemini_unsupported_part_of_json ~position part with
       | Some (Ok part) ->
         let unsupported_part =
           match unsupported_part with
           | Some _ -> unsupported_part
           | None -> Some part
         in
         validate_parts (position + 1) unsupported_part rest
       | Some (Error reason) -> Error (Gemini_payload_malformed reason)
       | None ->
         (match validate_gemini_part ~position part with
          | Error reason -> Error (Gemini_payload_malformed reason)
          | Ok () -> validate_parts (position + 1) unsupported_part rest))
  in
  let* unsupported_part = validate_parts 0 None parts in
  let* () =
    match unsupported_part with
    | None -> Ok ()
    | Some part -> Error (Gemini_payload_unsupported_part part)
  in
  let* gem_usage =
    match Json_util.assoc_member_opt "usageMetadata" json with
    | None | Some `Null -> Ok None
    | Some (`Assoc _ as usage) ->
      let* input_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "promptTokenCount"
          usage
      in
      let* output_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "candidatesTokenCount"
          usage
      in
      let* cache_read_input_tokens =
        gemini_optional_int_default_zero
          ~path:"gemini.usageMetadata"
          "cachedContentTokenCount"
          usage
      in
      Ok
        (Some
           { input_tokens
           ; output_tokens
           ; cache_creation_input_tokens = 0
           ; cache_read_input_tokens
           ; cost_usd = None
           })
    | Some value ->
      Error
        (Gemini_payload_malformed
           (Printf.sprintf
              "gemini.usageMetadata:not_object(got %s)"
              (Json_util.json_type_name value)))
  in
  Ok { gem_model = model_version; gem_parts = parts; gem_finish_reason; gem_usage }
;;

let gemini_provider_error_of_json ~raw json =
  Option.map
    (fun (envelope : Openai_error_envelope.t) ->
      Gemini_provider_error
        { message = envelope.message
        ; error_type = envelope.error_type
        ; provider_status = envelope.provider_status
        ; report = envelope.report
        ; raw
        })
    (Option.bind
       (Json_util.assoc_member_opt "error" json)
       Openai_error_envelope.of_error_value)
;;

let parse_gemini_sse_chunk data_str : gemini_sse_parse_result =
  match Yojson.Safe.from_string data_str with
  | exception Yojson.Json_error message ->
    Gemini_parse_failed { raw = data_str; reason = "json_error: " ^ message }
  | exception Invalid_argument message ->
    Gemini_parse_failed { raw = data_str; reason = "json_invalid_argument: " ^ message }
  | json ->
    (match gemini_provider_error_of_json ~raw:data_str json with
     | Some provider_error -> provider_error
     | None ->
       (match parse_gemini_json json with
        | Ok chunk -> Gemini_chunk chunk
        | Error (Gemini_payload_malformed reason) ->
          Gemini_parse_failed { raw = data_str; reason }
        | Error (Gemini_payload_unsupported_part part) ->
          Gemini_unsupported_part { raw = data_str; part }
        | Error (Gemini_payload_unsupported_response response) ->
          Gemini_unsupported_response { raw = data_str; response }))
;;
