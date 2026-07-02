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

(* RFC-0257 / P0-4 adversarial hardening: per-keeper librarian provider slot.
   The previous process-global slot allowed one slow keeper to starve the fleet.
   Capacity is still read from [MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT]
   (default 1), but the semaphore is now keyed by [keeper_id] so each keeper
   gets its own concurrency budget. A capacity of 0 disables the gate entirely. *)
let per_keeper_slot_capacity () =
  Env_config.KeeperMemoryOs.librarian_global_slot ()
;;

let memory_os_librarian_provider_slot_site = "memory_os_librarian_provider_slot"

let provider_slot_wait_sec = 0.25

type provider_slot =
  { capacity : int
  ; sem : Eio.Semaphore.t option
  }

let provider_slots_mu = Eio.Mutex.create ()
let provider_slots : (string, provider_slot) Hashtbl.t = Hashtbl.create 64

let provider_slot_for_keeper ~keeper_id capacity =
  Eio_guard.with_mutex provider_slots_mu (fun () ->
    match Hashtbl.find_opt provider_slots keeper_id with
    | Some slot when slot.capacity = capacity -> slot
    | _ ->
      let slot =
        { capacity
        ; sem =
            (match capacity with
             | 0 -> None
             | n -> Some (Eio.Semaphore.make n))
        }
      in
      Hashtbl.replace provider_slots keeper_id slot;
      slot)
;;

let with_provider_slot ~keeper_id ~clock f =
  let capacity = per_keeper_slot_capacity () in
  let slot = provider_slot_for_keeper ~keeper_id capacity in
  match slot.sem with
  | None -> Some (f ())
  | Some sem ->
    let acquired = ref false in
    (try
       (try
          Eio.Time.with_timeout_exn clock provider_slot_wait_sec (fun () ->
            Eio.Semaphore.acquire sem);
         acquired := true
        with
        | Eio.Time.Timeout -> ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "librarian provider slot acquisition failed keeper=%s: %s"
         keeper_id
         (Printexc.to_string exn));
    if !acquired
    then
      Some
        (Eio.Switch.run (fun cleanup_sw ->
           Eio.Switch.on_release cleanup_sw (fun () -> Eio.Semaphore.release sem);
           f ()))
    else None
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

(* Per-keeper "turns since last successful extraction" counter, paired with the
   trace it belongs to. Keyed by [keeper_id] (the long-lived owner), NOT by
   (keeper_id, trace_id): trace_id rotates on every keeper run, so a pair-keyed
   table mints a fresh row per rotation and never reclaims the previous one,
   growing without bound over the process lifetime. Keying by keeper_id bounds
   the table to one row per live keeper; a rotated trace is detected as a stored
   mismatch and resets the schedule in place.

   [Eio_guard.with_mutex]: the cadence table is reachable from concurrent keeper
   fibers, and a blocking stdlib mutex can stall unrelated Eio work if a fiber
   holds that lock while waiting on another Eio resource. [Eio_guard] gives
   runtime fibers cooperative locking while preserving a direct path for focused
   tests that call the pure cadence helpers before the Eio runtime is enabled. *)
let cadence_mu = Eio.Mutex.create ()
let cadence_counters : (string, string * int) Hashtbl.t = Hashtbl.create 16

(* A counter value below 0 means the keeper has never had a successful
   extraction on the current trace: the next turn is due immediately. *)
let fresh_counter = -1

(* Pure cadence decision. Given the keeper's current [counter] (turns since its
   last successful extraction) and the [cadence], return the updated counter and
   whether extraction is due now.

   - counter < 0 (fresh) is due immediately.
   - cadence <= 1 is always due with the counter pinned at 0.
   - When due, the counter is set to [cadence] and stays there until
     [cadence_record_success] or [cadence_record_attempt] resets it to 0. This
     keeps the keeper due across skipped work, while completed non-success
     provider attempts can defer the next attempt to the cadence window instead
     of retrying on every keeper turn. *)
let cadence_step ~cadence ~counter =
  if cadence <= 1
  then 0, true
  else if counter < 0
  then cadence, true
  else (
    let next = counter + 1 in
    if next >= cadence then cadence, true else next, false)
;;

