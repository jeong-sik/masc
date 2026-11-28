open Result.Syntax

type request = Llm_provider.Image_gen.request

type endpoint_generate_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  dialect:Llm_provider.Capabilities.images_api_dialect ->
  request ->
  (Llm_provider.Image_gen.generation_result, Llm_provider.Http_client.http_error) result

type remote_fetch_fn =
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
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

let max_error_body_chars = 512
let max_remote_redirects = 5

let strip_ipv6_brackets s =
  let len = String.length s in
  if len >= 2 && Char.equal s.[0] '[' && Char.equal s.[len - 1] ']'
  then String.sub s 1 (len - 2)
  else s

let strip_trailing_dot s =
  let len = String.length s in
  if len > 0 && Char.equal s.[len - 1] '.'
  then String.sub s 0 (len - 1)
  else s

let validate_remote_download_url url =
  let uri = Uri.of_string (String.trim url) in
  match Option.map String.lowercase_ascii (Uri.scheme uri), Uri.host uri with
  | Some "https", Some raw_host ->
    if Option.is_some (Uri.userinfo uri)
    then Error "remote image URL must not contain credentials"
    else (
      let host =
        raw_host
        |> String.trim
        |> strip_ipv6_brackets
        |> strip_trailing_dot
        |> String.lowercase_ascii
      in
      if String.equal host ""
         || String.equal host "localhost"
         || String.ends_with ~suffix:".localhost" host
         || String.ends_with ~suffix:".local" host
      then Error "remote image URL has a missing or disallowed host"
      else (
        match Ipaddr.of_string host with
        | Ok ip ->
          (match Outbound_address.ip_refusal ip with
           | Some refusal ->
             Error
               (Printf.sprintf
                  "remote image URL host is disallowed (%s)"
                  (Outbound_address.refusal_to_string refusal))
           | None -> Ok ())
        | Error _ -> Ok ()))
  | Some scheme, _ ->
    Error (Printf.sprintf "remote image URL must use https (got %s)" scheme)
  | None, _ -> Error "remote image URL must use https"

let is_redirect_status code =
  code = 301 || code = 302 || code = 303 || code = 307 || code = 308

let header_ci headers name =
  let target = String.lowercase_ascii name in
  List.find_map
    (fun (k, v) ->
       if String.equal (String.lowercase_ascii k) target then Some v else None)
    headers

let default_fetch_remote_url ~net ~clock ~max_bytes initial_url =
  let timeout_sec = Keeper_runtime_resolved.provider_call_deadline_sec () in
  let rec follow ~remaining_redirects current_url =
    let* () = validate_remote_download_url current_url in
    let current_uri = Uri.of_string (String.trim current_url) in
    match Outbound_address.resolve_allowed_host ~net current_uri with
    | Error refusal ->
      Error
        (Printf.sprintf
           "remote image download refused host: %s"
           (Outbound_address.host_refusal_to_string refusal))
    | Ok resolved_addresses ->
      (match
         Masc_http_client.get_response_sync
           ~clock
           ~timeout_sec
           ~max_body_bytes:max_bytes
           ~resolved_addresses
           ~url:current_url
           ~headers:[]
           ()
       with
       | Error err -> Error (Printf.sprintf "remote image download failed: %s" err)
       | Ok (resp : Masc_http_client.response) when resp.status >= 200 && resp.status < 300 ->
         Ok resp.body
       | Ok resp when is_redirect_status resp.status ->
         if remaining_redirects <= 0
         then Error "remote image download exceeded maximum redirects"
         else (
           match header_ci resp.headers "location" with
           | Some loc when String.trim loc <> "" ->
             let next_url =
               Uri.resolve "" current_uri (Uri.of_string (String.trim loc))
               |> Uri.to_string
             in
             follow ~remaining_redirects:(remaining_redirects - 1) next_url
           | Some _ | None ->
             Error
               (Printf.sprintf
                  "remote image download redirect HTTP %d missing Location header"
                  resp.status))
       | Ok resp ->
         Error (Printf.sprintf "remote image download returned HTTP %d" resp.status))
  in
  follow ~remaining_redirects:max_remote_redirects initial_url

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

let compact_base64 raw =
  let buf = Buffer.create (String.length raw) in
  String.iter
    (function
      | ' ' | '\t' | '\r' | '\n' -> ()
      | c -> Buffer.add_char buf c)
    raw;
  Buffer.contents buf

