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
  ; clear_thinking = Some true
  }
  |> Keeper_structured_output_schema.without_response_format

let message_of_request (req : Va.request) : Agent_core.Types.message =
  let query =
    Printf.sprintf
      "Analyze the attached image for this request:\n\
       %s\n\n\
       Return only a JSON object with a non-empty string field named text. When \
       the requested content is not visible, explicitly describe its absence \
       in text; do not invent content to fill the field. Distinguish no visible \
       content from content that is present but unreadable. Do not include \
       markdown fences or prose outside the JSON object."
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

let vision_runtime_candidates ~now
  : (string * Runtime.t * Llm_provider.Provider_config.t) list =
  (* Delegate image-capability admission to the RFC-0265 SSOT
     [Runtime_agent.caps_admit_required_modalities] so a runtime surfaced to the
     vision tool is exactly one the dispatch capability gate would admit. Do NOT
     re-derive this from [supports_image_input] / [supports_multimodal_inputs]
     here: the SSOT admits "image" on [supports_image_input] alone, and the
     modality reroute, the capability gate, and this vision pick must share one
     predicate or a vision pick can land on a runtime the gate then rejects.
     The candidate order is the RFC-0440 set the keeper reroute walks
     ([Runtime_agent.media_candidates] with no lane, which is
     [runtime.media_failover] in declared order). A declared runtime outside
     that list is not offered here: it is the one boot does not validate
     dispatch caps for, and this tool dispatches what it is handed
     (#34823). Only [Agent_core] runtimes
     qualify here because this tool calls the provider itself; an official
     client carries inline images for the reroute but has no provider config.
     The set is held in quota-window order ([Runtime_quota_window.demote_order],
     the order the keeper lane already uses): a candidate whose account answered
     a hard quota rejection moves behind the live ones, so a read does not start
     at the candidate that just said it cannot pay (RFC-0440 §3). *)
  Runtime_agent.media_candidates ~lane:[]
  |> Runtime_quota_window.demote_order ~now ~quota_scope_of:(fun (rt : Runtime.t) ->
       Some (Runtime.quota_scope_of_runtime rt))
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

let vision_runtime_ids ~now : string list =
  List.map (fun (runtime_id, _, _) -> runtime_id) (vision_runtime_candidates ~now)

let first_vision_runtime_id ~now : (string, string) result =
  match vision_runtime_ids ~now with
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

(* AcceptRejected is the caller's own transport wiring refused before dispatch
   (a missing clock, an invalid deadline). Every candidate would refuse the
   same wiring, so this one still ends the walk. *)
let wiring_rejected = function
  | Llm_provider.Http_client.AcceptRejected _ -> true
  | _ -> false

(* Capacity belongs to the selected binding. A later image runtime may admit
   the same pixels under a different request/context ceiling. HTTP 413 states
   that cause directly; arbitrary HTTP 400/422 prose must not infer it. *)
let candidate_capacity_http_error = function
  | Llm_provider.Http_client.HttpError { code = 413; _ }
  | Llm_provider.Http_client.ProviderFailure
      { kind =
          (Llm_provider.Http_client.Request_body_too_large _
          | Llm_provider.Http_client.Context_overflow _)
      ; _
      } -> true
  | _ -> false

(* Every other 4xx is this binding's verdict on this request: a parameter
   range (glm-4.6v refused max_tokens 40960 on 2026-09-07), a media type, a
   key it does not accept (401), a model its plan does not serve (403/404).
   It says nothing about the next candidate, which has its own key and its
   own wire, so this class ends the candidate, not the walk. Transient codes
   (408/409/429) and capacity (413) are classified before it and keep their
   own handling; it still names the failure class once every candidate has
   answered. *)
let candidate_policy_http_error err =
  match err with
  | Llm_provider.Http_client.HttpError { code; _ } ->
    code >= 400
    && code < 500
    && (not (candidate_capacity_http_error err))
    && not (Runtime_attempt_fsm.should_try_next err)
  | _ -> false

let failure_class_of_http_error = function
  | err when wiring_rejected err || candidate_policy_http_error err ->
    Tool_result.Policy_rejection
  | err when candidate_capacity_http_error err -> Tool_result.Runtime_failure
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

type vision_reading =
  { text : string
  ; runtime_id : string
  ; requested_model : string
  ; response_model : string
  }

type vision_outcome =
  | Vo_ok of vision_reading
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

let ok_data (reading : vision_reading) =
  record_vision_analyze_result ~result:"ok" ~reason:"ok";
  (`Assoc
       [ "ok", `Bool true
       ; "text", `String reading.text
       ; "runtime_id", `String reading.runtime_id
       ; "requested_model", `String reading.requested_model
       ; "response_model", `String reading.response_model
       ])

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

