open Result.Syntax

type request = Llm_provider.Image_gen.request

type endpoint_generate_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  dialect:Llm_provider.Capabilities.images_api_dialect ->
  request ->
  (Llm_provider.Image_gen.generated_image list, Llm_provider.Http_client.http_error) result

type remote_fetch_fn =
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  max_bytes:int ->
  string ->
  (string, string) result

let allowed_param_keys =
  [ "prompt"
  ; "aspect_ratio"
  ; "size"
  ; "quality"
  ; "count"
  ; "output_format"
  ; "negative_prompt"
  ; "runtime_id"
  ]

let allowed_output_formats = [ "png"; "jpeg"; "webp" ]

let opt_nonempty_string fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
    let trimmed = String.trim raw in
    if String.equal trimmed ""
    then Error (Printf.sprintf "%s must be a non-empty string" key)
    else Ok (Some trimmed)
  | Some _ -> Error (Printf.sprintf "%s must be a string" key)

let parse_args = function
  | `Assoc fields ->
    let unknown =
      List.filter_map
        (fun (k, _) ->
           if List.mem k allowed_param_keys then None else Some k)
        fields
    in
    if unknown <> []
    then
      Error
        (Printf.sprintf
           "unexpected argument(s): %s"
           (String.concat ", " unknown))
    else
      let* prompt =
        match opt_nonempty_string fields "prompt" with
        | Ok (Some p) -> Ok p
        | Ok None -> Error "prompt is required and must be a non-empty string"
        | Error _ as err -> err
      in
      let* aspect_ratio = opt_nonempty_string fields "aspect_ratio" in
      let* size = opt_nonempty_string fields "size" in
      let* quality = opt_nonempty_string fields "quality" in
      let* negative_prompt = opt_nonempty_string fields "negative_prompt" in
      let* runtime_id = opt_nonempty_string fields "runtime_id" in
      let* output_format =
        let* raw = opt_nonempty_string fields "output_format" in
        match raw with
        | None -> Ok None
        | Some fmt ->
          let normalized = String.lowercase_ascii fmt in
          if List.mem normalized allowed_output_formats
          then Ok (Some normalized)
          else
            Error
              (Printf.sprintf
                 "output_format must be one of %s"
                 (String.concat ", " allowed_output_formats))
      in
      let* count =
        match List.assoc_opt "count" fields with
        | None | Some `Null -> Ok None
        | Some (`Int n) when n >= 1 && n <= 4 -> Ok (Some n)
        | Some (`Int _) -> Error "count must be an integer between 1 and 4"
        | Some _ -> Error "count must be an integer between 1 and 4"
      in
      Ok
        ( Llm_provider.Image_gen.make_request
            ?aspect_ratio
            ?size
            ?quality
            ?count
            ?output_format
            ?negative_prompt
            prompt
        , runtime_id )
  | _ -> Error "keeper_generate_image arguments must be a JSON object"

let sibling_provider_config
    (base : Llm_provider.Provider_config.t)
    ~model_id
    ~provider_id
    ?request_path
    ()
  =
  { base with
    model_id
  ; provider_id = Some provider_id
  ; request_path = Option.value request_path ~default:base.request_path
  ; model_capabilities_override = None
  ; request_policy_snapshot = None
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; enable_thinking = None
  ; preserve_thinking = None
  ; reasoning_effort = None
  ; response_format = Llm_provider.Types.Off
  }

let is_private_or_loopback_host host =
  let h = String.lowercase_ascii (String.trim host) in
  String.equal h ""
  || String.equal h "localhost"
  || String.ends_with ~suffix:".localhost" h
  || String.ends_with ~suffix:".local" h
  || String.equal h "::1"
  || String.equal h "[::1]"
  || String.equal h "0.0.0.0"
  || String.starts_with ~prefix:"127." h
  || String.starts_with ~prefix:"10." h
  || String.starts_with ~prefix:"169.254." h
  || String.starts_with ~prefix:"192.168." h
  || String.starts_with ~prefix:"fc" h
  || String.starts_with ~prefix:"fd" h
  || (String.starts_with ~prefix:"172." h
      &&
      match String.split_on_char '.' h with
      | _ :: second :: _ ->
        (match int_of_string_opt second with
         | Some n -> n >= 16 && n <= 31
         | None -> false)
      | _ -> false)

let validate_remote_download_url url =
  let uri = Uri.of_string (String.trim url) in
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some host when not (is_private_or_loopback_host host) ->
    if Option.is_some (Uri.userinfo uri)
    then Error "remote image URL must not contain credentials"
    else Ok ()
  | Some scheme, _ when not (String.equal scheme "https") ->
    Error (Printf.sprintf "remote image URL must use https (got %s)" scheme)
  | _ -> Error "remote image URL has a missing or disallowed host"

