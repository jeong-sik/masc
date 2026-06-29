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

let valid_timeout_sec timeout_sec =
  Float.is_finite timeout_sec && timeout_sec > 0.0

(* One-shot vision read: shorter than a full keeper turn. *)
let default_timeout_sec = 120.0

(* Thinking is forced off (below), so the budget only needs room for the answer;
   keep it well above the 64-token point where the 2026-06-25 gemma4 reply
   truncated entirely into the thinking phase. *)
let vision_default_max_tokens = 1024

let max_image_bytes () = Env_config_keeper.KeeperVision.max_image_bytes ()

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
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
  |> Keeper_structured_output_schema.apply_to_provider_config
       Keeper_structured_output_schema.vision_analyze_output_schema

let vision_schema_supported provider_cfg =
  Keeper_structured_output_schema.provider_config_accepts_schema
    Keeper_structured_output_schema.vision_analyze_output_schema
    provider_cfg

let message_of_request (req : Va.request) : Agent_sdk.Types.message =
  let query =
    Printf.sprintf
      "Analyze the attached image for this request:\n\
       %s\n\n\
       Return only a JSON object with a non-empty string field named text. Do \
       not include markdown fences or prose outside the JSON object."
      req.Va.query
  in
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.text_block query
    ; Agent_sdk.Types.image_block
        ~source_type:Agent_sdk.Types.Base64
        ~media_type:req.Va.image_media_type
        ~data:(Base64.encode_string req.Va.image_bytes)
        ()
    ]

let vision_runtime_candidates () : (string * Runtime.t) list =
  (* Delegate image-capability admission to the RFC-0265 SSOT
     [Runtime_agent.caps_admit_required_modalities] so a runtime surfaced to the
     vision tool is exactly one the dispatch capability gate would admit. Do NOT
     re-derive this from [supports_image_input] / [supports_multimodal_inputs]
     here: the SSOT admits "image" on [supports_image_input] alone, and the
     modality reroute, the capability gate, and this vision pick must share one
     predicate or a vision pick can land on a runtime the gate then rejects. *)
  let runtimes, media_failover = Runtime.runtimes_and_media_failover () in
  let by_id id =
    List.find_opt (fun (rt : Runtime.t) -> String.equal rt.Runtime.id id) runtimes
  in
  let from_failover = List.filter_map by_id media_failover in
  let rest =
    List.filter
      (fun (rt : Runtime.t) -> not (List.mem rt.Runtime.id media_failover))
      runtimes
  in
  from_failover @ rest
  |> List.filter_map (fun (rt : Runtime.t) ->
       let caps = Runtime_agent.input_capabilities_of_runtime rt in
       if Runtime_agent.caps_admit_required_modalities caps [ "image" ]
       then
         if vision_schema_supported rt.Runtime.provider_config
         then Some (rt.Runtime.id, rt)
         else (
           Log.Keeper.warn
             "vision runtime skipped runtime=%s provider=%s: provider does not support native structured output"
             rt.Runtime.id
             rt.Runtime.provider_config.Llm_provider.Provider_config.model_id;
           None)
       else None)

let vision_runtime_ids () : string list =
  List.map fst (vision_runtime_candidates ())

let first_vision_runtime_id () : (string, string) result =
  match vision_runtime_ids () with
  | id :: _ -> Ok id
  | [] -> Error "no schema-capable image runtime configured"

(* Per-keeper content-addressed store dir. Phase 2 ingestion (§2.3) will write
   incoming images here under the same path. *)
let vision_store_dir ~keeper_name =
  Filename.concat (Config_dir_resolver.keepers_dir ()) (keeper_name ^ ".vision")

let store_artifact ~dir bytes =
  Eio_guard.run_in_systhread (fun () -> Store.store ~dir bytes)

let load_artifact ~dir handle =
  Eio_guard.run_in_systhread (fun () -> Store.load ~dir handle)

let record_vision_analyze_result ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionAnalyze)
    ~labels:[ "result", result; "reason", reason ]
    ()
;;

let record_vision_candidate_attempt ~runtime_id ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionCandidateAttempts)
    ~labels:[ "runtime_id", runtime_id; "result", result; "reason", reason ]
    ()
;;

let ok_json text =
  record_vision_analyze_result ~result:"ok" ~reason:"ok";
  Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "text", `String text ])

(* Default to Runtime_failure: an unclassified error is treated as an internal
   keeper-health fault, not a caller validation or workflow business rule. *)
let err_json ?detail ?(failure_class = Tool_result.Runtime_failure) code =
  record_vision_analyze_result ~result:"error" ~reason:code;
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

let terminal_policy_http_error = function
  | Llm_provider.Http_client.AcceptRejected _ -> true
  | Llm_provider.Http_client.HttpError { code; _ } -> code = 400 || code = 422
  | _ -> false

let failure_class_of_http_error = function
  | err when terminal_policy_http_error err -> Tool_result.Policy_rejection
  | err when Runtime_attempt_fsm.should_try_next err -> Tool_result.Transient_error
  | _ -> Tool_result.Runtime_failure

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

let validate_media_type raw =
  let media_type = normalize_media_type raw in
  if String.equal media_type "" then Error "media_type must be non-empty"
  else if supported_image_media_type media_type then Ok media_type
  else
    Error
      (Printf.sprintf
         "unsupported image media_type %S; expected one of %s"
         raw
         supported_image_media_types_csv)

let validate_image_size bytes =
  let size = String.length bytes in
  let max_image_bytes = max_image_bytes () in
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
  | Some (`String raw) -> validate_media_type raw
  | Some _ -> Error "media_type must be a string"