let outcome_of_response
    ~runtime_id ~requested_model (response : Agent_core.Types.api_response) =
  (* A length stop is authoritative even when the prefix happens to form
     valid, nonempty JSON. Accepting that prefix would publish a partial
     extraction as success and prevent the next candidate from finishing it. *)
  if truncated_of_stop_reason response.stop_reason then Vo_truncated
  else
  match vision_text_of_response response with
  | Error detail -> Vo_invalid_structured_response detail
  | Ok text ->
    (match Va.classify ~truncated:false ~content:text with
     | Ok text ->
       Vo_ok { text; runtime_id; requested_model; response_model = response.model }
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

type candidate_failure =
  | Candidate_timeout
  | Candidate_provider_error of Llm_provider.Http_client.http_error
  | Candidate_output_limit
  | Candidate_invalid_output of string

(* One walk shrinks the image at most once per distinct edge it is asked
   for. The live fleet declares three distinct caps, so a 4K screenshot costs
   at most two extra scaler runs on top of the first downscale. *)
let shrink_for_edge ~(req : Va.request) ~cache edge =
  match Hashtbl.find_opt cache edge with
  | Some cached -> cached
  | None ->
    let shrunk =
      match
        Keeper_vision_downscale.downscale_with_status
          ~max_dimension:edge
          ~media_type:req.Va.image_media_type
          ~bytes:req.Va.image_bytes
          ()
      with
      | (media_type, bytes), Keeper_vision_downscale.Downscaled _ -> Some (media_type, bytes)
      | ( _
        , ( Keeper_vision_downscale.Unchanged_within_bounds _
          | Keeper_vision_downscale.Unchanged_unknown_dimensions
          | Keeper_vision_downscale.Downscale_fallback_error _ ) ) -> None
    in
    Hashtbl.replace cache edge shrunk;
    shrunk
;;

let longest_edge bytes =
  match Keeper_vision_downscale.detect_dimensions bytes with
  | None -> None
  | Some { Keeper_vision_downscale.width; height } -> Some (max width height)
;;

(* The request this candidate gets: the image as it is when it fits under
   the candidate's cap, a copy shrunk once to the edge the byte ratio
   predicts when it does not, and no request at all when neither fits. The
   client still measures the exact serialized body before dispatch. *)
let fit_request_to_stated_cap ~(req : Va.request) ~cache ~cap_bytes =
  let query_bytes = String.length req.Va.query in
  let min_edge = Env_config_keeper.KeeperVision.max_dimension_floor in
  let plan_for bytes =
    Keeper_vision_cap_fit.plan
      ~cap_bytes
      ~image_bytes:(String.length bytes)
      ~query_bytes
      ~longest_edge:(longest_edge bytes)
      ~min_edge
  in
  match plan_for req.Va.image_bytes with
  | Keeper_vision_cap_fit.Sends_as_is -> Ok req
  | Keeper_vision_cap_fit.Cannot_fit { needed_bytes; cap_bytes } ->
    Error (needed_bytes, cap_bytes)
  | Keeper_vision_cap_fit.Shrink_longest_edge_to edge ->
    (match shrink_for_edge ~req ~cache edge with
     | None ->
       Error
         ( Keeper_vision_cap_fit.needed_bytes
             ~image_bytes:(String.length req.Va.image_bytes)
             ~query_bytes
         , cap_bytes )
     | Some (image_media_type, image_bytes) ->
       (match plan_for image_bytes with
        | Keeper_vision_cap_fit.Sends_as_is ->
          Ok { req with Va.image_media_type; image_bytes }
        | Keeper_vision_cap_fit.Shrink_longest_edge_to _
        | Keeper_vision_cap_fit.Cannot_fit _ ->
          Error
            ( Keeper_vision_cap_fit.needed_bytes
                ~image_bytes:(String.length image_bytes)
                ~query_bytes
            , cap_bytes )))
;;

(* No cap means nothing to fit to. #34163 let a runtime dispatch without a
   caller byte ceiling, which turned [validate_request_body_cap] into an
   [int option] and left this call site reading it as an [int] -- main did not
   compile. Absence is not a number to shrink towards: the request goes as it
   is, and the client still measures the serialized body before dispatch.

   Absence is also the common case, not an edge: 117 of the 155 runtime
   bindings in this workspace state no max-request-body-bytes (2026-09-08). A
   reading that treated [None] as a refusal would have stopped vision on all
   of them. *)
let fit_request_to_cap ~(req : Va.request) ~cache ~cap_bytes =
  match cap_bytes with
  | None -> Ok req
  | Some cap_bytes -> fit_request_to_stated_cap ~req ~cache ~cap_bytes
;;


(* The same kind the client raises when it measures the serialized body,
   so the walk's exhaustion classifies as capacity; the message says the
   number is this walk's prediction, made before any body was serialized. *)
let predicted_size_failure ~actual_bytes ~limit_bytes =
  Llm_provider.Http_client.ProviderFailure
    { kind = Llm_provider.Http_client.Request_body_too_large { actual_bytes; limit_bytes }
    ; message =
        Printf.sprintf
          "predicted request body of %d bytes exceeds the candidate's %d-byte cap; \
           skipped before dispatch"
          actual_bytes
          limit_bytes
    }
;;

(* A 402 states the binding's account cannot pay. The keeper walk records the
   same fact for a typed [PaymentRequired]; the read walk meets it as HTTP and
   records it here so the next read starts elsewhere (RFC-0440 §3). Any answer
   that got through clears an observation on that account. *)
let note_candidate_account ~(runtime : Runtime.t) = function
  | Llm_provider.Http_client.HttpError { code = 402; _ } ->
    Runtime_quota_window.note_observed_exhausted
      ~scope:(Runtime.quota_scope_of_runtime runtime)
  | Llm_provider.Http_client.HttpError _
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.ProviderFailure _
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.ProviderTerminal _ -> ()
;;

let run_candidates_outcome
    ?complete
    ~sw
    ~clock
    ~net
    ~(req : Va.request)
    ~last_error
    ~attempt_index
    candidates
  =
  let cache = Hashtbl.create 4 in
  let rec loop ~last_error ~attempt_index = function
    | [] ->
      (* The walk's outcome is the last candidate's: what ended it. A verdict
         an earlier candidate gave and the walk moved past (a 400, a capacity
         refusal) is not the reason the image went unread, and it is already
         on the candidate counter under that runtime's id. *)
      (match last_error with
       | None -> Vo_no_runtime "no schema-capable image runtime configured"
       | Some Candidate_timeout -> Vo_timeout
       | Some Candidate_output_limit -> Vo_truncated
       | Some (Candidate_invalid_output detail) -> Vo_invalid_structured_response detail
       | Some (Candidate_provider_error err) ->
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
          ~reason:"invalid_request_body_cap";
        Vo_provider
          { failure_class = Tool_result.Runtime_failure
          ; detail = Runtime.request_body_cap_error_to_string error
          }
      | Ok cap_bytes ->
        (match fit_request_to_cap ~req ~cache ~cap_bytes with
         | Error (actual_bytes, limit_bytes) ->
           record_vision_candidate_attempt
             ~runtime_id
             ~result:"skipped"
             ~reason:"image_exceeds_cap";
           (* No call was made, so no backoff and no attempt counted. The
              size failure is kept as the last error so an exhausted walk
              reports why the image went unread. *)
           loop
             ~last_error:
               (Some (Candidate_provider_error (predicted_size_failure ~actual_bytes ~limit_bytes)))
             ~attempt_index
             rest
         | Ok fitted ->
        (match
           Keeper_provider_subcall.complete ?override:complete ~sw ~net ~clock
             ~config ~messages:[ message_of_request fitted ] ()
         with
       | Error (Llm_provider.Http_client.TimeoutError _) ->
            record_vision_candidate_attempt
              ~runtime_id
              ~result:"error"
              ~reason:"timeout";
            continue_with Candidate_timeout
       | Error err ->
            if candidate_capacity_http_error err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"candidate_capacity_error";
              (* Another attempt on this binding cannot change its hard limit;
                 advance without transient-outage backoff or rewriting pixels. *)
              loop
                ~last_error:(Some (Candidate_provider_error err))
                ~attempt_index:(attempt_index + 1)
                rest)
            else if wiring_rejected err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"terminal_provider_error";
              Vo_provider
                { failure_class = failure_class_of_http_error err
                ; detail = Provider_http_error.to_message err
                })
            else if candidate_policy_http_error err
            then (
              note_candidate_account ~runtime:rt err;
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"candidate_policy_error";
              (* The verdict is this binding's; waiting changes nothing about
                 it, so advance without the transient-outage backoff. *)
              loop
                ~last_error:(Some (Candidate_provider_error err))
                ~attempt_index:(attempt_index + 1)
                rest)
            else if Runtime_attempt_fsm.should_try_next err
            then (
              record_vision_candidate_attempt
                ~runtime_id
                ~result:"error"
                ~reason:"transient_provider_error";
              continue_with (Candidate_provider_error err))
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
            Runtime_quota_window.note_succeeded
              ~scope:(Runtime.quota_scope_of_runtime rt);
            (match
               outcome_of_response ~runtime_id ~requested_model:config.model_id response
             with
             | Vo_truncated ->
               record_vision_candidate_attempt
                 ~runtime_id
                 ~result:"error"
                 ~reason:"output_token_limit";
               (* A typed length stop is candidate-local. Keep the same pixels
                  and query, and let the next serializer enforce its own
                  declared ceiling. Equal ceilings are still worth trying:
                  models differ in how much reasoning precedes the answer. *)
               loop
                 ~last_error:(Some Candidate_output_limit)
                 ~attempt_index:(attempt_index + 1)
                 rest
             | Vo_invalid_structured_response detail
               when (match response.Agent_core.Types.stop_reason with
                     | EndTurn | StopSequence | Unknown _ -> true
                     | StopToolUse | MaxTokens | Refusal | ContentFilter
                     | RepetitionTruncation | PauseTurn | Compaction
                     | ContextWindowExceeded | UnmatchedToolCalls -> false) ->
               record_vision_candidate_attempt
                 ~runtime_id
                 ~result:"error"
                 ~reason:"invalid_structured_output";
               (* A finished reply whose JSON broke mid-string is the
                  json_object flake, not a verdict: which backends break
                  escaping differs per model, exactly as token ceilings do
                  (2026-09-12, msx-retro-mania: one broken reply ended the
                  whole vision call and the terminal composition killed the
                  turn). A Refusal or ContentFilter stop is the model
                  answering "no" -- the branch below returns that as the
                  walk's final outcome instead of re-rolling the same
                  pixels elsewhere. The detail names the runtime so an
                  exhausted walk reports who answered. *)
               continue_with
                 (Candidate_invalid_output
                    (Printf.sprintf "%s: %s" runtime_id detail))
             | Vo_invalid_structured_response _ as final ->
               record_vision_candidate_attempt
                 ~runtime_id
                 ~result:"error"
                 ~reason:"invalid_structured_response";
               final
             | Vo_empty ->
               record_vision_candidate_attempt
                 ~runtime_id
                 ~result:"error"
                 ~reason:"empty_extraction";
               continue_with
                 (Candidate_invalid_output
                    (Printf.sprintf "%s: empty extraction" runtime_id))
             | outcome ->
               record_vision_candidate_attempt
                 ~runtime_id
                 ~result:"ok"
                 ~reason:"provider_response";
               outcome)))
  in
  loop ~last_error ~attempt_index candidates

let run_vision
    ?complete
    ?runtime_id
    ?(exclude_runtime_ids = [])
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
              let all_candidates =
                vision_runtime_candidates ~now:(Eio.Time.now clock)
              in
              (* Candidates the caller's own walk already spent this turn. The
                 quota window pushes a candidate that answered a hard rejection
                 behind the live ones but keeps it in the list, so without this
                 the delegation calls the accounts that just refused to pay one
                 more time before the text fallback starts (#34829). *)
              let candidates =
                match exclude_runtime_ids with
                | [] -> all_candidates
                | excluded ->
                  List.filter
                    (fun (id, _, _) -> not (List.mem id excluded))
                    all_candidates
              in
              if List.is_empty candidates && not (List.is_empty all_candidates)
              then
                (* Distinct from "none configured": there are capable runtimes
                   and the walk has already asked all of them. *)
                Vo_no_runtime
                  "every capable image runtime was already attempted in this turn"
              else
              let selected = match runtime_id with
                | None -> Ok candidates
                | Some requested ->
                    let matching = List.filter
                      (fun (id, _, _) -> String.equal id requested) candidates in
                    if List.is_empty matching then
                      Error "requested runtime is not a configured capable image candidate"
                    else Ok matching
              in
              match selected with
              | Error detail -> Vo_invalid_request detail
              | Ok candidates -> run_candidates_outcome
                ?complete
                ~sw
                ~clock
                ~net
                ~req
                ~last_error:None
                ~attempt_index:0
                candidates))
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
    ~effect_disposition:Tool_result.Proven_pre_effect
    (err_json ~failure_class ?detail code)
;;

let execution_of_vision_outcome = function
  | Vo_ok text -> Keeper_tool_execution.success_data (ok_data text)
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

let runtime_id_of_args args =
  match json_member_opt "runtime_id" args with
  | None -> Ok None
  | Some (`String id) when not (String.equal (String.trim id) "") -> Ok (Some id)
  | Some _ -> Error "runtime_id must be a non-empty configured runtime identifier"

let handle_with_outcome
    ?complete
    ?sw
    ?clock
    ?net
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~args
    () =
  match string_member "artifact" args, string_member "query" args, runtime_id_of_args args with
  | _, _, Error detail ->
      failed ~failure_class:Tool_result.Policy_rejection ~detail "invalid_args"
  | None, _, _ | _, None, _ ->
    failed
      ~failure_class:Tool_result.Policy_rejection
      ~detail:"requires string fields: artifact, query"
      "invalid_args"
  | Some handle_str, Some query, Ok runtime_id ->
    (match sw, net, clock with
     | None, _, _ | _, None, _ | _, _, None ->
       failed
         ~failure_class:Tool_result.Runtime_failure
         "eio_context_unavailable"
     | Some sw, Some net, Some clock ->
       let dir = vision_store_dir ~keeper_name:meta.name in
         (match load_artifact ~dir (Store.of_string handle_str) with
        | Error error ->
          let failure_class, code, recovery = match error with
            | Store.Malformed_handle _ -> Tool_result.Policy_rejection,
                "invalid_artifact", "Copy the exact artifact returned by the image-producing tool."
            | Store.Missing_artifact _ -> Tool_result.Workflow_rejection,
                "artifact_not_found", "Observe again and use the artifact returned for this Keeper."
            | Store.Hash_mismatch _ | Store.Read_failed _ -> Tool_result.Runtime_failure,
                "artifact_load_failed", "The stored image could not be read with verified integrity." in
          failed
            ~failure_class
            ~detail:(Store.load_error_to_string error ^ " " ^ recovery)
            code
        | Ok bytes ->
          (match validate_image_size bytes with
             | Error msg ->
               failed
                 ~failure_class:Tool_result.Runtime_failure
                 ~detail:msg
                 "image_too_large"
           | Ok () ->
             (match media_type_for_request ~bytes args with
              | Error msg ->
                failed
                  ~failure_class:Tool_result.Policy_rejection
                  ~detail:msg
                  "invalid_media_type"
              | Ok media_type ->
                run_vision
                  ?complete
                  ?runtime_id
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