let default_fetch_remote_url ~clock ~max_bytes url =
  let* () = validate_remote_download_url url in
  match Masc_http_client.get_sync ~clock ~max_body_bytes:max_bytes ~url ~headers:[] () with
  | Ok (code, bytes) when code >= 200 && code < 300 -> Ok bytes
  | Ok (code, _) -> Error (Printf.sprintf "remote image download returned HTTP %d" code)
  | Error err -> Error (Printf.sprintf "remote image download failed: %s" err)

let failed ~failure_class code detail =
  let payload =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String code
      ; "failure_class", `String (Tool_result.tool_failure_class_to_string failure_class)
      ; "detail", `String detail
      ]
  in
  Keeper_tool_execution.failure_data ~class_:failure_class ~message:detail payload

let image_options_of_request (req : request) : Llm_provider.Provider_config.image_generation_options =
  { aspect_ratio = req.aspect_ratio
  ; size = req.size
  ; quality = req.quality
  ; count = req.count
  }

let extracted_images_of_api_response (resp : Agent_core.Types.api_response)
  : (Llm_provider.Image_gen.generated_image list, string) result
  =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | Llm_provider.Types.Image { media_type; source } :: rest ->
      (match source with
       | Llm_provider.Types.Base64 b64 ->
         (match Base64.decode b64 with
          | Ok data_bytes ->
            let item : Llm_provider.Image_gen.generated_image =
              { mime_type = media_type
              ; data_bytes = Some data_bytes
              ; remote_url = None
              ; revised_prompt = None
              }
            in
            loop (item :: acc) rest
          | Error (`Msg msg) -> Error ("invalid base64 image in model response: " ^ msg))
       | Llm_provider.Types.Url url ->
         let item : Llm_provider.Image_gen.generated_image =
           { mime_type = media_type
           ; data_bytes = None
           ; remote_url = Some url
           ; revised_prompt = None
           }
         in
         loop (item :: acc) rest
       | Llm_provider.Types.File_id _ ->
         Error "provider returned file_id media without inline bytes or URL")
    | ( Llm_provider.Types.Text _
      | Llm_provider.Types.Thinking _
      | Llm_provider.Types.RedactedThinking _
      | Llm_provider.Types.ToolUse _
      | Llm_provider.Types.ToolResult _
      | Llm_provider.Types.Document _
      | Llm_provider.Types.Audio _
      | Llm_provider.Types.ReasoningDetails _
      | Llm_provider.Types.ToolReference _ ) :: rest ->
      loop acc rest
  in
  let* images = loop [] resp.content in
  if images = []
  then Error "provider completed without returning any image"
  else Ok images

let format_http_error (err : Llm_provider.Http_client.http_error) =
  match err with
  | Llm_provider.Http_client.HttpError { code; _ } ->
    Printf.sprintf "HTTP %d" code
  | Llm_provider.Http_client.NetworkError { message; _ } ->
    "network error: " ^ message
  | Llm_provider.Http_client.Connect_failed { message; _ } ->
    "connection failed: " ^ message
  | Llm_provider.Http_client.TimeoutError { message; _ } ->
    "timeout: " ^ message
  | Llm_provider.Http_client.AcceptRejected { reason } ->
    "request rejected: " ^ reason
  | Llm_provider.Http_client.ProviderTerminal { message; _ } ->
    "provider terminal: " ^ message
  | Llm_provider.Http_client.ProviderFailure { message; _ } ->
    "provider failure: " ^ message

let unseal_agent_core (runtime : Runtime_instance.t) =
  match runtime.Runtime_instance.execution with
  | Runtime_execution.Agent_core sealed ->
    Runtime_account_access.authorize_api sealed
    |> Result.map_error Runtime_account_access.refusal_to_string
  | Runtime_execution.Claude_code _
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Acp _ ->
    Error (Printf.sprintf "runtime %s is not an HTTP Agent_core runtime" runtime.id)

let run_single_target
    ~base_dir
    ~sw
    ~net
    ~clock
    ?generate_endpoint
    ?complete_in_turn
    (req : request)
    (target : Runtime_agent.image_generator_target)
  : (Llm_provider.Image_gen.generated_image list, string) result
  =
  let call_endpoint ~config ~dialect =
    let fn =
      match generate_endpoint with
      | Some f -> f
      | None ->
        fun ~sw ~net ~clock ~config ~dialect req ->
          Llm_provider.Image_gen.generate ~sw ~net ~clock ~config ~dialect req
    in
    fn ~sw ~net ~clock ~config ~dialect req
    |> Result.map_error format_http_error
  in
  let call_in_turn ~config =
    let prompt_text =
      match req.negative_prompt with
      | Some neg when String.trim neg <> "" ->
        Printf.sprintf "%s\n\nAvoid: %s" req.prompt neg
      | Some _ | None -> req.prompt
    in
    let config =
      { config with
        Llm_provider.Provider_config.output_media = Some (image_options_of_request req)
      ; tool_choice = None
      ; disable_parallel_tool_use = true
      ; response_format = Llm_provider.Types.Off
      }
    in
    let messages =
      [ Llm_provider.Types.make_message
          ~role:Llm_provider.Types.User
          [ Llm_provider.Types.text_block prompt_text ]
      ]
    in
    match
      Keeper_provider_subcall.complete
        ?override:complete_in_turn
        ~sw
        ~net
        ~clock
        ~config
        ~messages
        ()
    with
    | Error err -> Error (format_http_error err)
    | Ok resp -> extracted_images_of_api_response resp
  in
  match target with
  | Runtime_agent.Runtime_images_endpoint { runtime; dialect } ->
    let* config = unseal_agent_core runtime in
    call_endpoint ~config ~dialect
  | Runtime_agent.Derived_sibling_images_endpoint
      { source_runtime; model_id; provider_id; request_path; dialect; _ } ->
    let* base = unseal_agent_core source_runtime in
    let config =
      sibling_provider_config base ~model_id ~provider_id ~request_path ()
    in
    call_endpoint ~config ~dialect
  | Runtime_agent.Derived_sibling_in_turn
      { source_runtime; model_id; provider_id; contract = _; _ } ->
    let* base = unseal_agent_core source_runtime in
    let config = sibling_provider_config base ~model_id ~provider_id () in
    call_in_turn ~config
  | Runtime_agent.Runtime_in_turn { runtime; contract } ->
    (match runtime.Runtime_instance.execution, contract with
     | Runtime_execution.Agent_core _, _ ->
       let* config = unseal_agent_core runtime in
       call_in_turn ~config
     | ( ( Runtime_execution.Codex_app_server _
         | Runtime_execution.Acp _
         | Runtime_execution.Claude_code _
         | Runtime_execution.Antigravity_cli _ )
       , ( Llm_provider.Capabilities.In_turn_codex_item
         | Llm_provider.Capabilities.In_turn_acp_chunk
         | Llm_provider.Capabilities.In_turn_openai_responses_tool
         | Llm_provider.Capabilities.In_turn_openai_chat_modalities
         | Llm_provider.Capabilities.In_turn_gemini_modalities ) ) ->
       (match
          Fusion_official_client.run_with_images
            ~images:[]
            ~base_dir
            ~runtime
            ~system_prompt:"Generate the requested image."
            ~prompt:req.prompt
            ()
        with
        | Error failure ->
          Error
            (Fusion_official_client.failure_detail ~runtime_id:runtime.id failure)
        | Ok resp ->
          if resp.media_outputs = []
          then Error (Printf.sprintf "runtime %s completed without generating an image" runtime.id)
          else
            Ok
              (List.map
                 (fun (m : Fusion_official_client.media_output) ->
                    ({ mime_type = m.mime_type
                     ; data_bytes = Some m.data_bytes
                     ; remote_url = None
                     ; revised_prompt = None
                     }
                     : Llm_provider.Image_gen.generated_image))
                 resp.media_outputs))
     | _, Llm_provider.Capabilities.Endpoint_images_api dialect ->
       let* config = unseal_agent_core runtime in
       call_endpoint ~config ~dialect
     | _, Llm_provider.Capabilities.No_image_output ->
       Error (Printf.sprintf "runtime %s does not support image generation" runtime.id))

let resolve_base_path ?base_path () =
  match base_path with
  | Some bp when String.trim bp <> "" -> bp
  | Some _ | None ->
    let keepers = Config_dir_resolver.keepers_dir () in
    Filename.dirname (Filename.dirname keepers)

let persist_generated_images
    ~store
    ~keeper_name
    ~clock
    ~fetch_remote_url
    (images : Llm_provider.Image_gen.generated_image list)
  : ((Attachment_store.meta * string * string option) list, string) result
  =
  let max_bytes = Attachment_store.max_bytes () in
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | (img : Llm_provider.Image_gen.generated_image) :: rest ->
      let* raw_bytes =
        match img.data_bytes, img.remote_url with
        | Some bytes, _ -> Ok bytes
        | None, Some url -> fetch_remote_url ~clock ~max_bytes url
        | None, None -> Error "generated image entry contained neither bytes nor URL"
      in
      let declared_mime =
        let m = String.trim img.mime_type in
        if String.equal m "" then None else Some m
      in
      let ext =
        match Attachment_store.sniff_mime raw_bytes with
        | Some supported -> Attachment_store.extension_of_mime supported
        | None -> ".png"
      in
      let filename = Printf.sprintf "generated-%d%s" idx ext in
      let* meta =
        Attachment_store.put
          ?declared_mime
          ~filename
          ~origin:Attachment_store.Model_generated
          ~created_by:keeper_name
          ~retention:Attachment_store.Durable
          store
          ~bytes:raw_bytes
        |> Result.map_error Attachment_store.put_error_to_string
      in
      loop (idx + 1) ((meta, raw_bytes, img.revised_prompt) :: acc) rest
  in
  loop 1 [] images

let handle_with_outcome
    ?base_path
    ?active_runtime
    ?candidates
    ?generate_endpoint
    ?complete_in_turn
    ?(fetch_remote_url = default_fetch_remote_url)
    ?sw
    ?clock
    ?net
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~args
    ()
  =
  let start_time = Tool_timing.start () in
  match parse_args args with
  | Error detail ->
    failed ~failure_class:Tool_result.Policy_rejection "invalid_args" detail
  | Ok (req, requested_runtime_id) ->
    (match sw, net, clock with
     | None, _, _ | _, None, _ | _, _, None ->
       failed
         ~failure_class:Tool_result.Runtime_failure
         "eio_context_unavailable"
         "Image generation requires an active Eio switch, network, and clock."
     | Some sw, Some net, Some clock ->
       let target_list =
         match candidates with
         | Some explicit -> explicit
         | None ->
           Runtime_agent.image_generator_candidates
             ?active_runtime
             ?requested_runtime_id
             ()
       in
       (match target_list with
        | [] ->
          let failure_class, detail =
            match requested_runtime_id with
            | Some id ->
              ( Tool_result.Policy_rejection
              , Printf.sprintf
                  "Requested runtime %S is not configured or does not support image generation."
                  id )
            | None ->
              ( Tool_result.Runtime_failure
              , "No image-generation runtime or compatible provider credential is configured." )
          in
          failed ~failure_class "no_image_generator_available" detail
        | _ ->
          let resolved_base = resolve_base_path ?base_path () in
          let rec walk last_err = function
            | [] ->
              failed
                ~failure_class:Tool_result.Dependency_unavailable
                "image_generation_failed"
                (Option.value last_err ~default:"All image generation candidates failed.")
            | target :: rest ->
              let label = Runtime_agent.image_generator_target_label target in
              (match
                 run_single_target
                   ~base_dir:resolved_base
                   ~sw
                   ~net
                   ~clock
                   ?generate_endpoint
                   ?complete_in_turn
                   req
                   target
               with
               | Error err ->
                 Log.Keeper.warn
                   "keeper_generate_image candidate failed keeper=%s target=%s: %s"
                   meta.name
                   label
                   err;
                 walk (Some (Printf.sprintf "%s: %s" label err)) rest
               | Ok generated ->
                 let store = Attachment_store.create ~base_path:resolved_base in
                 (match
                    persist_generated_images
                      ~store
                      ~keeper_name:meta.name
                      ~clock
                      ~fetch_remote_url
                      generated
                  with
                  | Error detail ->
                    failed
                      ~failure_class:Tool_result.Runtime_failure
                      "attachment_store_failed"
                      detail
                  | Ok persisted ->
                    let image_json_items =
                      List.map
                        (fun ((att : Attachment_store.meta), _bytes, revised_prompt) ->
                           match Attachment_store.meta_to_wire_json att with
                           | `Assoc fields ->
                             let extra =
                               match revised_prompt with
                               | Some p -> [ "revised_prompt", `String p ]
                               | None -> []
                             in
                             `Assoc (fields @ extra)
                           | other -> other)
                        persisted
                    in
                    let attachment_refs =
                      List.map
                        (fun (att, _, _) -> Attachment_store.meta_to_wire_json att)
                        persisted
                    in
                    let primary_fields =
                      match persisted with
                      | (first, _, _) :: _ ->
                        [ "attachment_id", `String first.id
                        ; "url", `String (Attachment_store.url_of_id first.id)
                        ; "artifact", `String first.sha256
                        ]
                      | [] -> []
                    in
                    let data =
                      `Assoc
                        ([ "ok", `Bool true
                         ; "runtime_id", `String label
                         ; "count", `Int (List.length persisted)
                         ; "images", `List image_json_items
                         ; "attachments", `List attachment_refs
                         ]
                         @ primary_fields)
                    in
                    let image_blocks =
                      List.map
                        (fun ((att : Attachment_store.meta), raw_bytes, _) ->
                           Llm_provider.Types.image_block
                             ~media_type:att.mime_type
                             ~source:
                               (Llm_provider.Types.Base64
                                  (Base64.encode_string raw_bytes)))
                        persisted
                    in
                    Tool_result.make_ok
                      ~tool_name:"keeper_generate_image"
                      ~start_time
                      ~data
                      ~content_blocks:
                        (Llm_provider.Types.Text (Yojson.Safe.to_string data)
                         :: image_blocks)
                      ()
                    |> Keeper_tool_execution.of_tool_result))
          in
          walk None target_list))