type vision_outcome =
  | Vo_ok of string
  | Vo_invalid_request of string
  | Vo_no_runtime of string
  | Vo_timeout
  | Vo_provider of
      { failure_class : Tool_result.tool_failure_class
      ; detail : string
      }
  | Vo_empty
  | Vo_truncated

let vision_text_of_response (response : Agent_sdk.Types.api_response) =
  let raw = String.trim (Agent_sdk_response.text_of_response response) in
  try
    match Yojson.Safe.from_string raw with
    | `Assoc fields ->
      (match List.assoc_opt "text" fields with
       | Some (`String text) -> String.trim text
       | Some _
       | None -> "")
    | _ -> ""
  with Yojson.Json_error _ -> ""
;;

let ok_or_classified_json (response : Agent_sdk.Types.api_response) =
  let text = vision_text_of_response response in
  let truncated = truncated_of_stop_reason response.stop_reason in
  match Va.classify ~truncated ~content:text with
  | Ok t -> ok_json t
  | Error Va.Empty_extraction ->
    err_json ~failure_class:Tool_result.Workflow_rejection "empty_extraction"
  | Error Va.Truncated_extraction ->
    err_json ~failure_class:Tool_result.Runtime_failure "truncated_extraction"

let outcome_of_response (response : Agent_sdk.Types.api_response) =
  let text = vision_text_of_response response in
  let truncated = truncated_of_stop_reason response.stop_reason in
  match Va.classify ~truncated ~content:text with
  | Ok t -> Vo_ok t
  | Error Va.Empty_extraction -> Vo_empty
  | Error Va.Truncated_extraction -> Vo_truncated

let remaining_timeout_sec ~clock ~deadline =
  let remaining = deadline -. Eio.Time.now clock in
  if remaining <= 0.0 then None else Some remaining

let bounded_exponential_backoff ~base ~max_backoff ~attempt_index =
  let rec loop remaining delay =
    if remaining <= 0 || delay >= max_backoff
    then Float.min delay max_backoff
    else if delay >= max_backoff /. 2.0
    then max_backoff
    else loop (remaining - 1) (delay *. 2.0)
  in
  loop attempt_index base
;;

let candidate_backoff_sec ~attempt_index =
  let base = Env_config_keeper.KeeperVision.candidate_backoff_base_sec () in
  let max_backoff = Env_config_keeper.KeeperVision.candidate_backoff_max_sec () in
  if base <= 0.0 || max_backoff <= 0.0
  then 0.0
  else bounded_exponential_backoff ~base ~max_backoff ~attempt_index
;;

let sleep_before_next_candidate ~clock ~deadline ~attempt_index =
  let delay = candidate_backoff_sec ~attempt_index in
  match remaining_timeout_sec ~clock ~deadline with
  | Some remaining when delay > 0.0 ->
    Eio.Time.sleep clock (Float.min delay remaining)
  | Some _ | None -> ()
;;