(* Pure keyed cadence decision. Given a keeper's [prior] stored (trace, counter)
   and the [current_trace], a stored entry from a different (rotated) trace is
   treated as fresh — due immediately, not inheriting the old trace's schedule —
   exactly like an unseen keeper ([prior = None]). Returns the value to store and
   whether extraction is due now. Exposed for testing the rollover decision
   without the global table. *)
let cadence_step_keyed ~cadence ~current_trace ~prior =
  let counter =
    (* sound-partial: allow — an unseen keeper or a rotated trace is fresh
       (due immediately via [fresh_counter]); fresh-state init, not a default
       hiding a parse error. *)
    match prior with
    | Some (t, c) when String.equal t current_trace -> c
    | _ -> fresh_counter
  in
  let updated, due = cadence_step ~cadence ~counter in
  (current_trace, updated), due
;;

let cadence_due ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    let prior = Hashtbl.find_opt cadence_counters keeper_id in
    let value, due =
      cadence_step_keyed ~cadence:(cadence_turns ()) ~current_trace:trace_id ~prior
    in
    Hashtbl.replace cadence_counters keeper_id value;
    due)
;;

let cadence_record_success ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    Hashtbl.replace cadence_counters keeper_id (trace_id, 0))
;;

let cadence_record_attempt ~keeper_id ~trace_id =
  Eio_guard.with_mutex cadence_mu (fun () ->
    Hashtbl.replace cadence_counters keeper_id (trace_id, 0))
;;

(* Live per-keeper cadence rows. Bounded by the number of keepers that have run
   (one row each), so it doubles as a leak-regression signal: it must not grow
   with trace rotations. Read-only; consumed by the cadence test and the
   dashboard memory-health panel. *)
let cadence_counter_entries () =
  Eio_guard.with_mutex_ro cadence_mu (fun () -> Hashtbl.length cadence_counters)
;;

let max_messages () =
  Env_config.KeeperMemoryOs.librarian_max_messages ()
;;

(* Scale the prompt window by the cadence so skipped turns stay visible until
   the next due extraction. Without this, a tool-heavy skipped turn can scroll
   out of the per-turn cap before its first successful extraction. *)
let prompt_max_messages () = max_messages () * cadence_turns ()
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

let provider_for_librarian (provider_cfg : Llm_provider.Provider_config.t) =
  let configured_librarian_max_tokens = librarian_max_tokens () in
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n configured_librarian_max_tokens)
    | Some _ -> Some configured_librarian_max_tokens
    | None -> Some configured_librarian_max_tokens
  in
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
    |> Keeper_structured_output_schema.apply_to_provider_config
         Keeper_structured_output_schema.librarian_episode_output_schema
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

let should_record_cadence_backoff_after_error = function
  | Provider_timeout
  | Provider_transport_failed _
  | Provider_empty_response
  | Provider_unparseable_response _ ->
    true
  | Provider_clock_unavailable
  | Provider_config_rejected _
  | Prompt_render_failed _
  | Memory_fact_upsert_failed _ ->
    false
;;

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
    { inp with messages = select_recent_messages ~max_messages:(prompt_max_messages ()) inp.messages }
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

