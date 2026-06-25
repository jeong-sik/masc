module Va = Multimodal.Vision_analyze
module Store = Multimodal.Vision_artifact_store

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

(* Mirrors Keeper_librarian_runtime.default_complete / with_timeout (neither is
   exposed). Replicated rather than shared: two tiny consumers do not yet justify
   a shared keeper_provider_subcall module (repetition over premature
   abstraction); extract one if a third sub-call appears. *)
let default_complete : complete_fn =
 fun ~sw ~net ?clock ~config ~messages () ->
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()

(* Only [Eio.Time.Timeout] is caught here; [Eio.Cancel.Cancelled] and other
   exceptions are intentionally propagated so caller cancellation is not
   swallowed by the tool-level timeout handler. *)
let with_timeout ~clock ~timeout_sec f =
  try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
  | Eio.Time.Timeout -> None

(* One-shot vision read: shorter than a full keeper turn. *)
let default_timeout_sec = 120.0

(* Thinking is forced off (below), so the budget only needs room for the answer;
   keep it well above the 64-token point where the 2026-06-25 gemma4 reply
   truncated entirely into the thinking phase. *)
let vision_default_max_tokens = 1024

(* Tool policy SSOT for raw artifact size. The provider request base64-encodes
   this payload, so 10 MiB raw stays below the default 20 MiB HTTP body cap even
   after ~33% expansion. *)
let max_image_bytes = 10 * 1024 * 1024

let truncated_of_stop_reason : Agent_sdk.Types.stop_reason -> bool = function
  | Agent_sdk.Types.MaxTokens -> true
  | Agent_sdk.Types.EndTurn
  | Agent_sdk.Types.StopToolUse
  | Agent_sdk.Types.StopSequence
  | Agent_sdk.Types.Refusal
  | Agent_sdk.Types.PauseTurn
  | Agent_sdk.Types.Compaction
  | Agent_sdk.Types.ContextWindowExceeded
  | Agent_sdk.Types.Unknown _ -> false

let provider_for_vision (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    max_tokens =
      (match provider_cfg.max_tokens with
       | Some _ as configured -> configured
       | None -> Some vision_default_max_tokens)
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.Off
  ; output_schema = None
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }

let message_of_request (req : Va.request) : Agent_sdk.Types.message =
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.text_block req.Va.query
    ; Agent_sdk.Types.image_block
        ~source_type:"base64"
        ~media_type:req.Va.image_media_type
        ~data:(Base64.encode_string req.Va.image_bytes)
        ()
    ]

let vision_runtime_ids () : string list =
  (* Delegate image-capability admission to the RFC-0265 SSOT
     [Runtime_agent.caps_admit_required_modalities] so a runtime surfaced to the
     vision tool is exactly one the dispatch capability gate would admit. Do NOT
     re-derive this from [supports_image_input] / [supports_multimodal_inputs]
     here: the SSOT admits "image" on [supports_image_input] alone, and the
     modality reroute, the capability gate, and this vision pick must share one
     predicate or a vision pick can land on a runtime the gate then rejects. *)
  Runtime_agent.media_reroute_candidates ~exclude:""
  |> List.filter_map (fun (runtime_id, caps) ->
       if Runtime_agent.caps_admit_required_modalities caps [ "image" ]
       then Some runtime_id
       else None)

let first_vision_runtime_id () : (string, string) result =
  match vision_runtime_ids () with
  | id :: _ -> Ok id
  | [] -> Error "no image-capable runtime configured"

(* Per-keeper content-addressed store dir. Phase 2 ingestion (§2.3) will write
   incoming images here under the same path. *)
let vision_store_dir ~keeper_name =
  Filename.concat (Config_dir_resolver.keepers_dir ()) (keeper_name ^ ".vision")

let ok_json text =
  Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "text", `String text ])

(* Default to Runtime_failure: an unclassified error is treated as an internal
   keeper-health fault, not a caller validation or workflow business rule. *)
let err_json ?detail ?(failure_class = Tool_result.Runtime_failure) code =
  let fields =
    [ "ok", `Bool false
    ; "error", `String code
    ; ( "failure_class"
      , `String (Tool_result.tool_failure_class_to_string failure_class) )
    ]
  in
  let fields =
    match detail with
    | Some d -> fields @ [ "detail", `String d ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

let failure_class_of_http_error err =
  if Runtime_attempt_fsm.should_try_next err
  then Tool_result.Transient_error
  else Tool_result.Policy_rejection
;;

let string_member key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let normalize_media_type value =
  String.trim value |> String.lowercase_ascii

let supported_image_media_types =
  [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]

let supported_image_media_type media_type =
  List.mem media_type supported_image_media_types

let supported_image_media_types_csv =
  String.concat ", " supported_image_media_types

let validate_image_size bytes =
  let size = String.length bytes in
  if size <= max_image_bytes then Ok ()
  else
    Error
      (Printf.sprintf
         "image artifact is %d bytes; max allowed is %d bytes"
         size
         max_image_bytes)

let json_member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let media_type_for_request ~bytes args =
  let sniff_media_type bytes =
    let starts prefix =
      let lp = String.length prefix in
      String.length bytes >= lp && String.equal (String.sub bytes 0 lp) prefix
    in
    if starts "\x89PNG" then Ok "image/png"
    else if starts "\xff\xd8\xff" then Ok "image/jpeg"
    else if starts "GIF8" then Ok "image/gif"
    else if
      String.length bytes >= 12
      && String.equal (String.sub bytes 0 4) "RIFF"
      && String.equal (String.sub bytes 8 4) "WEBP"
    then Ok "image/webp"
    else
      Error
        (Printf.sprintf
           "could not identify image media type; expected one of %s"
           supported_image_media_types_csv)
  in
  match json_member_opt "media_type" args with
  | None -> sniff_media_type bytes
  | Some (`String raw) ->
    let media_type = normalize_media_type raw in
    if String.equal media_type "" then Error "media_type must be non-empty"
    else if supported_image_media_type media_type then Ok media_type
    else
      Error
        (Printf.sprintf
           "unsupported image media_type %S; expected one of %s"
           raw
           supported_image_media_types_csv)
  | Some _ -> Error "media_type must be a string"

