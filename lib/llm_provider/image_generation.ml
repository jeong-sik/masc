type source =
  | Remote_url of string
  | Inline_base64 of
      { media_type : string option
      ; data : string
      }

type image = { source : source }

type usage = Gemini_interactions.usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; total_tokens : int option
  ; cached_tokens : int option
  ; thought_tokens : int option
  ; tool_use_tokens : int option
  }

type filter_role =
  | User
  | Assistant
  | History
  | Other of string

type content_filter =
  { role : filter_role option
  ; level : int
  }

type response =
  { created_at : int option
  ; created_at_rfc3339 : string option
  ; provider_response_id : string option
  ; images : image list
  ; usage : usage option
  ; content_filter : content_filter list
  }

type protocol =
  | Openai_image
  | Zai_image
  | Gemini_interaction

let reject reason = Error (Http_client.AcceptRejected { reason })

let parse_failure message =
  Error
    (Http_client.ProviderFailure
       { kind = Http_client.Provider_parse_error { parser = Some "image_generation" }
       ; message
       })
;;

let protocol_of_config (config : Provider_config.t) =
  match config.kind with
  | Provider_config.Glm -> Ok Zai_image
  | Provider_config.OpenAI_compat -> Ok Openai_image
  | Provider_config.Gemini -> Ok Gemini_interaction
  | Anthropic | Kimi | Ollama | DashScope ->
    reject
      (Printf.sprintf
         "image generation has no wire implementation for provider kind %s"
         (Provider_config.string_of_provider_kind config.kind))
;;

let validate_declared_task (config : Provider_config.t) =
  match Provider_config.capabilities_for_config_model config with
  | Some { Capabilities.task = Some Capabilities.Image_generation; _ } -> Ok ()
  | Some { task = Some task; _ } ->
    reject
      (Printf.sprintf
         "model %S declares task %S, not image_generation"
         config.model_id
         (Capability_vocab.task_to_string task))
  | Some { task = None; _ } ->
    reject (Printf.sprintf "model %S does not declare an inference task" config.model_id)
  | None ->
    reject
      (Printf.sprintf
         "model %S has no exact catalog capability declaration"
         config.model_id)
;;

let validate_request config prompt =
  if String.trim prompt = ""
  then reject "image generation prompt must not be empty"
  else if String.trim config.Provider_config.model_id = ""
  then reject "image generation model_id must not be empty"
  else (
    match validate_declared_task config with
    | Error _ as error -> error
    | Ok () -> protocol_of_config config)
;;

let request_body ~protocol ~(config : Provider_config.t) ~prompt =
  match protocol with
  | Gemini_interaction ->
    `Assoc
      [ "model", `String config.model_id
      ; "input", `String prompt
      ; "store", `Bool false
      ; ( "response_format"
        , `Assoc [ "type", `String "image"; "mime_type", `String "image/png" ] )
      ]
    |> Yojson.Safe.to_string
  | Zai_image ->
    `Assoc [ "model", `String config.model_id; "prompt", `String prompt ]
    |> Yojson.Safe.to_string
  | Openai_image ->
    `Assoc
      [ "model", `String config.model_id
      ; "prompt", `String prompt
      ; "output_format", `String "png"
      ]
    |> Yojson.Safe.to_string
;;

(* Closed mapping of the OpenAI-style response [output_format] field; an
   absent or unrecognized value yields no media type rather than a guess. *)
let media_type_of_output_format json =
  match Yojson.Safe.Util.member "output_format" json with
  | `String "png" -> Some "image/png"
  | `String "jpeg" -> Some "image/jpeg"
  | `String "webp" -> Some "image/webp"
  | _ -> None
;;

let source_of_json ~media_type json =
  let open Yojson.Safe.Util in
  match member "url" json, member "b64_json" json with
  | `String url, `Null when String.trim url <> "" -> Ok (Remote_url url)
  | `Null, `String data when String.trim data <> "" ->
    Ok (Inline_base64 { media_type; data })
  | `String _, `String _ -> parse_failure "image item contains both url and b64_json"
  | _ -> parse_failure "image item must contain exactly one non-empty url or b64_json"
;;

let images_of_json json =
  let media_type = media_type_of_output_format json in
  match Yojson.Safe.Util.member "data" json with
  | `List [] -> parse_failure "image response data is empty"
  | `List items ->
    List.fold_left
      (fun acc item ->
         match acc, source_of_json ~media_type item with
         | Ok images, Ok source -> Ok ({ source } :: images)
         | (Error _ as error), _ | _, (Error _ as error) -> error)
      (Ok [])
      items
    |> Result.map List.rev
  | _ -> parse_failure "image response data must be a non-empty list"
;;

let int_field name json =
  match Yojson.Safe.Util.member name json with
  | `Int value -> Ok value
  | _ -> parse_failure (Printf.sprintf "image response usage.%s must be an integer" name)