let run_candidates
    ~complete
    ~deadline
    ~sw
    ~clock
    ~net
    ~messages
    ~last_error
    ~attempt_index
    candidates
  =
  let rec loop ~last_error ~attempt_index = function
    | [] ->
      (match last_error with
       | None ->
         err_json
           ~failure_class:Tool_result.Runtime_failure
           ~detail:"no schema-capable image runtime configured"
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
           "provider_error")
    | (runtime_id, rt) :: rest ->
      let continue_with last_error =
        (if not (List.is_empty rest)
         then sleep_before_next_candidate ~clock ~deadline ~attempt_index);
        loop
          ~last_error:(Some last_error)
          ~attempt_index:(attempt_index + 1)
          rest
      in
      (match remaining_timeout_sec ~clock ~deadline with
       | None ->
         let last_error =
           match last_error with
           | Some _ as existing -> existing
           | None -> Some (`Timeout runtime_id)
         in
         loop ~last_error ~attempt_index []
       | Some timeout_sec ->
         let config = provider_for_vision rt.Runtime.provider_config in
         (match
            with_timeout ~clock ~timeout_sec (fun () ->
              complete ~sw ~net ?clock:(Some clock) ~config ~messages ())
          with
          | None ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"error"
              ~reason:"timeout";
            continue_with (`Timeout runtime_id)
          | Some (Error err) ->
            if terminal_policy_http_error err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"terminal_provider_error";
              err_json
                ~failure_class:(failure_class_of_http_error err)
                ~detail:(Provider_http_error.to_message err)
                "provider_error")
            else if Runtime_attempt_fsm.should_try_next err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"transient_provider_error";
              continue_with (`Provider_error err))
            else (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"runtime_provider_error";
              err_json
                ~failure_class:(failure_class_of_http_error err)
                ~detail:(Provider_http_error.to_message err)
                "provider_error")
          | Some (Ok response) ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"ok"
              ~reason:"provider_response";
            ok_or_classified_json response))
  in
  loop ~last_error ~attempt_index candidates

let run_candidates_outcome
    ~complete
    ~deadline
    ~sw
    ~clock
    ~net
    ~messages
    ~last_error
    ~attempt_index
    candidates
  =
  let rec loop ~last_error ~attempt_index = function
    | [] ->
      (match last_error with
       | None -> Vo_no_runtime "no schema-capable image runtime configured"
       | Some (`Timeout _runtime_id) -> Vo_timeout
       | Some (`Provider_error err) ->
         Vo_provider
           { failure_class = failure_class_of_http_error err
           ; detail = Provider_http_error.to_message err
           })
    | (runtime_id, rt) :: rest ->
      let continue_with last_error =
        (if not (List.is_empty rest)
         then sleep_before_next_candidate ~clock ~deadline ~attempt_index);
        loop
          ~last_error:(Some last_error)
          ~attempt_index:(attempt_index + 1)
          rest
      in
      (match remaining_timeout_sec ~clock ~deadline with
       | None ->
         let last_error =
           match last_error with
           | Some _ as existing -> existing
           | None -> Some (`Timeout runtime_id)
         in
         loop ~last_error ~attempt_index []
       | Some timeout_sec ->
         let config = provider_for_vision rt.Runtime.provider_config in
         (match
            with_timeout ~clock ~timeout_sec (fun () ->
              complete ~sw ~net ?clock:(Some clock) ~config ~messages ())
          with
          | None ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"error"
              ~reason:"timeout";
            continue_with (`Timeout runtime_id)
          | Some (Error err) ->
            if terminal_policy_http_error err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"terminal_provider_error";
              Vo_provider
                { failure_class = failure_class_of_http_error err
                ; detail = Provider_http_error.to_message err
                })
            else if Runtime_attempt_fsm.should_try_next err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"transient_provider_error";
              continue_with (`Provider_error err))
            else (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"runtime_provider_error";
              Vo_provider
                { failure_class = failure_class_of_http_error err
                ; detail = Provider_http_error.to_message err
                })
          | Some (Ok response) ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"ok"
              ~reason:"provider_response";
            outcome_of_response response))
  in
  loop ~last_error ~attempt_index candidates

let run_vision
    ?(complete = default_complete)
    ?(timeout_sec = default_timeout_sec)
    ~sw
    ~clock
    ~net
    ~query
    ~media_type
    ~bytes
    () =
  try
    if not (valid_timeout_sec timeout_sec)
    then
      Vo_provider
        { failure_class = Tool_result.Runtime_failure
        ; detail = "timeout_sec must be finite and > 0"
        }
    else (
      match validate_image_size bytes with
      | Error msg -> Vo_invalid_request msg
      | Ok () ->
        (match validate_media_type media_type with
         | Error msg -> Vo_invalid_request msg
         | Ok media_type ->
           (match
              Va.make_request ~query ~image_media_type:media_type
                ~image_bytes:bytes
            with
            | Error msg -> Vo_invalid_request msg
            | Ok req ->
              run_candidates_outcome
                ~complete
                ~deadline:(Eio.Time.now clock +. timeout_sec)
                ~sw
                ~clock
                ~net
                ~messages:[ message_of_request req ]
                ~last_error:None
                ~attempt_index:0
                (vision_runtime_candidates ()))))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _exn ->
    Vo_provider
      { failure_class = Tool_result.Runtime_failure
      ; detail = "vision sub-call raised"
      }

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
       if not (valid_timeout_sec timeout_sec)
       then
         err_json
           ~failure_class:Tool_result.Runtime_failure
           ~detail:"timeout_sec must be finite and > 0"
           "invalid_timeout"
       else
         let dir = vision_store_dir ~keeper_name:meta.name in
         (match load_artifact ~dir (Store.of_string handle_str) with
        | Error msg ->
          err_json
            ~failure_class:Tool_result.Runtime_failure
            ~detail:msg
            "artifact_load_failed"
        | Ok bytes ->
          (match validate_image_size bytes with
             | Error msg ->
               err_json
                 ~failure_class:Tool_result.Runtime_failure
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
                     ~deadline:(Eio.Time.now clock +. timeout_sec)
                     ~sw
                     ~clock
                     ~net
                     ~messages:[ message_of_request req ]
                     ~last_error:None
                     ~attempt_index:0
                     (vision_runtime_candidates ()))))))