let ok_or_classified_json (response : Agent_sdk.Types.api_response) =
  let text = Agent_sdk_response.text_of_response response in
  let truncated = truncated_of_stop_reason response.stop_reason in
  match Va.classify ~truncated ~content:text with
  | Ok t -> ok_json t
  | Error Va.Empty_extraction ->
    err_json ~failure_class:Tool_result.Workflow_rejection "empty_extraction"
  | Error Va.Truncated_extraction ->
    err_json ~failure_class:Tool_result.Runtime_failure "truncated_extraction"

let rec run_candidates
    ~complete
    ~timeout_sec
    ~sw
    ~clock
    ~net
    ~messages
    ~last_error
    = function
  | [] ->
    (match last_error with
     | None ->
       err_json
         ~failure_class:Tool_result.Runtime_failure
         ~detail:"no image-capable runtime configured"
         "no_capable_runtime"
     | Some (`Timeout runtime_id) ->
       err_json
         ~failure_class:Tool_result.Transient_error
         ~detail:(Printf.sprintf "runtime %S timed out" runtime_id)
         "timeout"
     | Some (`Provider_error err) ->
       err_json
         ~failure_class:(failure_class_of_http_error err)
         ~detail:(Provider_http_error.to_message err)
         "provider_error"
     | Some (`Runtime_missing runtime_id) ->
       err_json
         ~failure_class:Tool_result.Runtime_failure
         ~detail:(Printf.sprintf "runtime %S not found" runtime_id)
         "no_capable_runtime")
  | runtime_id :: rest ->
    (match Runtime.get_runtime_by_id runtime_id with
     | None ->
       run_candidates ~complete ~timeout_sec ~sw ~clock ~net ~messages
         ~last_error:(Some (`Runtime_missing runtime_id))
         rest
     | Some rt ->
       let config = provider_for_vision rt.Runtime.provider_config in
       (match
          with_timeout ~clock ~timeout_sec (fun () ->
            complete ~sw ~net ?clock:(Some clock) ~config ~messages ())
        with
        | None ->
          run_candidates ~complete ~timeout_sec ~sw ~clock ~net ~messages
            ~last_error:(Some (`Timeout runtime_id))
            rest
        | Some (Error err) when Runtime_attempt_fsm.should_try_next err ->
          run_candidates ~complete ~timeout_sec ~sw ~clock ~net ~messages
            ~last_error:(Some (`Provider_error err))
            rest
        | Some (Error err) ->
          err_json
            ~failure_class:(failure_class_of_http_error err)
            ~detail:(Provider_http_error.to_message err)
            "provider_error"
        | Some (Ok response) -> ok_or_classified_json response))

let handle
    ?(complete = default_complete)
    ?(timeout_sec = default_timeout_sec)
    ?sw
    ?clock
    ?net
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~args
    () =
  match string_member "artifact" args, string_member "query" args with
  | None, _ | _, None ->
    err_json
      ~failure_class:Tool_result.Policy_rejection
      ~detail:"requires string fields: artifact, query"
      "invalid_args"
  | Some handle_str, Some query ->
    (match sw, net, clock with
     | None, _, _ | _, None, _ | _, _, None ->
       err_json
         ~failure_class:Tool_result.Runtime_failure
         "eio_context_unavailable"
     | Some sw, Some net, Some clock ->
       let dir = vision_store_dir ~keeper_name:meta.name in
       (match Store.load ~dir (Store.of_string handle_str) with
        | Error msg ->
          err_json
            ~failure_class:Tool_result.Runtime_failure
            ~detail:msg
            "artifact_load_failed"
        | Ok bytes ->
          (match validate_image_size bytes with
           | Error msg ->
             err_json
               ~failure_class:Tool_result.Policy_rejection
               ~detail:msg
               "image_too_large"
           | Ok () ->
             (match media_type_for_request ~bytes args with
              | Error msg ->
                err_json
                  ~failure_class:Tool_result.Policy_rejection
                  ~detail:msg
                  "invalid_media_type"
              | Ok media_type ->
                (match
                   Va.make_request ~query ~image_media_type:media_type
                     ~image_bytes:bytes
                 with
                 | Error msg ->
                   err_json
                     ~failure_class:Tool_result.Policy_rejection
                     ~detail:msg
                     "invalid_request"
                 | Ok req ->
                   run_candidates
                     ~complete
                     ~timeout_sec
                     ~sw
                     ~clock
                     ~net
                     ~messages:[ message_of_request req ]
                     ~last_error:None
                     (vision_runtime_ids ()))))))