let extract_and_append_with_provider_classified
    ?complete
    ?clock
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match clock with
  | None -> Error Provider_clock_unavailable
  | Some _ ->
    let generation =
      Keeper_memory_os_io.next_generation_with_floor
        ~floor:inp.Keeper_librarian.generation
        ~keeper_id
        ~trace_id:inp.Keeper_librarian.trace_id
    in
    (match
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
  | Error _ as e -> e
  | Ok episode ->
    let now = episode.Keeper_memory_os_types.created_at in
    (* RFC-0243: UPSERT claims into the fact store instead of blind-appending. A claim
       re-extracted across turns is folded into the existing row
       (Keeper_memory_os_policy.reobserve_fact: RFC-0247 refreshes
       [last_verified_at] only) rather than accumulating as a duplicate. The same
       call applies the RFC-0239 Q4 retention cap (ranked by the structural
       [retention_rank]) in one atomic rewrite. Only after the facts are durable
       do we publish the episode file and append the event row; the event row is
       the reader-visible commit marker for [read_episodes_tail]. *)
    Keeper_memory_os_io.with_episode_bundle_lock ?clock ~keeper_id (fun () ->
      match
        try
          let window = Keeper_memory_os_io.fact_recall_window in
          let (_ : Keeper_memory_os_io.fact_merge_stats) =
            File_lock_eio.with_lock ?clock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
              Keeper_memory_os_io.merge_and_cap_facts
                ~now
                ~keeper_id
                ~merge:(Keeper_memory_os_policy.reobserve_fact ~now)
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
          Log.Keeper.warn "memory os fact upsert failed keeper=%s: %s" keeper_id message;
          Error message
      with
      | Ok () ->
        Keeper_memory_os_io.append_episode ~keeper_id episode;
        Keeper_memory_os_io.append_event ~keeper_id episode;
        (* RFC-0272 (defect D): bound the append-only episode log under the same
           bundle lock that serialized the writes above, so a re-extraction cannot
           grow events.jsonl / episodes/ without limit. Hysteresis-gated: the trim
           is a no-op until the high-water, so this is off the per-turn hot path. *)
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
            : int);
        (* RFC-0251: the co-occurrence edge / spreading-activation organ was removed
           (dark-by-default, no recall consumer), so the fact upsert above is the only
           post-merge work. *)
        Ok episode
      | Error message -> Error (Memory_fact_upsert_failed message)))
;;

let extract_and_append_with_provider
    ?complete
    ?clock
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match
    extract_and_append_with_provider_classified
      ?complete
      ?clock
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

let run_best_effort ?complete ?timeout_sec ~runtime_id ~keeper_id (inp : Keeper_librarian.input) =
  (* [cadence_due] short-circuits after [enabled]: a disabled keeper never
     advances its cadence counter, and a not-due turn skips extraction entirely
     (the messages remain in the window for the next due turn). The cadence
     counter is scoped to the active trace so a rollover does not inherit the
     previous trace's schedule. *)
  if enabled () && cadence_due ~keeper_id ~trace_id:inp.trace_id
  then (
    try
      match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
      | Some sw, Some net ->
        let runtime_id = runtime_id_for_librarian ~runtime_id in
        (match provider_for_runtime ~runtime_id with
         | Error err ->
           Log.Keeper.warn ~keeper_name:keeper_id
             "memory os librarian skipped runtime=%s: %s"
             runtime_id
             err
         | Ok provider_cfg ->
           if not (Keeper_memory_llm_summary.is_direct_completion_provider provider_cfg)
           then
             Log.Keeper.warn ~keeper_name:keeper_id
               "memory os librarian skipped runtime=%s provider=%s: provider does not support direct completion"
               runtime_id
               provider_cfg.Llm_provider.Provider_config.model_id
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
                 librarian_provider_clock_unavailable_error
             | Some clock -> (
             match
               with_provider_slot ~keeper_id ~clock (fun () ->
                 extract_and_append_with_provider_classified
                   ?complete
                   ~clock
                   ~timeout_sec
                   ~sw
                   ~net
                   ~keeper_id
                   ~provider_cfg
                   inp)
             with
             | None ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string MemoryLaneProviderSlotBusy)
                ~labels:
                  [ "keeper", keeper_id; "site", memory_os_librarian_provider_slot_site ]
                 ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian skipped runtime=%s: per-keeper provider slot busy (capacity=%d)"
                 runtime_id
                 (per_keeper_slot_capacity ())
             | Some (Ok episode) ->
               cadence_record_success ~keeper_id ~trace_id:inp.trace_id;
               Log.Keeper.info ~keeper_name:keeper_id
                 "memory os librarian wrote episode trace_id=%s generation=%d claims=%d"
                 episode.Keeper_memory_os_types.trace_id
                 episode.generation
                 (List.length episode.claims)
             | Some (Error err) ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string EpisodeCreateFailures)
                 ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
                 ();
               if should_record_cadence_backoff_after_error err
               then cadence_record_attempt ~keeper_id ~trace_id:inp.trace_id;
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian failed runtime=%s: %s; cadence deferred=%b"
                 runtime_id
                 (extraction_error_to_string err)
                 (should_record_cadence_backoff_after_error err))))
      | _ ->
        Log.Keeper.warn ~keeper_name:keeper_id
          "memory os librarian skipped: Eio context unavailable runtime=%s"
          runtime_id
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
        (Printexc.to_string exn))
;;
