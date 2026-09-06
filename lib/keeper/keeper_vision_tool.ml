module Va = Multimodal.Vision_analyze
module Store = Multimodal.Vision_artifact_store

type complete_fn = Keeper_provider_subcall.complete_fn

(* The media_failover vision fleet is entirely /v1 "none" thinking-control
   lanes — reasoning-capable models with no wire field to disable thinking.
   Requesting enable_thinking=false there is fail-closed by the agent_core
   guard (Disable_not_encodable), which broke all image analysis (2026-08).
   So we leave thinking uncontrolled (enable_thinking=None below — the guard
   admits it) and rely on clear_thinking/preserve_thinking to keep the reply
   clean; on /v1 the model's reasoning lands in a separate response field and
   never enters the JSON content. The budget must cover the answer PLUS any
   reasoning the model spends first, since that phase can no longer be
   suppressed; truncated_of_stop_reason still flags a MaxTokens cut. The value
   is the [Env_config_keeper.KeeperVision.max_output_tokens] knob — one /v1 pool
   shared by reasoning and answer, defaulting generous so reasoning cannot
   truncate the reply the way the former 4096 did (2026-08-27 MiniMax M3). *)
let vision_default_max_tokens () = Env_config_keeper.KeeperVision.max_output_tokens ()

let max_image_bytes () = Env_config_keeper.KeeperVision.max_image_bytes ()

let truncated_of_stop_reason : Agent_core.Types.stop_reason -> bool = function
  | Agent_core.Types.MaxTokens -> true
  (* ContentFilter is a policy terminal like Refusal, not a length cut.
     RepetitionTruncation is a provider repetition guard, not token-budget
     exhaustion; classifying it as truncated would prescribe the wrong
     larger-budget remediation.
     UnmatchedToolCalls is AGENT_CORE's internal fail-closed tool-turn shape;
     vision runs with tool_choice = None so it cannot legitimately occur,
     and it carries no partial-extraction signal either way. *)
  | Agent_core.Types.EndTurn
  | Agent_core.Types.StopToolUse
  | Agent_core.Types.StopSequence
  | Agent_core.Types.Refusal
  | Agent_core.Types.ContentFilter
  | Agent_core.Types.RepetitionTruncation
  | Agent_core.Types.PauseTurn
  | Agent_core.Types.Compaction
  | Agent_core.Types.ContextWindowExceeded
  | Agent_core.Types.UnmatchedToolCalls
  | Agent_core.Types.Unknown _ -> false

let provider_for_vision (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    max_tokens =
      (match provider_cfg.max_tokens with
       | Some _ as configured -> configured
       | None -> Some (vision_default_max_tokens ()))
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; enable_thinking = None
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
  |> Keeper_structured_output_schema.without_response_format

let message_of_request (req : Va.request) : Agent_core.Types.message =
  let query =
    Printf.sprintf
      "Analyze the attached image for this request:\n\
       %s\n\n\
       Return only a JSON object with a non-empty string field named text. Do \
       not include markdown fences or prose outside the JSON object."
      req.Va.query
  in
  Agent_core.Types.make_message
    ~role:Agent_core.Types.User
    [ Agent_core.Types.text_block query
    ; Agent_core.Types.image_block
        ~source_type:Agent_core.Types.Base64
        ~media_type:req.Va.image_media_type
        ~data:(Base64.encode_string req.Va.image_bytes)
        ()
    ]

let vision_runtime_candidates ()
  : (string * Runtime.t * Llm_provider.Provider_config.t) list =
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
       match rt.Runtime.execution with
       | Runtime_execution.Codex_app_server _
       | Runtime_execution.Claude_code _
       | Runtime_execution.Antigravity_cli _ -> None
       | Runtime_execution.Agent_core provider_config ->
         let caps = Runtime_agent.input_capabilities_of_runtime rt in
         if Runtime_agent.caps_admit_required_modalities caps [ "image" ]
         then Some (rt.Runtime.id, rt, provider_config)
         else None)

let vision_runtime_ids () : string list =
  List.map (fun (runtime_id, _, _) -> runtime_id) (vision_runtime_candidates ())

let first_vision_runtime_id () : (string, string) result =
  match vision_runtime_ids () with
  | id :: _ -> Ok id
  | [] -> Error "no image-capable runtime configured"

(* Per-keeper content-addressed store dir. Phase 2 ingestion (§2.3) will write
   incoming images here under the same path. *)
let vision_store_dir ~keeper_name =
  Filename.concat (Config_dir_resolver.keepers_dir ()) (keeper_name ^ ".vision")

let store_artifact ~dir bytes =
  Eio_guard.run_in_systhread ~label:"vision-artifact-store" (fun () -> Store.store ~dir bytes)

