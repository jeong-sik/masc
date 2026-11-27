(** Standalone image generation over typed provider image-API dialects. *)

open Result.Syntax

type request =
  { prompt : string
  ; aspect_ratio : string option
  ; size : string option
  ; quality : string option
  ; count : int option
  ; output_format : string option
  ; negative_prompt : string option
  }
[@@deriving show, eq]

let make_request
      ?aspect_ratio
      ?size
      ?quality
      ?count
      ?output_format
      ?negative_prompt
      prompt
  =
  { prompt
  ; aspect_ratio
  ; size
  ; quality
  ; count
  ; output_format
  ; negative_prompt
  }
;;

let max_response_bytes = Api_common.max_image_response_body

type generated_image =
  { mime_type : string option
  ; data_bytes : string option
  ; remote_url : string option
  ; revised_prompt : string option
  }
[@@deriving show, eq]

type generation_result =
  { images : generated_image list
  ; ignored_options : string list
  }
[@@deriving show, eq]

let non_blank_opt = function
  | Some s when not (Api_common.string_is_blank s) -> Some (String.trim s)
  | Some _ | None -> None
;;

let unsupported_options ~(dialect : Capabilities.images_api_dialect) (req : request) =
  let has_str opt = Option.is_some (non_blank_opt opt) in
  (* Single-image endpoints inherently satisfy count=1 without loss; >1 cannot be honored. *)
  let has_multi_count =
    match req.count with
    | Some n when n > 1 -> true
    | Some _ | None -> false
  in
  let add cond name acc = if cond then name :: acc else acc in
  let rev =
    match dialect with
    | Capabilities.Openai_images_v1 ->
      []
      |> add (has_str req.aspect_ratio) "aspect_ratio"
      |> add (has_str req.negative_prompt) "negative_prompt"
    | Capabilities.Zai_images_v4 ->
      []
      |> add (has_str req.aspect_ratio) "aspect_ratio"
      |> add has_multi_count "count"
      |> add (has_str req.output_format) "output_format"
      |> add (has_str req.negative_prompt) "negative_prompt"
    | Capabilities.Gemini_imagen_predict ->
      [] |> add (has_str req.quality) "quality"
  in
  List.rev rev
;;

let unsupported_options_for_contract
      ~(contract : Capabilities.image_output_contract)
      (req : request)
  =
  match contract with
  | Capabilities.Endpoint_images_api dialect -> unsupported_options ~dialect req
  | Capabilities.In_turn_gemini_modalities
  | Capabilities.In_turn_openai_responses_tool
  | Capabilities.In_turn_openai_chat_modalities
  | Capabilities.In_turn_codex_item
  | Capabilities.In_turn_acp_chunk
  | Capabilities.No_image_output ->
    let opts : Provider_config.image_generation_options =
      { aspect_ratio = req.aspect_ratio
      ; size = req.size
      ; quality = req.quality
      ; count = req.count
      }
    in
    let base = Provider_config.unsupported_image_generation_options ~contract opts in
    let extra =
      (match non_blank_opt req.output_format with
       | Some _ -> [ "output_format" ]
       | None -> [])
      @
      match non_blank_opt req.negative_prompt with
      | Some _ -> [ "negative_prompt" ]
      | None -> []
    in
    base @ extra
;;

let strip_trailing_slash s =
  let rec loop len =
    if len > 0 && Char.equal s.[len - 1] '/' then loop (len - 1) else len
  in
  String.sub s 0 (loop (String.length s))
;;

let ends_with_ci ~suffix s =
  String.ends_with ~suffix:(String.lowercase_ascii suffix) (String.lowercase_ascii s)
;;

let default_images_path ~(dialect : Capabilities.images_api_dialect) ~base =
  match dialect with
  | Capabilities.Openai_images_v1 ->
    if ends_with_ci ~suffix:"/v1" base
    then "/images/generations"
    else "/v1/images/generations"
  | Capabilities.Zai_images_v4 ->
    if ends_with_ci ~suffix:"/api/paas/v4" base || ends_with_ci ~suffix:"/v4" base
    then "/images/generations"
    else "/api/paas/v4/images/generations"
  | Capabilities.Gemini_imagen_predict -> "/images/generations"