;;

let optional_int_field name json =
  match Yojson.Safe.Util.member name json with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | _ -> parse_failure (Printf.sprintf "image response usage.%s must be an integer" name)
;;

let usage_of_json json =
  match Yojson.Safe.Util.member "usage" json with
  | `Null -> Ok None
  | `Assoc _ as usage_json ->
    (match int_field "input_tokens" usage_json with
     | Error _ as error -> error
     | Ok input_tokens ->
       (match int_field "output_tokens" usage_json with
        | Error _ as error -> error
        | Ok output_tokens ->
          (match int_field "total_tokens" usage_json with
           | Error _ as error -> error
           | Ok total_tokens ->
             Ok
               (Some
                  { input_tokens = Some input_tokens
                  ; output_tokens = Some output_tokens
                  ; total_tokens = Some total_tokens
                  ; cached_tokens = None
                  ; thought_tokens = None
                  ; tool_use_tokens = None
                  }))))
  | _ -> parse_failure "image response usage must be an object"
;;

let created_at_of_json json =
  match Yojson.Safe.Util.member "created" json with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | _ -> parse_failure "image response created must be an integer"
;;

let filter_role_of_string = function
  | "user" -> User
  | "assistant" -> Assistant
  | "history" -> History
  | other -> Other other
;;

(* Z.AI content_filter severity levels are declared as the closed range 0-3. *)
let content_filter_level_is_declared level = level >= 0 && level <= 3

let content_filter_item json =
  match Yojson.Safe.Util.member "role" json, Yojson.Safe.Util.member "level" json with
  | `String role, `Int level
    when String.trim role <> "" && content_filter_level_is_declared level ->
    Ok { role = Some (filter_role_of_string role); level }
  | `Null, `Int level when content_filter_level_is_declared level ->
    Ok { role = None; level }
  | _ ->
    parse_failure
      "image response content_filter item requires level in [0,3] and an optional role"
;;

let content_filter_of_json json =
  match Yojson.Safe.Util.member "content_filter" json with
  | `Null -> Ok []
  | `List items ->
    List.fold_left
      (fun acc item ->
         match acc, content_filter_item item with
         | Ok observations, Ok observation -> Ok (observation :: observations)
         | (Error _ as error), _ | _, (Error _ as error) -> error)
      (Ok [])
      items
    |> Result.map List.rev
  | _ -> parse_failure "image response content_filter must be a list"
;;

let parse_openai_response body =
  let decode json =
    match created_at_of_json json with
    | Error _ as error -> error
    | Ok created_at ->
      (match images_of_json json with
       | Error _ as error -> error
       | Ok images ->
         (match usage_of_json json with
          | Error _ as error -> error
          | Ok usage ->
            (match content_filter_of_json json with
             | Error _ as error -> error
             | Ok content_filter ->
               Ok
                 { created_at
                 ; created_at_rfc3339 = None
                 ; provider_response_id = None
                 ; images
                 ; usage
                 ; content_filter
                 })))
  in
  match Json_util.decode_json_with decode body with
  | Ok result -> result
  | Error message -> parse_failure ("invalid image response JSON: " ^ message)
;;

