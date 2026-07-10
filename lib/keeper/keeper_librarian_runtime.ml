(** Runtime adapter for Memory OS librarian extraction. *)

(* Cap on the librarian extraction output, applied as
   [min provider_cfg.max_tokens (librarian_max_tokens ())] at the complete call
   (see [extract] below). The previous fixed cap of 1024 truncated episode
   JSON mid-object whenever the summary plus facts exceeded ~1024 output
   tokens, surfacing as "invalid_json: Unexpected end of input" every turn.
   4096 covers realistic episode payloads while staying well under the
   JSON-capable model context budget; tunable via
   [MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_TOKENS] (floor 1). *)
let librarian_max_tokens () = Env_config.KeeperMemoryOs.librarian_max_tokens ()

(* Memory extraction runs against a JSON-capable model with a long context
   window and is not constrained by the generic inference API budget (30s).
   600s aligns with the keeper turn budget so that provider cold starts or
   model loading do not silently drop episodes. *)
let librarian_default_timeout_sec =
  Env_config.KeeperMemoryOs.librarian_timeout_sec_default
;;

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let default_complete ~sw ~net ?clock ~config ~messages () =
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()
;;

let enabled () =
  (* Default on: a keeper without conversation ingestion is the pathology
     the Memory OS exists to fix (2026-06-12 diagnosis, issue #20909).
     The env var stays as the kill switch. *)
  Env_config.KeeperMemoryOs.librarian_enabled ()
;;

(* Librarian extraction cadence (per keeper).

   Memory extraction runs once per keeper turn by default, which means every
   keeper issues a provider-backed LLM extraction every turn against a shared
   inference pool. That per-turn LLM load — not the lack of a concurrency gate —
   is the dominant source of the librarian empty-response saturation observed
   2026-06-16 (HTTP 200 empty body under pool contention). The fleet-wide
   [provider_slot] only masked it by dropping (skip) most attempts.

   Extract once every [cadence_turns ()] turns per keeper instead. The extraction
   window ([max_messages ()], default 24) already spans several recent turns, so
   batching over a small cadence is a deferral, not a loss: a skipped turn's
   messages are still in the window at the next due turn. Cadence must stay small
   relative to [max_messages ()] or early turns can scroll out of the window.

   Tradeoff: recall in turns between extractions sees slightly staler memory
   (a turn's freshly-produced fact is not extracted until the next due turn).
   Memory extraction is best-effort, so this eventual-consistency is acceptable.

   Set MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS=1 to restore per-turn
   extraction (the previous behavior). *)
let cadence_turns () =
  Env_config.KeeperMemoryOs.librarian_cadence_turns ()
;;

type cadence_decision =
  | Due
  | Not_due of { turns_remaining : int }

(* The Keeper timeline turn id is the durable cadence clock. It starts at one;
   zero is the explicit pre-turn state and is also due. No process-local table
   is involved, so restart,
   BasePath multiplexing, detached execution order, and admission failure cannot
   change a turn's decision. *)
let cadence_decision_for_keeper_turn ~cadence ~keeper_turn =
  if cadence <= 1 || keeper_turn <= 1
  then Due
  else
    let offset = (keeper_turn - 1) mod cadence in
    if offset = 0
    then Due
    else Not_due { turns_remaining = cadence - offset }
;;

type librarian_admission_decision =
  | Admission_disabled
  | Admission_not_due of { turns_remaining : int }
  | Admission_due

let decide_librarian_admission ~keeper_turn =
  if not (enabled ())
  then Admission_disabled
  else
    match
      cadence_decision_for_keeper_turn
        ~cadence:(cadence_turns ())
        ~keeper_turn
    with
    | Due -> Admission_due
    | Not_due { turns_remaining } -> Admission_not_due { turns_remaining }
;;

let librarian_admission_decision_to_json = function
  | Admission_disabled -> `Assoc [ "kind", `String "disabled" ]
  | Admission_due -> `Assoc [ "kind", `String "due" ]
  | Admission_not_due { turns_remaining } ->
    `Assoc
      [ "kind", `String "not_due"
      ; "turns_remaining", `Int turns_remaining
      ]
;;

let librarian_admission_decision_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "disabled") -> Ok Admission_disabled
     | Some (`String "due") -> Ok Admission_due
     | Some (`String "not_due") ->
       (match List.assoc_opt "turns_remaining" fields with
        | Some (`Int turns_remaining) when turns_remaining > 0 ->
          Ok (Admission_not_due { turns_remaining })
        | Some _ -> Error "librarian admission turns_remaining must be positive"
        | None -> Error "librarian admission missing turns_remaining")
     | Some (`String kind) ->
       Error (Printf.sprintf "unknown librarian admission kind: %s" kind)
     | Some _ -> Error "librarian admission kind must be a string"
     | None -> Error "librarian admission missing kind")
  | _ -> Error "librarian admission decision must be an object"
;;

let max_messages () =
  Env_config.KeeperMemoryOs.librarian_max_messages ()
;;

(* Scale the prompt window by the cadence so skipped turns stay visible until
   the next due extraction. Without this, a tool-heavy skipped turn can scroll
   out of the per-turn cap before its first successful extraction. *)
let prompt_max_messages () =
  let per_turn = max_messages () in
  let cadence = cadence_turns () in
  if per_turn > Int.max_int / cadence
  then Int.max_int
  else per_turn * cadence
;;
;;

let default_timeout_sec () =
  Env_config.KeeperMemoryOs.librarian_timeout_sec ()
;;

let runtime_id_for_librarian ~runtime_id =
  Keeper_memory_runtime_resolution.runtime_id_for_librarian ~runtime_id
;;

let select_recent_messages ~max_messages messages =
  let max_messages = max 0 max_messages in
  let len = List.length messages in
  let drop_count = max 0 (len - max_messages) in
  let rec drop n xs =
    if n <= 0
    then xs
    else (
      match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest)
  in
  drop drop_count messages
;;

let prompt_window_messages messages =
  select_recent_messages ~max_messages:(prompt_max_messages ()) messages
;;

let provider_for_librarian (provider_cfg : Llm_provider.Provider_config.t) =
  let configured_librarian_max_tokens = librarian_max_tokens () in
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n configured_librarian_max_tokens)
    | Some _ -> Some configured_librarian_max_tokens
    | None -> Some configured_librarian_max_tokens
  in
  let tuned_cfg =
    { provider_cfg with
      max_tokens
    ; temperature = Some 0.0
    ; tool_choice = None
    ; disable_parallel_tool_use = true
    ; enable_thinking = Some false
    ; preserve_thinking = Some false
    ; thinking_budget = None
    ; clear_thinking = Some true
    }
  in
  (* Native json_schema when the provider declares it; otherwise fall back to the
     schema-free tuned config so json_object / free-text providers (GLM, MiMo,
     ollama cloud) can still serve the librarian. The schema gate is NOT the
     silent-failure safety net — the parse-retry loop below plus WARN on
     permanent failure is. *)
  Keeper_structured_output_schema.apply_schema_or_prompt_tier
    ~log_label:"keeper librarian output contract"
    Keeper_structured_output_schema.librarian_episode_output_schema
    tuned_cfg
;;

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

(* Bounded parse-retry for librarian extraction (typed-harness contract C6).

   The librarian asks a provider for a JSON episode. When the provider returns a
   non-empty response that does not parse into the typed episode
   ([Keeper_librarian.episode_of_output] -> None), the prior behavior dropped the
   episode and only incremented [EpisodeCreateFailures]: a counter makes the loss
   visible but does not recover it (the telemetry-as-fix shape CLAUDE.md rejects).
   Instead, re-ask the provider with a corrective nudge up to
   [librarian_max_parse_retries] times before giving up. Transport failures
   (timeout / HTTP error) are NOT retried here — they are a provider-availability
   problem, not the model-output problem this bound addresses. *)
let librarian_max_parse_retries = 2

type retry_field_shape =
  { name : string
  ; shape : string
  }

let parse_retry_claim_categories =
  Keeper_memory_os_types.all_categories
  |> List.map Keeper_memory_os_types.category_to_string
;;

let parse_retry_claim_kinds =
  Keeper_memory_os_types.librarian_claim_kinds
  |> List.map Keeper_memory_os_types.claim_kind_to_string
;;

let quoted value = Printf.sprintf "\"%s\"" value
let union_shape values = values |> String.concat "|" |> quoted
let render_retry_field field = Printf.sprintf "\"%s\": %s" field.name field.shape

let retry_shape_string = quoted "string"
let retry_shape_integer = quoted "integer"
let retry_shape_optional_string = quoted "optional-string"
let retry_shape_string_list = Printf.sprintf "[%s]" retry_shape_string

let parse_retry_claim_field_shapes =
  [ { name = Keeper_librarian.wire_field_claim; shape = retry_shape_string }
  ; { name = Keeper_librarian.wire_field_category
    ; shape = union_shape parse_retry_claim_categories
    }
  ; { name = Keeper_librarian.wire_field_source_turn; shape = retry_shape_integer }
  ; { name = Keeper_librarian.wire_field_source_tool_call_id
    ; shape = retry_shape_optional_string
    }
  ; { name = Keeper_librarian.wire_field_claim_id; shape = retry_shape_optional_string }
  ; { name = Keeper_librarian.wire_field_claim_kind
    ; shape = union_shape parse_retry_claim_kinds
    }
  ]
;;

let parse_retry_claim_fields =
  List.map (fun field -> field.name) parse_retry_claim_field_shapes
;;

let parse_retry_claim_shape =
  parse_retry_claim_field_shapes
  |> List.map render_retry_field
  |> String.concat ", "
  |> Printf.sprintf "{%s}"
;;

let parse_retry_episode_field_shapes =
  [ { name = Keeper_librarian.wire_field_episode_summary; shape = retry_shape_string }
  ; { name = Keeper_librarian.wire_field_claims
    ; shape = Printf.sprintf "[%s]" parse_retry_claim_shape
    }
  ; { name = Keeper_librarian.wire_field_open_items; shape = retry_shape_string_list }
  ; { name = Keeper_librarian.wire_field_constraints; shape = retry_shape_string_list }
  ; { name = Keeper_librarian.wire_field_preserved_tool_refs
    ; shape = retry_shape_string_list
    }
  ]
;;

let parse_retry_episode_fields =
  List.map (fun field -> field.name) parse_retry_episode_field_shapes
;;

let parse_retry_episode_shape =
  parse_retry_episode_field_shapes
  |> List.map render_retry_field
  |> String.concat ",\n"
  |> Printf.sprintf "{%s}"
;;

let parse_retry_nudge =
  String.concat
    "\n"
    [ "Your previous response could not be parsed as the required JSON episode object. Respond with ONLY a single JSON object — no markdown fences, no prose."
    ; "Required shape:"
    ; parse_retry_episode_shape
    ; Printf.sprintf
        "%s must be an integer. Do not include a confidence field and do not add any fields not shown above."
        Keeper_librarian.wire_field_source_turn
    ]

type extraction_error =
  | Prompt_render_failed of string
  | Provider_clock_unavailable
  | Provider_config_rejected of string
  | Provider_timeout
  | Provider_transport_failed of string
  | Provider_empty_response
  | Provider_unparseable_response of string
  | Memory_fact_upsert_failed of string
  | Memory_episode_persistence_failed of string

let librarian_provider_clock_unavailable_error =
  "memory os librarian provider clock unavailable"
;;

let extraction_error_to_string = function
  | Prompt_render_failed msg -> msg
  | Provider_clock_unavailable -> librarian_provider_clock_unavailable_error
  | Provider_config_rejected msg -> "librarian provider config rejected: " ^ msg
  | Provider_timeout -> "librarian provider timed out"
  | Provider_transport_failed msg -> msg
  | Provider_empty_response -> "librarian provider returned empty response"
  | Provider_unparseable_response msg ->
    "librarian provider returned unparseable structured response: " ^ msg
  | Memory_fact_upsert_failed msg -> "memory os fact upsert failed: " ^ msg
  | Memory_episode_persistence_failed msg ->
    "memory os episode persistence failed: " ^ msg
;;

type unparseable_response =
  { reason : string
  ; raw_evidence : string option
  }

let unparseable_response ?raw_evidence reason = { reason; raw_evidence }

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of unparseable_response
    (* provider returned output we could not parse into an episode — retryable *)
  | Transport_failed of extraction_error (* timeout / HTTP error — not retried here *)

type parse_retry_error =
  | Retry_exhausted_unparseable of unparseable_response
  | Retry_transport_failed of extraction_error

let prefer_unparseable_response prior current =
  match current.raw_evidence with
  | Some raw when not (String.equal (String.trim raw) "") -> current
  | Some _ | None ->
    (match prior with
     | Some best -> best
     | None -> current)
;;

let run_with_parse_retries ~max_retries ~attempt messages =
  let rec loop ~remaining_retries ~best_unparseable messages =
    match attempt messages with
    | Parsed episode -> Ok episode
    | Transport_failed msg -> Error (Retry_transport_failed msg)
    | Unparseable diagnostic ->
      let selected = prefer_unparseable_response best_unparseable diagnostic in
      let best_unparseable = Some selected in
      if remaining_retries <= 0
      then Error (Retry_exhausted_unparseable selected)
      else
        loop
          ~remaining_retries:(remaining_retries - 1)
          ~best_unparseable
          (messages @ [ message Agent_sdk.Types.User parse_retry_nudge ])
  in
  loop ~remaining_retries:max_retries ~best_unparseable:None messages
;;

let render_prompt key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text ->
    let text = String.trim text in
    if String.equal text ""
    then Error (Printf.sprintf "%s rendered empty prompt" key)
    else Ok text
  | Error msg -> Error (Printf.sprintf "%s: %s" key msg)
;;

let messages_for_librarian (inp : Keeper_librarian.input) =
  let input =
    { inp with messages = prompt_window_messages inp.messages }
  in
  match render_prompt Keeper_prompt_names.librarian_system [] with
  | Error _ as e -> e
  | Ok system ->
    (match
       render_prompt
         Keeper_prompt_names.librarian_episode_extraction
         (Keeper_librarian.prompt_variables input)
     with
     | Error _ as e -> e
     | Ok user ->
       Ok
         [ message Agent_sdk.Types.System system
         ; message Agent_sdk.Types.User user
         ])
;;

(* http_error_message moved to Provider_http_error.to_message (SSOT,
   2026-06-24): four byte-for-output-identical copies unified. *)

let with_timeout ~clock ~timeout_sec f =
  try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
  | Eio.Time.Timeout -> None
;;

let extract_with_provider_classified
    ?(complete = default_complete)
    ?clock
    ?(timeout_sec = librarian_default_timeout_sec)
    ~sw
    ~net
    ~provider_cfg
    ~generation
    (inp : Keeper_librarian.input)
  =
  match clock with
  | None -> Error Provider_clock_unavailable
  | Some clock ->
    (match messages_for_librarian inp with
     | Error msg -> Error (Prompt_render_failed msg)
     | Ok messages ->
       let provider_cfg = provider_for_librarian provider_cfg in
       (match
          Llm_provider.Provider_config.validate_output_schema_request provider_cfg
        with
        | Error msg -> Error (Provider_config_rejected msg)
        | Ok () ->
          let attempt messages =
            match
              with_timeout ~clock ~timeout_sec (fun () ->
                complete ~sw ~net ~clock ~config:provider_cfg ~messages ())
            with
            | None -> Transport_failed Provider_timeout
            | Some (Error err) ->
              Transport_failed
                (Provider_transport_failed (Provider_http_error.to_message err))
            | Some (Ok response) ->
              let raw_evidence = Agent_sdk_response.text_of_response response |> String.trim in
              (match
                 Agent_sdk_response.structured_json_of_response
                   ~schema_name:"keeper_librarian_episode"
                   response
               with
               | Error detail ->
                 let raw_evidence =
                   if String.equal raw_evidence "" then None else Some raw_evidence
                 in
                 Unparseable
                   (unparseable_response
                      ?raw_evidence
                      (Printf.sprintf
                         "librarian provider returned invalid structured JSON (%s)"
                         detail))
               | Ok json ->
                 (match Keeper_librarian.episode_of_json_result ~generation inp json with
                  | Ok episode -> Parsed episode
                  | Error error ->
                    let raw_evidence =
                      if String.equal raw_evidence "" then None else Some raw_evidence
                    in
                    Unparseable
                      (unparseable_response
                         ?raw_evidence
                         (Printf.sprintf
                            "librarian provider returned invalid episode JSON (%s)"
                            (Keeper_librarian.parse_error_to_string error)))))
          in
          (match
             run_with_parse_retries
               ~max_retries:librarian_max_parse_retries
               ~attempt
               messages
           with
           | Ok episode -> Ok episode
           | Error (Retry_transport_failed err) -> Error err
           | Error (Retry_exhausted_unparseable diagnostic) ->
             Error (Provider_unparseable_response diagnostic.reason))))
;;

let extract_with_provider ?complete ?clock ?timeout_sec ~sw ~net ~provider_cfg ~generation inp =
  match
    extract_with_provider_classified
      ?complete
      ?clock
      ?timeout_sec
      ~sw
      ~net
      ~provider_cfg
      ~generation
      inp
  with
  | Error err -> Error (extraction_error_to_string err)
  | Ok episode -> Ok episode
;;

let publish_episode
    ?operation_id
    ?clock
    ?keepers_dir
    ~keeper_id
    ~operation_model_id
    ~provider_latency_ms
    episode
  =
  let now = episode.Keeper_memory_os_types.created_at in
  (* RFC-0243: UPSERT claims into the fact store instead of blind-appending. A claim
     re-extracted across turns is folded into the existing row
     (Keeper_memory_os_policy.reobserve_fact: RFC-0247 refreshes
     [last_verified_at] only) rather than accumulating as a duplicate. The same
     call applies the RFC-0239 Q4 retention cap (ranked by the structural
     [retention_rank]) in one atomic rewrite. Only after the facts are durable
     do we publish the episode file and append the event row; the event row is
     the reader-visible commit marker for [read_episodes_tail].

     RFC-0285 §8: before folding, decide each claim's provenance. A claim
     whose identity was recall-injected into this keeper's recent prompts is
     an echo — the model restating what it just read — and must not advance
     the truth anchor recall's recency ranking reads. The judgment (window
     join + metric) lives here at the write boundary; the fold itself stays
     a pure function of the decision. *)
  let with_bundle_lock f =
    match keepers_dir with
    | Some keepers_dir ->
      Keeper_memory_os_io.with_episode_bundle_lock_for_keepers_dir
        ?clock
        ~keepers_dir
        ~keeper_id
        f
    | None ->
      Keeper_memory_os_io.with_episode_bundle_lock ?clock ~keeper_id f
  in
  let facts_path () =
    match keepers_dir with
    | Some keepers_dir ->
      Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id
    | None -> Keeper_memory_os_io.facts_path ~keeper_id
  in
  with_bundle_lock (fun () ->
    let committed =
      match operation_id with
      | None -> Ok false
      | Some operation_id ->
        (match keepers_dir with
         | None ->
           Error
             (Memory_episode_persistence_failed
                "operation-backed publication requires an explicit keepers_dir")
         | Some keepers_dir ->
        Keeper_memory_os_io.operation_event_committed
          ~keepers_dir
          ~keeper_id
          ~operation_id
        |> Result.map_error (fun detail ->
          Memory_episode_persistence_failed detail))
    in
    match committed with
    | Error _ as error -> error
    | Ok true -> Ok (episode, operation_model_id, provider_latency_ms)
    | Ok false ->
      (match
         try
           let window = Keeper_memory_os_io.fact_recall_window in
           let merge ~existing ~incoming =
             let provenance =
               let key = Keeper_memory_os_types.claim_identity incoming in
               if Keeper_recall_injection_window.recently_injected ~keeper_id ~key
               then (
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string MemoryOsReobserveEchoSuppressed)
                   ~labels:[ "keeper", keeper_id ]
                   ();
                 Keeper_memory_os_policy.Recalled_echo)
               else Keeper_memory_os_policy.Independent_observation
             in
             Keeper_memory_os_policy.reobserve_fact ~now ~provenance ~existing ~incoming
           in
           let (_ : Keeper_memory_os_io.fact_merge_stats) =
             File_lock_eio.with_lock
               ?clock
               (facts_path ())
               (fun () ->
                  match keepers_dir with
                  | Some keepers_dir ->
                    Keeper_memory_os_io.merge_and_cap_facts_for_keepers_dir
                      ~keepers_dir
                      ~now
                      ~keeper_id
                      ~merge
                      ~incoming:episode.Keeper_memory_os_types.claims
                      ~keep:window
                      ~trigger:Keeper_memory_os_io.fact_store_max
                      ~rank:(Keeper_memory_os_policy.retention_rank ~now)
                  | None ->
                    Keeper_memory_os_io.merge_and_cap_facts
                      ~now
                      ~keeper_id
                      ~merge
                      ~incoming:episode.Keeper_memory_os_types.claims
                      ~keep:window
                      ~trigger:Keeper_memory_os_io.fact_store_max
                      ~rank:(Keeper_memory_os_policy.retention_rank ~now))
           in
           Ok ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           let message = Printexc.to_string exn in
           Log.Keeper.warn
             "memory os fact upsert failed keeper=%s: %s"
             keeper_id
             message;
           Error message
       with
       | Error message -> Error (Memory_fact_upsert_failed message)
       | Ok () ->
         let publication =
           match operation_id with
           | None ->
             (try
                (match keepers_dir with
                 | Some keepers_dir ->
                   Keeper_memory_os_io.append_episode_for_keepers_dir
                     ~keepers_dir
                     ~keeper_id
                     episode;
                   Keeper_memory_os_io.append_event_for_keepers_dir
                     ~keepers_dir
                     ~keeper_id
                     episode
                 | None ->
                   Keeper_memory_os_io.append_episode ~keeper_id episode;
                   Keeper_memory_os_io.append_event ~keeper_id episode);
                Ok ()
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn))
           | Some operation_id ->
             (match keepers_dir with
              | None ->
                Error
                  "operation-backed publication requires an explicit keepers_dir"
              | Some keepers_dir ->
                Keeper_memory_os_io.append_operation_event
                  ~keepers_dir
                  ~keeper_id
                  ~operation_id
                  ~model_id:operation_model_id
                  ~provider_latency_ms
                  episode)
         in
         (match publication with
          | Error detail -> Error (Memory_episode_persistence_failed detail)
          | Ok () ->
            (* RFC-0272 (defect D): bound the append-only episode log under the
               same bundle lock that serialized the writes above. *)
            (match keepers_dir with
             | Some keepers_dir ->
               ignore
                 (Keeper_memory_os_io.cap_events_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id
                    ~keep:Keeper_memory_os_io.event_recall_window
                    ~trigger:Keeper_memory_os_io.event_store_max
                  : int);
               ignore
                 (Keeper_memory_os_io.cap_episode_files_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id
                    ~keep:Keeper_memory_os_io.episode_file_window
                    ~trigger:Keeper_memory_os_io.episode_file_store_max
                  : int)
             | None ->
               ignore
                 (Keeper_memory_os_io.cap_events
                    ~keeper_id
                    ~keep:Keeper_memory_os_io.event_recall_window
                    ~trigger:Keeper_memory_os_io.event_store_max
                  : int);
               ignore
                 (Keeper_memory_os_io.cap_episode_files
                    ~keeper_id
                    ~keep:Keeper_memory_os_io.episode_file_window
                    ~trigger:Keeper_memory_os_io.episode_file_store_max
                  : int));
            Ok (episode, operation_model_id, provider_latency_ms))))
;;

let commit_staged_operation ~keepers_dir ?clock ~keeper_id ~operation_id staged =
  publish_episode
    ~operation_id
    ?clock
    ~keepers_dir
    ~keeper_id
    ~operation_model_id:staged.Keeper_memory_os_io.model_id
    ~provider_latency_ms:staged.provider_latency_ms
    staged.episode
  |> Result.map (fun _ -> ())
;;

let extract_and_append_with_provider_classified_with_model
    ?operation_id
    ?complete
    ?clock
    ?keepers_dir
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match clock with
  | None -> Error Provider_clock_unavailable
  | Some clock ->
    let extract_new_episode () =
      let provider_started_at = Eio.Time.now clock in
      let generation =
        match keepers_dir with
        | Some keepers_dir ->
          Keeper_memory_os_io.next_generation_with_floor_for_keepers_dir
            ~keepers_dir
            ~floor:inp.Keeper_librarian.generation
            ~keeper_id
            ~trace_id:inp.Keeper_librarian.trace_id
        | None ->
          Keeper_memory_os_io.next_generation_with_floor
            ~floor:inp.Keeper_librarian.generation
            ~keeper_id
            ~trace_id:inp.Keeper_librarian.trace_id
      in
      extract_with_provider_classified
        ?complete
        ~clock
        ?timeout_sec
        ~sw
        ~net
        ~provider_cfg
        ~generation
        inp
      |> Result.map (fun episode ->
        let provider_latency_ms =
          max 0.0 (Eio.Time.now clock -. provider_started_at)
          *. 1000.0
          |> Keeper_timing.round1
        in
        episode, provider_latency_ms)
    in
    let episode_result =
      match operation_id with
      | None ->
        extract_new_episode ()
        |> Result.map (fun (episode, provider_latency_ms) ->
          episode, provider_cfg.model_id, provider_latency_ms)
      | Some operation_id ->
        (match keepers_dir with
         | None ->
           Error
             (Memory_episode_persistence_failed
                "operation-backed extraction requires an explicit keepers_dir")
         | Some keepers_dir ->
        (match
           Keeper_memory_os_io.load_operation_episode
             ~keepers_dir
             ~keeper_id
             ~operation_id
         with
         | Error detail -> Error (Memory_episode_persistence_failed detail)
         | Ok (Some staged) ->
           Ok
             ( staged.Keeper_memory_os_io.episode
             , staged.model_id
             , staged.provider_latency_ms )
         | Ok None ->
           (match extract_new_episode () with
            | Error _ as error -> error
            | Ok (episode, provider_latency_ms) ->
              (match
                 Keeper_memory_os_io.stage_operation_episode_once
                   ?clock
                   ~keepers_dir
                   ~keeper_id
                   ~operation_id
                   ~model_id:provider_cfg.model_id
                   ~provider_latency_ms
                   episode
               with
               | Ok winner ->
                 Ok
                   ( winner.Keeper_memory_os_io.episode
                   , winner.model_id
                   , winner.provider_latency_ms )
               | Error detail ->
                 Error (Memory_episode_persistence_failed detail)))))
    in
    (match episode_result with
     | Error _ as error -> error
     | Ok (episode, operation_model_id, provider_latency_ms) ->
       publish_episode
         ?operation_id
         ?clock
         ?keepers_dir
         ~keeper_id
         ~operation_model_id
         ~provider_latency_ms
         episode)
;;

let extract_and_append_with_provider_classified
    ?operation_id
    ?complete
    ?clock
    ?keepers_dir
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match
    extract_and_append_with_provider_classified_with_model
      ?operation_id
      ?complete
      ?clock
      ?keepers_dir
      ?timeout_sec
      ~sw
      ~net
      ~keeper_id
      ~provider_cfg
      inp
  with
  | Error _ as error -> error
  | Ok (episode, _, _) -> Ok episode
;;

let extract_and_append_with_provider
    ?operation_id
    ?complete
    ?clock
    ?keepers_dir
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match
    extract_and_append_with_provider_classified
      ?operation_id
      ?complete
      ?clock
      ?keepers_dir
      ?timeout_sec
      ~sw
      ~net
      ~keeper_id
      ~provider_cfg
      inp
  with
  | Error err -> Error (extraction_error_to_string err)
  | Ok episode -> Ok episode
;;

let provider_for_runtime ~runtime_id =
  Keeper_memory_runtime_resolution.provider_for_runtime ~runtime_id
;;

type skip_reason =
  | Librarian_disabled
  | Cadence_not_due

type run_error =
  | Eio_context_unavailable
  | Runtime_resolution_failed of string
  | Provider_not_direct_completion
  | Extraction_failed of extraction_error
  | Unexpected_failure of string

type run_outcome =
  | Run_skipped of
      { runtime_id : string
      ; model_id : string option
      ; reason : skip_reason
      ; latency_ms : float
      ; next_due_after_turns : int option
      }
  | Run_succeeded of
      { runtime_id : string
      ; model_id : string
      ; episode : Keeper_memory_os_types.episode
      ; provider_latency_ms : float
      ; latency_ms : float
      ; next_due_after_turns : int
      }
  | Run_failed of
      { runtime_id : string
      ; model_id : string option
      ; error : run_error
      ; latency_ms : float
      ; next_due_after_turns : int
      }

let skip_reason_to_string = function
  | Librarian_disabled -> "disabled"
  | Cadence_not_due -> "cadence_not_due"
;;

let run_error_to_string = function
  | Eio_context_unavailable -> "Eio context unavailable"
  | Runtime_resolution_failed detail -> "runtime resolution failed: " ^ detail
  | Provider_not_direct_completion -> "provider does not support direct completion"
  | Extraction_failed error -> extraction_error_to_string error
  | Unexpected_failure detail -> detail
;;

let next_due_after_turns_to_json = function
  | None -> `Null
  | Some turns -> `Int turns
;;

let run_outcome_to_json = function
  | Run_skipped
      { runtime_id
      ; model_id
      ; reason
      ; latency_ms
      ; next_due_after_turns
      } ->
    `Assoc
      [ "status", `String "skipped"
      ; "runtime_id", `String runtime_id
      ; "model_id", Json_util.string_opt_to_json model_id
      ; "reason", `String (skip_reason_to_string reason)
      ; "latency_ms", `Float latency_ms
      ; "next_due_after_turns"
        , next_due_after_turns_to_json next_due_after_turns
      ]
  | Run_succeeded
      { runtime_id
      ; model_id
      ; episode
      ; provider_latency_ms
      ; latency_ms
      ; next_due_after_turns
      } ->
    `Assoc
      [ "status", `String "succeeded"
      ; "runtime_id", `String runtime_id
      ; "model_id", `String model_id
      ; "episode_generation", `Int episode.Keeper_memory_os_types.generation
      ; "claim_count", `Int (List.length episode.claims)
      ; "provider_latency_ms", `Float provider_latency_ms
      ; "latency_ms", `Float latency_ms
      ; "next_due_after_turns", `Int next_due_after_turns
      ]
  | Run_failed
      { runtime_id
      ; model_id
      ; error
      ; latency_ms
      ; next_due_after_turns
      } ->
    `Assoc
      [ "status", `String "failed"
      ; "runtime_id", `String runtime_id
      ; "model_id", Json_util.string_opt_to_json model_id
      ; "error", `String (run_error_to_string error)
      ; "latency_ms", `Float latency_ms
      ; "next_due_after_turns", `Int next_due_after_turns
      ]
;;

let run_outcome_is_failure = function
  | Run_failed _ -> true
  | Run_skipped _ | Run_succeeded _ -> false
;;

let run_best_effort
      ?operation_id
      ?complete
      ?timeout_sec
      ~keepers_dir
      ~admission_decision
      ~runtime_id
      ~keeper_id
      (inp : Keeper_librarian.input)
  =
  let started_at = Time_compat.now () in
  let latency_ms () =
    Keeper_timing.round1 ((Time_compat.now () -. started_at) *. 1000.0)
  in
  let cadence = cadence_turns () in
  (* The admission decision was made synchronously with the durable job payload.
     Replay consumes that typed decision verbatim; runtime restart or a failed
     receipt write can never turn one admitted provider attempt into a later
     cadence skip. *)
  match admission_decision with
  | Admission_disabled ->
    Run_skipped
      { runtime_id
      ; model_id = None
      ; reason = Librarian_disabled
      ; latency_ms = latency_ms ()
      ; next_due_after_turns = None
      }
  | Admission_not_due { turns_remaining } ->
       Run_skipped
         { runtime_id
         ; model_id = None
         ; reason = Cadence_not_due
         ; latency_ms = latency_ms ()
         ; next_due_after_turns = Some turns_remaining
         }
  | Admission_due ->
      try
      match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
      | Some sw, Some net ->
        let runtime_id = runtime_id_for_librarian ~runtime_id in
        (match provider_for_runtime ~runtime_id with
         | Error err ->
           Log.Keeper.warn ~keeper_name:keeper_id
             "memory os librarian failed runtime=%s: %s"
             runtime_id
             err;
           Run_failed
             { runtime_id
             ; model_id = None
             ; error = Runtime_resolution_failed err
             ; latency_ms = latency_ms ()
             ; next_due_after_turns = cadence
             }
         | Ok provider_cfg ->
           if not (Keeper_memory_llm_summary.is_direct_completion_provider provider_cfg)
           then (
             Log.Keeper.warn ~keeper_name:keeper_id
               "memory os librarian failed runtime=%s model=%s: provider does not support direct completion"
               runtime_id
               provider_cfg.model_id;
             Run_failed
               { runtime_id
               ; model_id = Some provider_cfg.model_id
               ; error = Provider_not_direct_completion
               ; latency_ms = latency_ms ()
               ; next_due_after_turns = cadence
               })
           else (
             let clock = Eio_context.get_clock_opt () in
             let timeout_sec =
               Option.value timeout_sec ~default:(default_timeout_sec ())
             in
             match clock with
             | None ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string EpisodeCreateFailures)
                 ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
                 ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian failed runtime=%s: %s"
                 runtime_id
                 librarian_provider_clock_unavailable_error;
               Run_failed
                 { runtime_id
                 ; model_id = Some provider_cfg.model_id
                 ; error = Extraction_failed Provider_clock_unavailable
                 ; latency_ms = latency_ms ()
                 ; next_due_after_turns = cadence
                 }
             | Some clock ->
               (match
                  extract_and_append_with_provider_classified_with_model
                    ?operation_id
                    ?complete
                    ~keepers_dir
                    ~clock
                    ~timeout_sec
                    ~sw
                    ~net
                    ~keeper_id
                    ~provider_cfg
                    inp
                with
                | Ok (episode, operation_model_id, provider_latency_ms) ->
               Log.Keeper.info ~keeper_name:keeper_id
                 "memory os librarian wrote episode trace_id=%s generation=%d claims=%d"
                 episode.Keeper_memory_os_types.trace_id
                 episode.generation
                 (List.length episode.claims);
               Run_succeeded
                 { runtime_id
                 ; model_id = operation_model_id
                 ; episode
                 ; provider_latency_ms
                 ; latency_ms = latency_ms ()
                 ; next_due_after_turns = cadence
                 }
                | Error err ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string EpisodeCreateFailures)
                 ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
                 ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian failed runtime=%s: %s"
                 runtime_id
                 (extraction_error_to_string err);
               Run_failed
                 { runtime_id
                 ; model_id = Some provider_cfg.model_id
                 ; error = Extraction_failed err
                 ; latency_ms = latency_ms ()
                 ; next_due_after_turns = cadence
                 })))
      | _ ->
        Log.Keeper.warn ~keeper_name:keeper_id
          "memory os librarian failed: Eio context unavailable runtime=%s"
          runtime_id;
        Run_failed
          { runtime_id
          ; model_id = None
          ; error = Eio_context_unavailable
          ; latency_ms = latency_ms ()
          ; next_due_after_turns = cadence
          }
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string EpisodeCreateFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      Log.Keeper.warn ~keeper_name:keeper_id
        "memory os librarian failed runtime=%s: %s"
        runtime_id
        (Printexc.to_string exn);
      Run_failed
        { runtime_id
        ; model_id = None
        ; error = Unexpected_failure (Printexc.to_string exn)
        ; latency_ms = latency_ms ()
        ; next_due_after_turns = cadence
        }
;;