let load_artifact ~dir handle =
  Eio_guard.run_in_systhread ~label:"vision-artifact-load" (fun () -> Store.load ~dir handle)

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
  | err when Runtime_attempt_fsm.should_try_next err -> Tool_result.Dependency_unavailable
  | _ -> Tool_result.Runtime_failure

let string_member key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

let normalize_media_type value =
  String.trim value |> String.lowercase_ascii

(* The downscaler's closed type is the one list of what a vision call may
   carry: a type it cannot read would go to the provider at full size. *)
let supported_image_media_types =
  List.map
    Keeper_vision_downscale.media_type_to_string
    Keeper_vision_downscale.all_media_types

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

(* Magic-byte identification, shared so the TUI composer and this tool agree on
   what counts as an image. Two copies of a byte-prefix table drift the moment
   one side learns a format the other does not. *)
let sniff_image_media_type bytes =
  let starts prefix =
    let lp = String.length prefix in
    String.length bytes >= lp && String.equal (String.sub bytes 0 lp) prefix
  in
  let named media_type = Ok (Keeper_vision_downscale.media_type_to_string media_type) in
  if starts "\x89PNG" then named Keeper_vision_downscale.Png
  else if starts "\xff\xd8\xff" then named Keeper_vision_downscale.Jpeg
  else if starts "GIF8" then named Keeper_vision_downscale.Gif
  else if
    String.length bytes >= 12
    && String.equal (String.sub bytes 0 4) "RIFF"
    && String.equal (String.sub bytes 8 4) "WEBP"
  then named Keeper_vision_downscale.Webp
  else
    Error
      (Printf.sprintf
         "could not identify image media type; expected one of %s"
         supported_image_media_types_csv)
;;

let media_type_for_request ~bytes args =
  match json_member_opt "media_type" args with
  | None -> sniff_image_media_type bytes
  | Some (`String raw) -> validate_media_type raw
  | Some _ -> Error "media_type must be a string"

type vision_outcome =
  | Vo_ok of string
  | Vo_invalid_request of string
  | Vo_no_runtime of string
  | Vo_timeout
  | Vo_invalid_structured_response of string
  | Vo_provider of
      { failure_class : Tool_result.tool_failure_class
      ; detail : string
      }
  | Vo_empty
  | Vo_truncated

let vision_text_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "text" fields with
     | Some (`String text) -> Ok (String.trim text)
     | Some _ -> Error "vision response field \"text\" must be a string"
     | None -> Error "vision response missing required field \"text\"")
  | _ -> Error "vision response must be a JSON object"
;;

let vision_text_of_response (response : Agent_core.Types.api_response) =
  match
    (Agent_core.Structured.response_json_extractor ()) response
  with
  | Ok json -> vision_text_of_json json
  | Error msg -> Error ("vision response is not valid structured JSON: " ^ msg)
;;

let outcome_of_response (response : Agent_core.Types.api_response) =
  match vision_text_of_response response with
  | Error detail ->
    (* A reply the model truncated mid-JSON fails the structured parse before
       its text can be read, so vision_text_of_response reports a parse error
       even though the cause is a MaxTokens cut. Consult the stop reason first:
       a length cut is truncation (remediation: a larger budget), which we
       report as such instead of a malformed-reply parser fault that would
       misdirect the operator. A parse error with a non-length stop reason is
       a genuine structured failure. *)
    if truncated_of_stop_reason response.stop_reason then Vo_truncated
    else Vo_invalid_structured_response detail
  | Ok text ->
    let truncated = truncated_of_stop_reason response.stop_reason in
    (match Va.classify ~truncated ~content:text with
     | Ok t -> Vo_ok t
     | Error Va.Empty_extraction -> Vo_empty
     | Error Va.Truncated_extraction -> Vo_truncated)

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

let sleep_before_next_candidate ~clock ~attempt_index =
  let delay = candidate_backoff_sec ~attempt_index in
  if delay > 0.0 then Eio.Time.sleep clock delay
;;