;;

let request_url ~(dialect : Capabilities.images_api_dialect) ~(config : Provider_config.t) =
  match dialect with
  | Capabilities.Openai_images_v1 | Capabilities.Zai_images_v4 ->
    let base = strip_trailing_slash (String.trim config.base_url) in
    let raw_path = String.trim config.request_path in
    let path =
      if raw_path = ""
      then default_images_path ~dialect ~base
      else if Char.equal raw_path.[0] '/'
      then raw_path
      else "/" ^ raw_path
    in
    base ^ path
  | Capabilities.Gemini_imagen_predict -> Complete_sampling.gemini_predict_url ~config
;;

let dialect_of_config (config : Provider_config.t) =
  let caps, _source = Provider_config.resolve_request_capabilities config in
  match caps.Capabilities.image_output with
  | Capabilities.Endpoint_images_api dialect -> Ok dialect
  | Capabilities.No_image_output ->
    Error
      (Printf.sprintf
         "model %S does not declare an image_output contract"
         config.model_id)
  | ( Capabilities.In_turn_gemini_modalities
    | Capabilities.In_turn_openai_responses_tool
    | Capabilities.In_turn_openai_chat_modalities
    | Capabilities.In_turn_codex_item
    | Capabilities.In_turn_acp_chunk ) as contract ->
    Error
      (Printf.sprintf
         "model %S uses in-turn image output (%s), not a standalone images API endpoint"
         config.model_id
         (Capabilities.image_output_contract_to_string contract))
;;

let mime_type_of_format_hint = Api_common.image_mime_of_format_opt

let decode_base64_payload raw =
  let buf = Buffer.create (String.length raw) in
  String.iter
    (function
      | ' ' | '\t' | '\r' | '\n' -> ()
      | c -> Buffer.add_char buf c)
    raw;
  let compact = Buffer.contents buf in
  if compact = ""
  then Error "empty base64 image payload"
  else (
    match Base64.decode compact with
    | Ok decoded -> Ok decoded
    | Error (`Msg msg) -> Error ("invalid base64 image payload: " ^ msg))
;;

let validate_request ~(dialect : Capabilities.images_api_dialect) (req : request) =
  let prompt = String.trim req.prompt in
  if prompt = ""
  then Error "image generation prompt must not be blank"
  else (
    let* () =
      match req.count with
      | Some n when n <= 0 ->
        Error (Printf.sprintf "image generation count must be positive, got %d" n)
      | Some _ | None -> Ok ()
    in
    let* () =
      match non_blank_opt req.output_format with
      | None -> Ok ()
      | Some fmt ->
        (match mime_type_of_format_hint fmt with
         | Some _ -> Ok ()
         | None ->
           Error
             (Printf.sprintf
                "unsupported image output_format %S (expected png, jpeg, webp, or gif)"
                fmt))
    in
    let* () =
      match dialect, non_blank_opt req.negative_prompt with
      | Capabilities.Gemini_imagen_predict, _ -> Ok ()
      | (Capabilities.Openai_images_v1 | Capabilities.Zai_images_v4), None -> Ok ()
      | ((Capabilities.Openai_images_v1 | Capabilities.Zai_images_v4) as d), Some _ ->
        Error
          (Printf.sprintf
             "%s does not support negative_prompt"
             (Capabilities.images_api_dialect_to_string d))
    in
    Ok prompt)
;;

let build_request_body
      ~(dialect : Capabilities.images_api_dialect)
      ~(config : Provider_config.t)
      (req : request)
  =
  let* prompt = validate_request ~dialect req in
  if Api_common.string_is_blank config.model_id
  then Error "image generation model_id must not be blank"
  else (
    let json =
      match dialect with
      | Capabilities.Openai_images_v1 ->
        let fields =
          [ "model", `String config.model_id; "prompt", `String prompt ]
          @ (match req.count with Some n -> [ "n", `Int n ] | None -> [])
          @ (match non_blank_opt req.size with Some s -> [ "size", `String s ] | None -> [])
          @ (match non_blank_opt req.quality with Some q -> [ "quality", `String q ] | None -> [])
          @ (match non_blank_opt req.output_format with
             | Some f -> [ "output_format", `String (String.lowercase_ascii f) ]
             | None -> [])
        in
        `Assoc fields
      | Capabilities.Zai_images_v4 ->
        let fields =
          [ "model", `String config.model_id; "prompt", `String prompt ]
          @ (match non_blank_opt req.size with Some s -> [ "size", `String s ] | None -> [])
          @ (match non_blank_opt req.quality with Some q -> [ "quality", `String q ] | None -> [])
        in
        `Assoc fields
      | Capabilities.Gemini_imagen_predict ->
        let parameters =
          (match req.count with Some n -> [ "sampleCount", `Int n ] | None -> [])
          @ (match non_blank_opt req.aspect_ratio with
             | Some ar -> [ "aspectRatio", `String ar ]
             | None -> [])
          @ (match non_blank_opt req.size with
             | Some sz -> [ "imageSize", `String sz ]
             | None -> [])
          @ (match non_blank_opt req.negative_prompt with
             | Some np -> [ "negativePrompt", `String np ]
             | None -> [])
          @ (match Option.bind (non_blank_opt req.output_format) mime_type_of_format_hint with
             | Some mime ->
               [ "outputOptions", `Assoc [ "mimeType", `String mime ] ]
             | None -> [])
        in
        let base = [ "instances", `List [ `Assoc [ "prompt", `String prompt ] ] ] in
        let fields =
          match parameters with
          | [] -> base
          | params -> base @ [ "parameters", `Assoc params ]
        in
        `Assoc fields
    in
    Ok (Yojson.Safe.to_string json))
;;

let member_string_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) when not (Api_common.string_is_blank s) -> Some (String.trim s)
     | Some _ | None -> None)
  | _ -> None