let gemini_source_of_json json =
  let open Yojson.Safe.Util in
  match member "data" json, member "uri" json, member "mime_type" json with
  | `String data, `Null, `String media_type
    when String.trim data <> "" && String.trim media_type <> "" ->
    Ok (Inline_base64 { media_type = Some media_type; data })
  | `Null, `String uri, _ when String.trim uri <> "" -> Ok (Remote_url uri)
  | `String _, `String _, _ -> parse_failure "Gemini image contains both data and uri"
  | _ -> parse_failure "Gemini image requires exactly one data+mime_type or uri source"
;;

let gemini_parser = "image_generation"

let gemini_images_of_json json =
  let items =
    Gemini_interactions.model_output_items
      ~parser:gemini_parser
      ~content_type:"image"
      ~item_of_json:(fun content ->
        Result.map (fun source -> { source }) (gemini_source_of_json content))
      json
  in
  Result.bind items (function
    | [] -> parse_failure "Gemini interaction returned no image"
    | images -> Ok images)
;;

let parse_gemini_response body =
  Result.map
    (fun { Gemini_interactions.provider_response_id; created_at_rfc3339; payload; usage } ->
       { created_at = None
       ; created_at_rfc3339
       ; provider_response_id = Some provider_response_id
       ; images = payload
       ; usage
       ; content_filter = []
       })
    (Gemini_interactions.decode_envelope
       ~parser:gemini_parser
       ~payload_of_json:gemini_images_of_json
       body)
;;

let parse_response ~protocol body =
  match protocol with
  | Openai_image | Zai_image -> parse_openai_response body
  | Gemini_interaction -> parse_gemini_response body
;;

let generate
      ~sw
      ~net
      ?clock
      ?timeout_s
      ?connection_cache
      ~(config : Provider_config.t)
      ~prompt
      ()
  =
  match validate_request config prompt with
  | Error _ as error -> error
  | Ok protocol ->
    let url = config.base_url ^ config.request_path in
    let headers = config.headers @ Provider_config.auth_headers_for_config config in
    let body = request_body ~protocol ~config ~prompt in
    (match
       Http_client.post_sync
         ?cache:connection_cache
         ?clock
         ?timeout_s
         ~sw
         ~net
         ~url
         ~headers
         ~body
         ()
     with
     | Error _ as error -> error
     | Ok (code, response_body) when code >= 200 && code < 300 ->
       parse_response ~protocol response_body
     | Ok (code, response_body) ->
       Error
         (Http_client.HttpError { code; body = response_body; retry_after_header = None }))
;;

let test_caps task = { Capabilities.default_capabilities with task }

let test_config kind task =
  Provider_config.make
    ~kind
    ~provider_id:"test-image"
    ~model_id:"test-image-model"
    ~base_url:"https://example.invalid"
    ~request_path:"/images/generations"
    ~model_capabilities_override:(test_caps task)
    ()
;;

let catalog_declares_image_task provider_label model_id =
  match
    Capabilities.for_provider_model_id
      ~allow_bare_fallback:false
      ~provider_label
      ~model_id
  with
  | Some { task = Some Capabilities.Image_generation; _ } -> true
  | Some _ | None -> false
;;

let%test "embedded catalog declares exact image providers" =
  catalog_declares_image_task "zai-image" "glm-image"
  && catalog_declares_image_task "openai-image" "gpt-image-2"
  && catalog_declares_image_task "gemini-image" "gemini-3.1-flash-image"
  && catalog_declares_image_task "gemini-image" "gemini-3.1-flash-lite-image"
  && catalog_declares_image_task "gemini-image" "gemini-3-pro-image"
;;

let%test "request requires an exact image-generation task" =
  match validate_request (test_config Provider_config.Glm None) "draw" with
  | Error (Http_client.AcceptRejected _) -> true
  | Ok _ | Error _ -> false
;;

let%test "Gemini image interaction is explicitly stateless" =
  let config = test_config Provider_config.Gemini (Some Capabilities.Image_generation) in
  let json =
    request_body ~protocol:Gemini_interaction ~config ~prompt:"draw"
    |> Yojson.Safe.from_string
  in
  Yojson.Safe.Util.member "store" json = `Bool false
;;

let%test "Z.AI URL response and safety observation are typed" =
  match
    parse_response
      ~protocol:Zai_image
      {|{"created":7,"data":[{"url":"https://example.test/a.png"}],"content_filter":[{"level":1},{"role":"assistant","level":2}]}|}
  with
  | Ok
      { created_at = Some 7
      ; created_at_rfc3339 = None
      ; provider_response_id = None
      ; images = [ { source = Remote_url url } ]
      ; usage = None
      ; content_filter =
          [ { role = None; level = 1 }; { role = Some Assistant; level = 2 } ]
      } -> String.equal url "https://example.test/a.png"
  | Ok _ | Error _ -> false
;;