let extracted_images_of_api_response (resp : Agent_core.Types.api_response)
  : (Llm_provider.Image_gen.generated_image list, string) result
  =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | Llm_provider.Types.Image { media_type; source } :: rest ->
      let mime_type = Llm_provider.Api_common.declared_media_type_opt media_type in
      (match source with
       | Llm_provider.Types.Base64 b64 ->
         (match Base64.decode ~pad:false (compact_base64 b64) with
          | Ok data_bytes ->
            let item : Llm_provider.Image_gen.generated_image =
              { mime_type
              ; data_bytes = Some data_bytes
              ; remote_url = None
              ; revised_prompt = None
              }
            in
            loop (item :: acc) rest
          | Error (`Msg msg) -> Error ("invalid base64 image in model response: " ^ msg))
       | Llm_provider.Types.Url url ->
         let item : Llm_provider.Image_gen.generated_image =
           { mime_type
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

let sanitize_error_snippet raw =
  let len = String.length raw in
  let buf = Buffer.create (min len max_error_body_chars) in
  let rec loop idx prev_space =
    if idx >= len
    then false
    else if Buffer.length buf >= max_error_body_chars
    then true
    else (
      let c = raw.[idx] in
      let code = Char.code c in
      if code < 32 || code = 127 || Char.equal c ' '
      then (
        if (not prev_space) && Buffer.length buf > 0 then Buffer.add_char buf ' ';
        loop (idx + 1) true)
      else (
        Buffer.add_char buf c;
        loop (idx + 1) false))
  in
  let truncated = loop 0 false in
  let text = String.trim (Buffer.contents buf) in
  if truncated && text <> "" then text ^ "..." else text

let format_http_error (err : Llm_provider.Http_client.http_error) =
  match err with
  | Llm_provider.Http_client.HttpError { code; body; _ } ->
    (match body with
     | Llm_provider.Http_client.Not_received_in_window ->
       Printf.sprintf "HTTP %d (response body not received)" code
     | Llm_provider.Http_client.Received raw ->
       let snippet = sanitize_error_snippet raw in
       if String.equal snippet ""
       then Printf.sprintf "HTTP %d" code
       else Printf.sprintf "HTTP %d: %s" code snippet)
  | Llm_provider.Http_client.NetworkError { message; _ } ->
    "network error: " ^ sanitize_error_snippet message
  | Llm_provider.Http_client.Connect_failed { message; _ } ->
    "connection failed: " ^ sanitize_error_snippet message
  | Llm_provider.Http_client.TimeoutError { message; _ } ->
    "timeout: " ^ sanitize_error_snippet message
  | Llm_provider.Http_client.AcceptRejected { reason } ->
    "request rejected: " ^ sanitize_error_snippet reason
  | Llm_provider.Http_client.ProviderTerminal { message; _ } ->
    "provider terminal: " ^ sanitize_error_snippet message
  | Llm_provider.Http_client.ProviderFailure { message; _ } ->
    "provider failure: " ^ sanitize_error_snippet message

type target_failure_kind =
  | Pre_dispatch_failover
  | Terminal_no_failover of Tool_result.tool_failure_class

type target_error =
  { kind : target_failure_kind
  ; detail : string
  }

let pre_dispatch_error detail = { kind = Pre_dispatch_failover; detail }

let terminal_error ~failure_class detail =
  { kind = Terminal_no_failover failure_class; detail }

(* Paid image generation is side-effecting: only advance to another candidate
   when the failure is guaranteed to have occurred before the provider accepted
   and billed the request. Post-dispatch errors (timeouts, 400/422, 500/504,
   connection resets, response-body-too-large, parse errors) fail closed. *)
let classify_http_error (err : Llm_provider.Http_client.http_error) : target_failure_kind =
  match err with
  | Llm_provider.Http_client.Connect_failed _ -> Pre_dispatch_failover
  | Llm_provider.Http_client.NetworkError { kind; _ } ->
    (match kind with
     | Llm_provider.Http_client.Connection_refused
     | Llm_provider.Http_client.Dns_failure
     | Llm_provider.Http_client.Unreachable
     | Llm_provider.Http_client.Tls_error
     | Llm_provider.Http_client.Local_resource_exhaustion -> Pre_dispatch_failover
     | Llm_provider.Http_client.Timeout
     | Llm_provider.Http_client.Connection_reset
     | Llm_provider.Http_client.End_of_file
     | Llm_provider.Http_client.Unknown ->
       Terminal_no_failover Tool_result.Dependency_unavailable)
  | Llm_provider.Http_client.HttpError { code; _ } ->
    (match code with
     | 401 | 403 | 429 | 503 -> Pre_dispatch_failover
     | 400 | 404 | 422 -> Terminal_no_failover Tool_result.Policy_rejection
     | _ -> Terminal_no_failover Tool_result.Dependency_unavailable)
  | Llm_provider.Http_client.TimeoutError _ ->
    Terminal_no_failover Tool_result.Dependency_unavailable
  | Llm_provider.Http_client.AcceptRejected _ ->
    Terminal_no_failover Tool_result.Policy_rejection
  | Llm_provider.Http_client.ProviderTerminal _ ->
    Terminal_no_failover Tool_result.Runtime_failure
  | Llm_provider.Http_client.ProviderFailure { kind; _ } ->
    (match kind with
     | Llm_provider.Http_client.Capacity_exhausted _
     | Llm_provider.Http_client.Hard_quota _
     | Llm_provider.Http_client.Cli_startup_failed _ -> Pre_dispatch_failover
     | Llm_provider.Http_client.Capability_mismatch _
     | Llm_provider.Http_client.Cli_policy_invalid _ ->
       Terminal_no_failover Tool_result.Policy_rejection
     | Llm_provider.Http_client.Response_body_too_large _
     | Llm_provider.Http_client.Provider_parse_error _
     | Llm_provider.Http_client.Provider_wire_error _
     | Llm_provider.Http_client.Provider_reported_error _
     | Llm_provider.Http_client.Provider_interrupted
     | Llm_provider.Http_client.Empty_completion _
     | Llm_provider.Http_client.Context_overflow _
     | Llm_provider.Http_client.Unknown_provider_failure _ ->
       Terminal_no_failover Tool_result.Runtime_failure)

let classify_official_failure (failure : Fusion_official_client.failure)
  : target_failure_kind
  =
  match failure with
  | Fusion_official_client.Setup_failure _
  | Fusion_official_client.Claude_admission_failure _ -> Pre_dispatch_failover
  | Fusion_official_client.Missing_reply
  | Fusion_official_client.Codex_failure _
  | Fusion_official_client.Claude_failure _
  | Fusion_official_client.Antigravity_failure _
  | Fusion_official_client.Acp_failure _ ->
    Terminal_no_failover Tool_result.Runtime_failure

let unseal_agent_core (runtime : Runtime_instance.t) =
  match runtime.Runtime_instance.execution with
  | Runtime_execution.Agent_core sealed ->
    Runtime_account_access.authorize_api sealed
    |> Result.map_error (fun r ->
      pre_dispatch_error (Runtime_account_access.refusal_to_string r))
  | Runtime_execution.Claude_code _
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Acp _ ->
    Error
      (pre_dispatch_error
         (Printf.sprintf "runtime %s is not an HTTP Agent_core runtime" runtime.id))

let check_negative_prompt_supported ~target_label ~unsupported =
  if List.mem "negative_prompt" unsupported
  then
    Error
      (terminal_error
         ~failure_class:Tool_result.Policy_rejection
         (Printf.sprintf "%s does not support negative_prompt" target_label))
  else Ok ()

let run_single_target
    ~base_dir
    ~sw
    ~net
    ~clock
    ?generate_endpoint
    ?complete_in_turn
    (req : request)
    (target : Runtime_agent.image_generator_target)
  : (Llm_provider.Image_gen.generation_result, target_error) result
  =
  let target_label = Runtime_agent.image_generator_target_label target in
  let timeout_s = Keeper_runtime_resolved.provider_call_deadline_sec () in
  let call_endpoint ~config ~dialect =
    let unsupported = Llm_provider.Image_gen.unsupported_options ~dialect req in
    let* () = check_negative_prompt_supported ~target_label ~unsupported in
    let fn =
      match generate_endpoint with
      | Some f -> f
      | None ->
        fun ~sw ~net ~clock ~config ~dialect req ->
          Llm_provider.Image_gen.generate
            ~timeout_s
            ~sw
            ~net
            ~clock
            ~config
            ~dialect
            req
    in
    match fn ~sw ~net ~clock ~config ~dialect req with
    | Ok res ->
      let ignored_options =
        if res.ignored_options <> [] then res.ignored_options else unsupported
      in
      Ok { res with ignored_options }
    | Error err ->
      Error { kind = classify_http_error err; detail = format_http_error err }
  in
  let call_in_turn ~config ~contract =
    let ignored_options =
      Llm_provider.Image_gen.unsupported_options_for_contract ~contract req
    in
    let* () =
      check_negative_prompt_supported ~target_label ~unsupported:ignored_options
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
          [ Llm_provider.Types.text_block req.prompt ]
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
    | Error err ->
      Error { kind = classify_http_error err; detail = format_http_error err }
    | Ok resp ->
      (match extracted_images_of_api_response resp with
       | Ok images -> Ok { Llm_provider.Image_gen.images; ignored_options }
       | Error detail ->
         Error (terminal_error ~failure_class:Tool_result.Runtime_failure detail))
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
      { source_runtime; model_id; provider_id; contract; _ } ->
    let* base = unseal_agent_core source_runtime in
    let config = sibling_provider_config base ~model_id ~provider_id () in
    call_in_turn ~config ~contract
  | Runtime_agent.Runtime_in_turn { runtime; contract } ->
    (match runtime.Runtime_instance.execution, contract with
     | _, Llm_provider.Capabilities.Endpoint_images_api dialect ->
       let* config = unseal_agent_core runtime in
       call_endpoint ~config ~dialect
     | _, Llm_provider.Capabilities.No_image_output ->
       Error
         (terminal_error
            ~failure_class:Tool_result.Policy_rejection
            (Printf.sprintf "runtime %s does not support image generation" runtime.id))
     | ( Runtime_execution.Agent_core _
       , ( Llm_provider.Capabilities.In_turn_gemini_modalities
         | Llm_provider.Capabilities.In_turn_openai_responses_tool
         | Llm_provider.Capabilities.In_turn_openai_chat_modalities
         | Llm_provider.Capabilities.In_turn_codex_item
         | Llm_provider.Capabilities.In_turn_acp_chunk ) ) ->
       let* config = unseal_agent_core runtime in
       call_in_turn ~config ~contract
     | ( ( Runtime_execution.Codex_app_server _
         | Runtime_execution.Acp _
         | Runtime_execution.Claude_code _
         | Runtime_execution.Antigravity_cli _ )
       , ( Llm_provider.Capabilities.In_turn_codex_item
         | Llm_provider.Capabilities.In_turn_acp_chunk
         | Llm_provider.Capabilities.In_turn_openai_responses_tool
         | Llm_provider.Capabilities.In_turn_openai_chat_modalities
         | Llm_provider.Capabilities.In_turn_gemini_modalities ) ) ->
       let ignored_options =
         Llm_provider.Image_gen.unsupported_options_for_contract ~contract req
       in
       let* () =
         check_negative_prompt_supported ~target_label ~unsupported:ignored_options
       in
       (match
          Fusion_official_client.run_with_images
            ~images:[]
            ~base_dir
            ~runtime
            ~system_prompt:"Generate the requested image."
            ~timeout_s
            ~prompt:req.prompt
            ()
        with
        | Error failure ->
          Error
            { kind = classify_official_failure failure
            ; detail = Fusion_official_client.failure_detail ~runtime_id:runtime.id failure
            }
        | Ok resp ->
          if resp.media_outputs = []
          then
            Error
              (terminal_error
                 ~failure_class:Tool_result.Runtime_failure
                 (Printf.sprintf "runtime %s completed without generating an image" runtime.id))
          else
            let images =
              List.map
                (fun (m : Fusion_official_client.media_output) ->
                   ({ mime_type = Llm_provider.Api_common.declared_media_type_opt m.mime_type
                    ; data_bytes = Some m.data_bytes
                    ; remote_url = None
                    ; revised_prompt = None
                    }
                    : Llm_provider.Image_gen.generated_image))
                resp.media_outputs
            in
            Ok { Llm_provider.Image_gen.images; ignored_options }))

let resolve_base_path ?base_path () =
  match base_path with
  | Some bp when String.trim bp <> "" -> bp
  | Some _ | None ->
    let keepers = Config_dir_resolver.keepers_dir () in
    Filename.dirname (Filename.dirname keepers)

let persist_generated_images
    ~store
    ~keeper_name
    ~net
    ~clock
    ~fetch_remote_url
    (images : Llm_provider.Image_gen.generated_image list)
  : (Attachment_store.meta * string * string option) list * string list
  =
  let max_bytes = Attachment_store.max_bytes () in
  let rec loop idx persisted_rev errors_rev = function
    | [] -> List.rev persisted_rev, List.rev errors_rev
    | (img : Llm_provider.Image_gen.generated_image) :: rest ->
      let raw_res =
        match img.data_bytes, img.remote_url with
        | Some bytes, _ -> Ok bytes
        | None, Some url -> fetch_remote_url ~net ~clock ~max_bytes url
        | None, None -> Error "generated image entry contained neither bytes nor URL"
      in
      (match raw_res with
       | Error err ->
         let msg = Printf.sprintf "image #%d: %s" idx err in
         loop (idx + 1) persisted_rev (msg :: errors_rev) rest
       | Ok raw_bytes ->
         let declared_mime =
           Option.bind img.mime_type Llm_provider.Api_common.declared_media_type_opt
         in
         let ext =
           match Attachment_store.sniff_mime raw_bytes with
           | Some supported -> Attachment_store.extension_of_mime supported
           | None -> ".png"
         in
         let filename = Printf.sprintf "generated-%d%s" idx ext in
         let put_once declared_mime =
           Attachment_store.put
             ?declared_mime
             ~filename
             ~origin:Attachment_store.Model_generated
             ~created_by:keeper_name
             ~retention:Attachment_store.Durable
             store
             ~bytes:raw_bytes
         in
         let stored =
           match put_once declared_mime with
           | Ok meta -> Ok meta
           | Error (Attachment_store.Mime_mismatch _) when Option.is_some declared_mime ->
             (* Provider declared a stale/inaccurate MIME header for valid bytes;
                retry with magic-byte sniffing instead of dropping a paid image. *)
             put_once None
           | Error
               ( Attachment_store.Mime_mismatch _
               | Attachment_store.Empty_payload
               | Attachment_store.Payload_too_large _
               | Attachment_store.Unsupported_or_unknown_format _
               | Attachment_store.Forbidden_mime _
               | Attachment_store.Encrypted_document _
               | Attachment_store.Invalid_keeper_name _
               | Attachment_store.Store_io_failed _ ) as err -> err
         in
         (match stored with
          | Ok meta ->
            loop
              (idx + 1)
              ((meta, raw_bytes, img.revised_prompt) :: persisted_rev)
              errors_rev
              rest
          | Error err ->
            let msg =
              Printf.sprintf
                "image #%d: %s"
                idx
                (Attachment_store.put_error_to_string err)
            in
            loop (idx + 1) persisted_rev (msg :: errors_rev) rest))
  in
  loop 1 [] [] images

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
               | Error { kind = Pre_dispatch_failover; detail } ->
                 Log.Keeper.warn
                   "keeper_generate_image pre-dispatch candidate failure keeper=%s target=%s: %s"
                   meta.name
                   label
                   detail;
                 walk (Some (Printf.sprintf "%s: %s" label detail)) rest
               | Error { kind = Terminal_no_failover failure_class; detail } ->
                 Log.Keeper.warn
                   "keeper_generate_image terminal failure (no failover) keeper=%s target=%s: %s"
                   meta.name
                   label
                   detail;
                 failed
                   ~failure_class
                   "image_generation_failed"
                   (Printf.sprintf "%s: %s" label detail)
               | Ok { Llm_provider.Image_gen.images; ignored_options } ->
                 let store = Attachment_store.create ~base_path:resolved_base in
                 let persisted, persist_errors =
                   persist_generated_images
                     ~store
                     ~keeper_name:meta.name
                     ~net
                     ~clock
                     ~fetch_remote_url
                     images
                 in
                 (match persisted with
                  | [] ->
                    let detail =
                      if persist_errors = []
                      then "provider returned no persistable images"
                      else String.concat "; " persist_errors
                    in
                    failed
                      ~failure_class:Tool_result.Runtime_failure
                      "attachment_store_failed"
                      detail
                  | _ ->
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
                    let ignored_fields =
                      match ignored_options with
                      | [] -> []
                      | opts ->
                        [ "ignored_options", `List (List.map (fun s -> `String s) opts) ]
                    in
                    let partial_fields =
                      match persist_errors with
                      | [] -> []
                      | errs ->
                        [ "partial", `Bool true
                        ; "errors", `List (List.map (fun e -> `String e) errs)
                        ]
                    in
                    let data =
                      `Assoc
                        ([ "ok", `Bool true
                         ; "runtime_id", `String label
                         ; "count", `Int (List.length persisted)
                         ; "images", `List image_json_items
                         ; "attachments", `List attachment_refs
                         ]
                         @ primary_fields
                         @ ignored_fields
                         @ partial_fields)
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