;;

let check_error_envelope json =
  match Json_util.assoc_member_opt "error" json with
  | None | Some `Null -> Ok ()
  | Some (`String msg) when not (Api_common.string_is_blank msg) ->
    Error ("provider error: " ^ String.trim msg)
  | Some (`Assoc fields) ->
    let msg =
      match List.assoc_opt "message" fields with
      | Some (`String m) when not (Api_common.string_is_blank m) -> String.trim m
      | _ -> "provider returned error envelope"
    in
    Error ("provider error: " ^ msg)
  | Some _ -> Error "provider returned error envelope"
;;

let parse_openai_or_zai_data ~dialect_label json =
  let* () = check_error_envelope json in
  let top_format =
    Option.bind (member_string_opt "output_format" json) mime_type_of_format_hint
  in
  match Json_util.assoc_member_opt "data" json with
  | Some (`List items) ->
    let rec loop index acc = function
      | [] ->
        (match List.rev acc with
         | [] -> Error (dialect_label ^ " response contained no images")
         | images -> Ok images)
      | item :: rest ->
        let item_format =
          Option.bind (member_string_opt "output_format" item) mime_type_of_format_hint
        in
        let item_mime_field =
          Option.bind (member_string_opt "mime_type" item) mime_type_of_format_hint
        in
        let revised_prompt = member_string_opt "revised_prompt" item in
        let remote_url = member_string_opt "url" item in
        let* data_bytes =
          match member_string_opt "b64_json" item with
          | None -> Ok None
          | Some b64 ->
            Result.map Option.some (decode_base64_payload b64)
            |> Result.map_error (fun e ->
              Printf.sprintf "%s data[%d]: %s" dialect_label index e)
        in
        if Option.is_none data_bytes && Option.is_none remote_url
        then
          Error
            (Printf.sprintf
               "%s data[%d] missing both b64_json and url"
               dialect_label
               index)
        else (
          (* Record [Some m] only when the provider explicitly declared the
             MIME/format; leave [None] when undeclared so downstream storage
             (Attachment_store) can sniff magic bytes without false mismatch
             errors. *)
          let mime_type =
            match item_mime_field with
            | Some _ as m -> m
            | None ->
              (match item_format with
               | Some _ as m -> m
               | None -> top_format)
          in
          let image = { mime_type; data_bytes; remote_url; revised_prompt } in
          loop (index + 1) (image :: acc) rest)
    in
    loop 0 [] items
  | Some _ -> Error (dialect_label ^ " response field \"data\" must be an array")
  | None -> Error (dialect_label ^ " response missing required \"data\" array")
;;

let parse_gemini_imagen_predictions json =
  let* () = check_error_envelope json in
  match Json_util.assoc_member_opt "predictions" json with
  | Some (`List items) ->
    let rec loop index acc = function
      | [] ->
        (match List.rev acc with
         | [] -> Error "gemini_imagen_predict response contained no predictions"
         | images -> Ok images)
      | item :: rest ->
        let* b64 =
          match member_string_opt "bytesBase64Encoded" item with
          | Some s -> Ok s
          | None ->
            Error
              (Printf.sprintf
                 "gemini_imagen_predict predictions[%d] missing bytesBase64Encoded"
                 index)
        in
        let* bytes =
          decode_base64_payload b64
          |> Result.map_error (fun e ->
            Printf.sprintf "gemini_imagen_predict predictions[%d]: %s" index e)
        in
        let mime_type =
          match member_string_opt "mimeType" item with
          | Some m ->
            (match mime_type_of_format_hint m with
             | Some canonical -> Some canonical
             | None -> Some m)
          | None -> None
        in
        let revised_prompt = member_string_opt "prompt" item in
        let image =
          { mime_type; data_bytes = Some bytes; remote_url = None; revised_prompt }
        in
        loop (index + 1) (image :: acc) rest
    in
    loop 0 [] items
  | Some _ -> Error "gemini_imagen_predict response field \"predictions\" must be an array"
  | None -> Error "gemini_imagen_predict response missing required \"predictions\" array"
