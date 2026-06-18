(** Runtime adapter for Memory OS librarian extraction. *)

let librarian_max_tokens = 1024

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

(* RFC-0255 adversarial review: the previous process-global slot was removed in
   favor of per-keeper lanes, but measured production data showed that an
   unbounded shared flash/glm provider pool can spike empty-response rates.
   Re-introduce an optional fleet-wide concurrency gate around librarian provider
   calls only. Per-keeper lanes still serialize ordering and fairness; this slot
   only caps simultaneous provider round-trips. Default 1 preserves the prior
   #21230 protection; 0 disables the gate. *)
let global_slot_capacity () =
  Keeper_memory_bank_env.memory_env_int_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT"
    ~default:1
  |> max 0
;;

let provider_slot_wait_sec = 0.25

type provider_slot_state =
  { capacity : int
  ; slot : Eio.Semaphore.t option
  }

let provider_slot_mu = Stdlib.Mutex.create ()
let provider_slot_state : provider_slot_state option ref = ref None

let provider_slot_for_capacity capacity =
  Stdlib.Mutex.protect provider_slot_mu (fun () ->
    match !provider_slot_state with
    | Some state when state.capacity = capacity -> state.slot
    | _ ->
      let slot =
        match capacity with
        | 0 -> None
        | n -> Some (Eio.Semaphore.make n)
      in
      provider_slot_state := Some { capacity; slot };
      slot)
;;

let with_provider_slot ?clock f =
  let capacity = global_slot_capacity () in
  match provider_slot_for_capacity capacity with
  | None -> Some (f ())
  | Some sem ->
    let acquired = ref false in
    (try
       match clock with
       | None ->
         Eio.Semaphore.acquire sem;
         acquired := true
       | Some clock ->
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
         "librarian provider slot acquisition failed: %s"
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
  Keeper_memory_bank_env.memory_env_bool_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN"
    ~default:true
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
  Keeper_memory_bank_env.memory_env_int_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS"
    ~default:3
  |> max 1
;;

(* Per-(keeper, active trace) "turns since last successful extraction"
   counters. Stdlib.Mutex (not Eio.Mutex): the critical section is a Hashtbl
   read/write that never yields, and the table is reachable from concurrent
   keeper fibers. *)
let cadence_mu = Stdlib.Mutex.create ()
let cadence_counters : (string * string, int) Hashtbl.t = Hashtbl.create 16

(* A counter value below 0 means the (keeper, trace) has never had a successful
   extraction: the next turn is due immediately. *)
let fresh_counter = -1

(* Pure cadence decision. Given the keeper's current [counter] (turns since its
   last successful extraction) and the [cadence], return the updated counter and
   whether extraction is due now.

   - counter < 0 (fresh) is due immediately.
   - cadence <= 1 is always due with the counter pinned at 0.
   - When due, the counter is set to [cadence] and stays there until
     [cadence_record_success] resets it to 0. This keeps the keeper due across
     skipped or failed attempts instead of silently suppressing the next turns. *)
let cadence_step ~cadence ~counter =
  if cadence <= 1
  then 0, true
  else if counter < 0
  then cadence, true
  else (
    let next = counter + 1 in
    if next >= cadence then cadence, true else next, false)
;;

let cadence_due ~keeper_id ~trace_id =
  Stdlib.Mutex.protect cadence_mu (fun () ->
    let counter =
      (* sound-partial: allow — an unseen (keeper, trace) is due immediately via
         [fresh_counter]; fresh-state init, not a default hiding a parse error. *)
      Option.value ~default:fresh_counter
        (Hashtbl.find_opt cadence_counters (keeper_id, trace_id))
    in
    let updated, due = cadence_step ~cadence:(cadence_turns ()) ~counter in
    Hashtbl.replace cadence_counters (keeper_id, trace_id) updated;
    due)
;;

let cadence_record_success ~keeper_id ~trace_id =
  Stdlib.Mutex.protect cadence_mu (fun () ->
    Hashtbl.replace cadence_counters (keeper_id, trace_id) 0)
;;

let max_messages () =
  Keeper_memory_bank_env.memory_env_int_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES"
    ~default:24
  |> max 1
;;

(* Scale the prompt window by the cadence so skipped turns stay visible until
   the next due extraction. Without this, a tool-heavy skipped turn can scroll
   out of the per-turn cap before its first successful extraction. *)
let prompt_max_messages () = max_messages () * cadence_turns ()
;;

let default_timeout_sec () =
  Keeper_memory_bank_env.memory_env_float_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC"
    ~default:Env_config_governance.Inference.timeout_seconds
;;

let runtime_id_for_librarian ~runtime_id =
  match
    Keeper_memory_bank_env.memory_env_opt "MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID"
  with
  | Some value -> value
  | None -> runtime_id
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
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n librarian_max_tokens)
    | Some _ -> Some librarian_max_tokens
    | None -> Some librarian_max_tokens
  in
  { provider_cfg with
    max_tokens
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.JsonMode
  ; output_schema = None
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
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

let parse_retry_nudge =
  "Your previous response could not be parsed as the required JSON episode \
   object. Respond with ONLY a single JSON object — no markdown fences, no \
   prose — containing: episode_summary (string), claims (array of objects with \
   claim, confidence, category, source_turn), open_items, constraints, \
   preserved_tool_refs."

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of string
    (* provider returned output we could not parse into an episode — retryable *)
  | Transport_failed of string (* timeout / HTTP error — not retried here *)

let rec run_with_parse_retries ~max_retries ~attempt messages =
  match attempt messages with
  | Parsed episode -> Ok episode
  | Transport_failed msg -> Error msg
  | Unparseable msg ->
    if max_retries <= 0
    then Error msg
    else
      run_with_parse_retries
        ~max_retries:(max_retries - 1)
        ~attempt
        (messages @ [ message Agent_sdk.Types.User parse_retry_nudge ])
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

let http_error_message (err : Llm_provider.Http_client.http_error) =
  match err with
  | Llm_provider.Http_client.NetworkError { message; _ } -> message
  | Llm_provider.Http_client.TimeoutError { message; phase } ->
    Printf.sprintf
      "provider timeout: %s: %s"
      (Llm_provider.Http_client.timeout_phase_to_label phase)
      message
  | Llm_provider.Http_client.AcceptRejected { reason } -> reason
  | Llm_provider.Http_client.ProviderTerminal { kind = _; message } ->
    Printf.sprintf "provider terminal: %s" message
  | Llm_provider.Http_client.ProviderFailure { kind; message } ->
    Llm_provider.Http_client.provider_failure_to_string ~kind ~message
  | Llm_provider.Http_client.HttpError { code; body } ->
    Printf.sprintf
      "HTTP %d: %s"
      code
      (if String.length body > 200 then String.sub body 0 200 ^ "..." else body)
;;

let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Some (f ())
  | Some clock ->
    (try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
     | Eio.Time.Timeout -> None)
;;

let extract_with_provider
    ?(complete = default_complete)
    ?clock
    ?(timeout_sec = Env_config_governance.Inference.timeout_seconds)
    ~sw
    ~net
    ~provider_cfg
    (inp : Keeper_librarian.input)
  =
  match messages_for_librarian inp with
  | Error _ as e -> e
  | Ok messages ->
    let provider_cfg = provider_for_librarian provider_cfg in
    let attempt messages =
      match
        with_timeout ?clock ~timeout_sec (fun () ->
          complete ~sw ~net ?clock ~config:provider_cfg ~messages ())
      with
      | None -> Transport_failed "librarian provider timed out"
      | Some (Error err) -> Transport_failed (http_error_message err)
      | Some (Ok response) ->
        let raw = Agent_sdk_response.text_of_response response |> String.trim in
        if String.equal raw ""
        then Unparseable "librarian provider returned empty response"
        else (
          match Keeper_librarian.episode_of_output inp raw with
          | Some episode -> Parsed episode
          | None -> Unparseable "librarian provider returned invalid episode JSON")
    in
    run_with_parse_retries
      ~max_retries:librarian_max_parse_retries
      ~attempt
      messages
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
  match extract_with_provider ?complete ?clock ?timeout_sec ~sw ~net ~provider_cfg inp with
  | Error _ as e -> e
  | Ok episode ->
    let now = episode.Keeper_memory_os_types.created_at in
    (* RFC-0243: persist the episode log (unique episode file + event), then
       UPSERT its claims into the fact store instead of blind-appending. A claim
       re-extracted across turns is folded into the existing row
       (Keeper_memory_os_policy.reobserve_fact: RFC-0247 refreshes
       [last_verified_at] only) rather than accumulating as a duplicate. The same
       call applies the RFC-0239 Q4 retention cap (ranked by the structural
       [retention_rank]) in one atomic rewrite. The episode log already retains
       the raw claims, but a fact-merge failure is still reported to the caller so
       the turn is not counted as a clean librarian write. *)
    Keeper_memory_os_io.append_episode ~keeper_id episode;
    Keeper_memory_os_io.append_event ~keeper_id episode;
    (match
       try
         let window = Keeper_memory_os_io.fact_recall_window in
         let (_ : Keeper_memory_os_io.fact_merge_stats) =
           File_lock_eio.with_lock ?clock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
             Keeper_memory_os_io.merge_and_cap_facts
               ~keeper_id
               ~merge:(Keeper_memory_os_policy.reobserve_fact ~now)
               ~incoming:episode.Keeper_memory_os_types.claims
               ~keep:window
               ~trigger:(window + (window / 2))
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
       (* RFC-0247 §2.7: record the episode's co-occurrence associations — but only
          when activation is enabled ([writes_enabled]). With the default-off organ
          there is no consumer, so writing edges would accrue unbounded disk cost on
          the fleet for nothing; gating the write keeps the whole organ dark until an
          operator opts in. This is enrichment for associative recall, not part of
          the fact contract, so a failure here is logged and swallowed (Cancelled
          re-raised) exactly like the fact upsert — edges never block a turn or the
          fact write above. *)
       (try
          if Keeper_memory_os_edges.writes_enabled ()
          then
            Keeper_memory_os_io.append_edges
              ~keeper_id
              (Keeper_memory_os_edges.co_occurrence_edges episode)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "memory os edge write failed keeper=%s: %s"
            keeper_id
            (Printexc.to_string exn));
       Ok episode
     | Error message -> Error ("memory os fact upsert failed: " ^ message))
;;

let provider_for_runtime ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some rt -> Ok rt.Runtime.provider_config
  | None ->
    (match Runtime.get_default_runtime () with
     | Some rt -> Ok rt.Runtime.provider_config
     | None -> Error "no runtime configured for librarian extraction")
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
             match
               with_provider_slot ?clock (fun () ->
                 extract_and_append_with_provider
                   ?complete
                   ?clock
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
                   [ "keeper", keeper_id; "site", "memory_os_librarian_provider_slot" ]
                 ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian skipped runtime=%s: global provider slot busy (capacity=%d)"
                 runtime_id
                 (global_slot_capacity ())
             | Some (Ok episode) ->
               (* Only a successful write resets the cadence. Skipped or failed
                  attempts leave the keeper due on the next turn. *)
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
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian failed runtime=%s: %s"
                 runtime_id
                 err))
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