let run_candidates_outcome
    ?complete
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
    | (runtime_id, rt, provider_config) :: rest ->
      let continue_with last_error =
        (if not (List.is_empty rest)
         then sleep_before_next_candidate ~clock ~attempt_index);
        loop
          ~last_error:(Some last_error)
          ~attempt_index:(attempt_index + 1)
          rest
      in
      let config = provider_for_vision provider_config in
      match Runtime.validate_request_body_cap ~runtime_id config with
      | Error error ->
        record_vision_candidate_attempt
          ~runtime_id
          ~result:"error"
          ~reason:"missing_request_body_cap";
        Vo_provider
          { failure_class = Tool_result.Runtime_failure
          ; detail = Runtime.request_body_cap_error_to_string error
          }
      | Ok _ ->
        (match
           Keeper_provider_subcall.complete ?override:complete ~sw ~net ~clock
             ~config ~messages ()
         with
       | Error (Llm_provider.Http_client.TimeoutError _) ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"error"
              ~reason:"timeout";
            continue_with (`Timeout runtime_id)
       | Error err ->
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
       | Ok response ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"ok"
              ~reason:"provider_response";
            outcome_of_response response)
  in
  loop ~last_error ~attempt_index candidates

let run_vision
    ?complete
    ~sw
    ~clock
    ~net
    ~query
    ~media_type
    ~bytes
    () =
  try
    match validate_image_size bytes with
      | Error msg -> Vo_invalid_request msg
      | Ok () ->
        (match validate_media_type media_type with
         | Error msg -> Vo_invalid_request msg
         | Ok media_type ->
           let media_type, bytes =
             Keeper_vision_downscale.downscale_if_needed ~media_type ~bytes ()
           in
           (match
              Va.make_request ~query ~image_media_type:media_type
                ~image_bytes:bytes
            with
            | Error msg -> Vo_invalid_request msg
            | Ok req ->
              run_candidates_outcome
                ?complete
                ~sw
                ~clock
                ~net
                ~messages:[ message_of_request req ]
                ~last_error:None
                ~attempt_index:0
                (vision_runtime_candidates ())))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _exn ->
    Vo_provider
      { failure_class = Tool_result.Runtime_failure
      ; detail = "vision sub-call raised"
      }

(* The [Vo_provider] arm below binds its class once and hands the same value
   to the result and to the payload. The other arms wrote theirs twice, so a
   change to one spelling left the other saying something else. *)
let failed ~failure_class ?detail code =
  Keeper_tool_execution.failure
    ~class_:failure_class
    (err_json ~failure_class ?detail code)
;;

let execution_of_vision_outcome = function
  | Vo_ok text -> Keeper_tool_execution.success (ok_json text)
  | Vo_invalid_request detail ->
    failed ~failure_class:Tool_result.Policy_rejection ~detail "invalid_request"
  | Vo_no_runtime detail ->
    failed ~failure_class:Tool_result.Runtime_failure ~detail "no_capable_runtime"
  | Vo_timeout -> failed ~failure_class:Tool_result.Dependency_unavailable "timeout"
  | Vo_invalid_structured_response detail ->
    failed
      ~failure_class:Tool_result.Runtime_failure
      ~detail
      "invalid_structured_response"
  | Vo_provider { failure_class; detail } ->
    failed ~failure_class ~detail "provider_error"
  | Vo_empty ->
    failed ~failure_class:Tool_result.Workflow_rejection "empty_extraction"
  | Vo_truncated ->
    failed ~failure_class:Tool_result.Runtime_failure "truncated_extraction"
;;

let handle_with_outcome
    ?complete
    ?sw
    ?clock
    ?net
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~args
    () =
  match string_member "artifact" args, string_member "query" args with
  | None, _ | _, None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (err_json
         ~failure_class:Tool_result.Policy_rejection
         ~detail:"requires string fields: artifact, query"
         "invalid_args")
  | Some handle_str, Some query ->
    (match sw, net, clock with
     | None, _, _ | _, None, _ | _, _, None ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Runtime_failure
         (err_json
            ~failure_class:Tool_result.Runtime_failure
            "eio_context_unavailable")
     | Some sw, Some net, Some clock ->
       let dir = vision_store_dir ~keeper_name:meta.name in
         (match load_artifact ~dir (Store.of_string handle_str) with
        | Error msg ->
          Keeper_tool_execution.failure
            ~class_:Tool_result.Runtime_failure
            (err_json
               ~failure_class:Tool_result.Runtime_failure
               ~detail:msg
               "artifact_load_failed")
        | Ok bytes ->
          (match validate_image_size bytes with
             | Error msg ->
               Keeper_tool_execution.failure
                 ~class_:Tool_result.Runtime_failure
                 (err_json
                    ~failure_class:Tool_result.Runtime_failure
                    ~detail:msg
                    "image_too_large")
           | Ok () ->
             (match media_type_for_request ~bytes args with
              | Error msg ->
                Keeper_tool_execution.failure
                  ~class_:Tool_result.Policy_rejection
                  (err_json
                     ~failure_class:Tool_result.Policy_rejection
                     ~detail:msg
                     "invalid_media_type")
              | Ok media_type ->
                run_vision
                  ?complete
                  ~sw
                  ~clock
                  ~net
                  ~query
                  ~media_type
                  ~bytes
                  ()
                |> execution_of_vision_outcome))))

let handle ?complete ?sw ?clock ?net ~meta ~args () =
  (handle_with_outcome
     ?complete
     ?sw
     ?clock
     ?net
     ~meta
     ~args
     ()).raw_output