;;

let parse_response ~(dialect : Capabilities.images_api_dialect) (body : string) =
  match Json_util.from_string_bounded body with
  | Error reason -> Error ("image_gen JSON parse error: " ^ reason)
  | Ok json ->
    (match dialect with
     | Capabilities.Openai_images_v1 ->
       parse_openai_or_zai_data ~dialect_label:"openai_images_v1" json
     | Capabilities.Zai_images_v4 ->
       parse_openai_or_zai_data ~dialect_label:"zai_images_v4" json
     | Capabilities.Gemini_imagen_predict -> parse_gemini_imagen_predictions json)
;;

let generate
      ?cache
      ?timeout_s
      ?(max_response_bytes = max_response_bytes)
      ~sw
      ~net
      ~clock
      ~(config : Provider_config.t)
      ~(dialect : Capabilities.images_api_dialect)
      (req : request)
  =
  match build_request_body ~dialect ~config req with
  | Error reason -> Error (Http_client.AcceptRejected { reason })
  | Ok body ->
    let ignored_options = unsupported_options ~dialect req in
    let url = request_url ~dialect ~config in
    let effective_headers = Provider_config.effective_request_headers config in
    let parser_name = "image_gen:" ^ Capabilities.images_api_dialect_to_string dialect in
    let rec dispatch ~allow_auth_retry =
      match Provider_config.resolve_auth_headers config with
      | Error reason -> Error (Http_client.AcceptRejected { reason })
      | Ok auth_headers ->
        let headers = effective_headers @ auth_headers in
        (match
           Http_client.post_sync
             ?cache
             ~clock
             ?timeout_s
             ~max_response_bytes
             ~sw
             ~net
             ~url
             ~headers
             ~body
             ()
         with
         | Error _ as err -> err
         | Ok resp when resp.status = 401 && allow_auth_retry ->
           if Provider_config.invalidate_credential config
           then dispatch ~allow_auth_retry:false
           else
             Error
               (Http_client.HttpError
                  { code = resp.status
                  ; body = Http_client.Received resp.body
                  ; retry_after_header = resp.retry_after_header
                  })
         | Ok resp when Http_client.is_success_status resp.status ->
           (match parse_response ~dialect resp.body with
            | Ok images -> Ok { images; ignored_options }
            | Error message ->
              Error
                (Http_client.ProviderFailure
                   { kind = Provider_parse_error { parser = Some parser_name }
                   ; message
                   }))
         | Ok resp ->
           Error
             (Http_client.HttpError
                { code = resp.status
                ; body = Http_client.Received resp.body
                ; retry_after_header = resp.retry_after_header
                }))
    in
    dispatch ~allow_auth_retry:(Provider_config.can_invalidate_credential config)
;;