let%test "OpenAI base64 response preserves usage and declared format" =
  match
    parse_response
      ~protocol:Openai_image
      {|{"created":8,"output_format":"png","data":[{"b64_json":"aGVsbG8="}],"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}|}
  with
  | Ok
      { images = [ { source = Inline_base64 { media_type = Some "image/png"; data } } ]
      ; usage =
          Some
            { input_tokens = Some 1
            ; output_tokens = Some 2
            ; total_tokens = Some 3
            ; cached_tokens = None
            ; thought_tokens = None
            ; tool_use_tokens = None
            }
      ; content_filter = []
      ; _
      } -> String.equal data "aGVsbG8="
  | Ok _ | Error _ -> false
;;

let%test "base64 without a declared format carries no media type" =
  match
    parse_response
      ~protocol:Openai_image
      {|{"created":8,"data":[{"b64_json":"aGVsbG8="}]}|}
  with
  | Ok { images = [ { source = Inline_base64 { media_type = None; data } } ]; _ } ->
    String.equal data "aGVsbG8="
  | Ok _ | Error _ -> false
;;

let%test "non-object 2xx body is a typed parse failure" =
  match parse_response ~protocol:Openai_image "null" with
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Provider_parse_error { parser = Some "image_generation" }
         ; _
         }) -> true
  | Ok _ | Error _ -> false
;;

let%test "ambiguous image source fails closed" =
  match
    parse_response
      ~protocol:Openai_image
      {|{"data":[{"url":"https://x","b64_json":"eA=="}]}|}
  with
  | Error (Http_client.ProviderFailure _) -> true
  | Ok _ | Error _ -> false
;;

let%test "Gemini interaction preserves image, identity, time, and usage" =
  match
    parse_response
      ~protocol:Gemini_interaction
      {|{"id":"ix-1","status":"completed","created":"2026-07-16T00:00:00Z","steps":[{"type":"thought"},{"type":"model_output","content":[{"type":"image","data":"eA==","mime_type":"image/webp"}]}],"usage":{"total_input_tokens":4,"total_output_tokens":5,"total_tokens":12,"total_cached_tokens":1,"total_thought_tokens":3,"total_tool_use_tokens":0}}|}
  with
  | Ok
      { created_at = None
      ; created_at_rfc3339 = Some "2026-07-16T00:00:00Z"
      ; provider_response_id = Some "ix-1"
      ; images =
          [ { source = Inline_base64 { media_type = Some "image/webp"; data = "eA==" } } ]
      ; usage =
          Some
            { input_tokens = Some 4
            ; output_tokens = Some 5
            ; total_tokens = Some 12
            ; cached_tokens = Some 1
            ; thought_tokens = Some 3
            ; tool_use_tokens = Some 0
            }
      ; content_filter = []
      } -> true
  | Ok _ | Error _ -> false
;;

let%test "Gemini non-object 2xx body is a typed parse failure" =
  match parse_response ~protocol:Gemini_interaction "[]" with
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Provider_parse_error { parser = Some "image_generation" }
         ; _
         }) -> true
  | Ok _ | Error _ -> false
;;

let%test "Gemini non-completed status is a provider failure, not a parse error" =
  match
    parse_response
      ~protocol:Gemini_interaction
      {|{"id":"ix-4","status":"failed","steps":[]}|}
  with
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Unknown_provider_failure { reason = Some reason }; _ }) ->
    String.equal reason "gemini interaction status failed"
  | Ok _ | Error _ -> false
;;

let%test "Gemini image-only response rejects text output" =
  match
    parse_response
      ~protocol:Gemini_interaction
      {|{"id":"ix-2","status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"not an image"}]}]}|}
  with
  | Error (Http_client.ProviderFailure _) -> true
  | Ok _ | Error _ -> false
;;

let%test "Gemini optional usage fields stay absent rather than becoming zero" =
  match
    parse_response
      ~protocol:Gemini_interaction
      {|{"id":"ix-3","status":"completed","steps":[{"type":"model_output","content":[{"type":"image","uri":"https://example.test/image.png"}]}],"usage":{}}|}
  with
  | Ok
      { usage =
          Some
            { input_tokens = None
            ; output_tokens = None
            ; total_tokens = None
            ; cached_tokens = None
            ; thought_tokens = None
            ; tool_use_tokens = None
            }
      ; _
      } -> true
  | Ok _ | Error _ -> false
;;
