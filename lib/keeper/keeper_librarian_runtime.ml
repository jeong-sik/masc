(** Runtime adapter for Memory OS librarian extraction. *)

module Exact_output = Agent_sdk.Exact_output

let exact_lane_id = "librarian_exact"

(* RFC-0257 / P0-4 adversarial hardening: per-keeper librarian provider slot.
   The previous process-global slot allowed one slow keeper to starve the fleet.
   Capacity is still read from [MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT]
   (default 1), but the nonblocking slot is keyed by [keeper_id] so each keeper
   gets its own concurrency budget. A capacity of 0 disables the gate entirely. *)
let per_keeper_slot_capacity () =
  Env_config.KeeperMemoryOs.librarian_global_slot ()
;;

let memory_os_librarian_provider_slot_site = "memory_os_librarian_provider_slot"

type provider_slot =
  { capacity : int
  ; mutable in_use : int
  }

let provider_slots_mu = Eio.Mutex.create ()
let provider_slots : (string, provider_slot) Hashtbl.t = Hashtbl.create 64
let exact_flow_mutexes : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 64

let provider_slot_for_keeper ~keeper_id capacity =
  Eio_guard.with_mutex provider_slots_mu (fun () ->
    match Hashtbl.find_opt provider_slots keeper_id with
    | Some slot when slot.capacity = capacity -> slot
    | _ ->
      let slot = { capacity; in_use = 0 } in
      Hashtbl.replace provider_slots keeper_id slot;
      slot)
;;

let exact_flow_mutex_for_keeper ~keeper_id =
  Eio_guard.with_mutex provider_slots_mu (fun () ->
    match Hashtbl.find_opt exact_flow_mutexes keeper_id with
    | Some mutex -> mutex
    | None ->
      let mutex = Eio.Mutex.create () in
      Hashtbl.replace exact_flow_mutexes keeper_id mutex;
      mutex)
;;

let with_provider_slot ~keeper_id ~clock:_ f =
  let capacity = per_keeper_slot_capacity () in
  let slot = provider_slot_for_keeper ~keeper_id capacity in
  if capacity = 0
  then Some (f ())
  else
    let acquired =
      Eio_guard.with_mutex provider_slots_mu (fun () ->
        if slot.in_use >= slot.capacity
        then false
        else (
          slot.in_use <- slot.in_use + 1;
          true))
    in
    if not acquired
    then None
    else
      Fun.protect
        ~finally:(fun () ->
          Eio_guard.with_mutex provider_slots_mu (fun () ->
            slot.in_use <- Int.max 0 (slot.in_use - 1)))
        (fun () -> Some (f ()))
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

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

type exact_setup_error =
  | Exact_registry_unavailable of Runtime_exact_output_registry.publication_error
  | Exact_lane_unavailable of Runtime_exact_output_registry.lane_resolution_error
  | Exact_candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Exact_journal_unavailable of string
  | Exact_previous_attempt_unsettled of
      { state : string
      ; trace_id : string
      ; generation : int
      }
  | Exact_flow_admission_failed of Exact_output.flow_admission_error
  | Exact_flow_start_failed of Exact_output.flow_start_error

type exact_execution_failure =
  | Exact_attempt_already_started
  | Exact_callback_persistence_failed of string
  | Exact_provider_execution_failed of Exact_output.execution_error_cause

type exact_execution_error =
  { dispatched : bool
  ; failure : exact_execution_failure
  }

type extraction_error =
  | Prompt_render_failed of string
  | Provider_clock_unavailable
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Provider_unparseable_response of string
  | Memory_fact_upsert_failed of string

let librarian_provider_clock_unavailable_error =
  "memory os librarian provider clock unavailable"
;;

let execution_error_cause_to_string = function
  | Exact_output.Attempt_already_started -> "attempt_already_started"
  | Clock_required_for_timeout -> "clock_required_for_timeout"
  | Frozen_request_mismatch -> "frozen_request_mismatch"
  | Completion_failed -> "completion_failed"
  | Incomplete_output -> "incomplete_output"
  | Missing_output -> "missing_output"
  | Ambiguous_output count -> Printf.sprintf "ambiguous_output(%d)" count
  | Unexpected_output_content -> "unexpected_output_content"
  | Invalid_json_output -> "invalid_json_output"
  | Internal_non_json_output -> "internal_non_json_output"
;;

let exact_setup_error_to_string = function
  | Exact_registry_unavailable error ->
    "exact registry unavailable: "
    ^ Runtime_exact_output_registry.publication_error_to_string error
  | Exact_lane_unavailable error ->
    Runtime_exact_output_registry.lane_resolution_error_to_string error
  | Exact_candidate_invalid { position; slot_id } ->
    Printf.sprintf
      "exact lane candidate invalid position=%d slot=%S"
      position
      slot_id
  | Exact_journal_unavailable detail ->
    "exact receipt journal unavailable: " ^ detail
  | Exact_previous_attempt_unsettled { state; trace_id; generation } ->
    Printf.sprintf
      "previous exact attempt is unsettled state=%s trace_id=%s generation=%d"
      state
      trace_id
      generation
  | Exact_flow_admission_failed
      (Exact_output.Duplicate_flow_candidate_id
         { candidate_id; first_position; duplicate_position }) ->
    Printf.sprintf
      "exact flow duplicate candidate id=%S first_position=%d duplicate_position=%d"
      candidate_id
      first_position
      duplicate_position
  | Exact_flow_admission_failed (No_admitted_flow_candidates admissions) ->
    Printf.sprintf
      "exact flow has no admitted candidates (candidates=%d)"
      (List.length admissions)
  | Exact_flow_start_failed
      (Exact_output.Flow_candidate_attempt_start_failed
         { identity; position; cause; admissions = _ }) ->
    let detail =
      match cause with
      | Exact_output.Call_id_generation_failed detail -> detail
    in
    Printf.sprintf
      "exact flow attempt start failed candidate=%S position=%d: %s"
      identity.candidate_id
      position
      detail
;;

let extraction_error_to_string = function
  | Prompt_render_failed msg -> msg
  | Provider_clock_unavailable -> librarian_provider_clock_unavailable_error
  | Exact_setup_failed error -> exact_setup_error_to_string error
  | Exact_execution_failed { dispatched; failure } ->
    let detail =
      match failure with
      | Exact_attempt_already_started -> "attempt_already_started"
      | Exact_callback_persistence_failed detail ->
        "callback_persistence_failed: " ^ detail
      | Exact_provider_execution_failed cause ->
        execution_error_cause_to_string cause
    in
    Printf.sprintf
      "librarian exact execution failed dispatched=%b cause=%s"
      dispatched
      detail
  | Provider_unparseable_response msg ->
    "librarian provider returned unparseable structured response: " ^ msg
  | Memory_fact_upsert_failed msg -> "memory os fact upsert failed: " ^ msg
;;

let should_record_cadence_backoff_after_error = function
  | Exact_execution_failed { dispatched; _ } -> dispatched
  | Exact_setup_failed (Exact_previous_attempt_unsettled _) -> true
  | Provider_unparseable_response _ -> true
  | Provider_clock_unavailable
  | Prompt_render_failed _
  | Exact_setup_failed _
  | Memory_fact_upsert_failed _ ->
    false
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

let effect_phase_to_string = function
  | Exact_output.Not_started -> "not_started"
  | Before_dispatch -> "before_dispatch"
  | Dispatch_started -> "dispatch_started"
  | Response_received -> "response_received"
  | Terminal -> "terminal"
;;

let receipt_json (receipt : Exact_output.receipt) =
  `Assoc
    [ ( "call_id"
      , `String
          (Exact_output.call_id_to_string
             (Exact_output.receipt_call_id receipt)) )
    ; "phase", `String (effect_phase_to_string (Exact_output.receipt_phase receipt))
    ; "dispatch_count", `Int (Exact_output.receipt_dispatch_count receipt)
    ; ( "http_status"
      , match Exact_output.receipt_http_status receipt with
        | Some status -> `Int status
        | None -> `Null )
    ; "plan_fingerprint", `String (Exact_output.receipt_plan_fingerprint receipt)
    ; "request_body_sha256", `String (Exact_output.receipt_request_body_sha256 receipt)
    ; ( "catalog_generation"
      , `String
          (Exact_output.catalog_generation_fingerprint
             (Exact_output.receipt_catalog_generation receipt)) )
    ; ( "catalog_evidence_sha256"
      , `String
          (Exact_output.catalog_evidence_sha256
             (Exact_output.receipt_catalog_evidence receipt)) )
    ; ( "target_identity"
      , `String
          (Exact_output.target_identity_fingerprint
             (Exact_output.receipt_target_identity receipt)) )
    ]
;;

let attempt_receipt_json (attempt : Exact_output.flow_attempt_receipt) =
  `Assoc
    [ "candidate_id", `String attempt.identity.candidate_id
    ; "receipt", receipt_json attempt.receipt
    ]
;;

let exact_flow_state_dir ~keeper_id =
  Keeper_memory_os_io.facts_path ~keeper_id
  |> Filename.dirname
  |> fun keepers_dir -> Filename.concat keepers_dir keeper_id
  |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
;;

let exact_flow_state_path ~keeper_id =
  Filename.concat
    (exact_flow_state_dir ~keeper_id)
    "librarian-exact-state.json"
;;

let persist_exact_flow_state ~keeper_id ~trace_id ~generation ~state fields =
  let (_ : string) = Keeper_fs.ensure_dir (exact_flow_state_dir ~keeper_id) in
  let payload =
    `Assoc
      ([ "schema_version", `Int 1
       ; "trace_id", `String trace_id
       ; "generation", `Int generation
       ; "state", `String state
       ]
       @ fields)
    |> Yojson.Safe.pretty_to_string
  in
  Fs_compat.save_file_atomic_strict
    (exact_flow_state_path ~keeper_id)
    payload
;;

type exact_journal_disposition =
  | Journal_active
  | Journal_terminal

let exact_journal_disposition_of_state = function
  | "candidate_bound"
  | "candidate_advance_committed"
  | "oas_success" ->
    Ok Journal_active
  | "domain_valid"
  | "domain_invalid"
  | "execution_terminal" ->
    Ok Journal_terminal
  | state -> Error state
;;

let preflight_exact_flow_state ~keeper_id =
  let path = exact_flow_state_path ~keeper_id in
  if not (Sys.file_exists path)
  then Ok ()
  else
    try
      let json =
        In_channel.with_open_bin path In_channel.input_all
        |> Yojson.Safe.from_string
      in
      let open Yojson.Safe.Util in
      let state = json |> member "state" |> to_string in
      match exact_journal_disposition_of_state state with
      | Ok Journal_terminal -> Ok ()
      | Ok Journal_active ->
        Error
          (Exact_previous_attempt_unsettled
             { state
             ; trace_id = json |> member "trace_id" |> to_string
             ; generation = json |> member "generation" |> to_int
             })
      | Error state ->
        Error (Exact_journal_unavailable ("unknown state " ^ state))
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | exn -> Error (Exact_journal_unavailable (Printexc.to_string exn))
;;

let flow_candidates selected_slots =
  let rec loop position acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match Exact_output.make_flow_candidate ~id:slot.slot_id ~target:slot.target with
       | Ok candidate -> loop (position + 1) (candidate :: acc) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error
           (Exact_candidate_invalid
              { position
              ; slot_id = slot.slot_id
              }))
  in
  loop 0 [] selected_slots
;;

let exact_execution_error = function
  | Exact_output.Flow_attempt_already_started _ ->
    { dispatched = false; failure = Exact_attempt_already_started }
  | Flow_before_dispatch_callback_failed { candidate; cause; evidence = _ } ->
    { dispatched =
        Exact_output.receipt_dispatch_count candidate.receipt > 0
    ; failure = Exact_callback_persistence_failed cause
    }
  | Flow_before_advance_callback_failed
      { failed; failure = _; next = _; cause; evidence = _ } ->
    { dispatched =
        Exact_output.receipt_dispatch_count failed.receipt > 0
    ; failure = Exact_callback_persistence_failed cause
    }
  | Flow_exact_execution_failed { candidate = _; cause; evidence = _ } ->
    { dispatched = Exact_output.receipt_dispatch_count cause.receipt > 0
    ; failure = Exact_provider_execution_failed cause.cause
    }
;;

let persist_exact_execution_terminal
      ~keeper_id
      ~trace_id
      ~generation
      error
  =
  match error with
  | Exact_output.Flow_exact_execution_failed
      { candidate; cause; evidence = _ } ->
    persist_exact_flow_state
      ~keeper_id
      ~trace_id
      ~generation
      ~state:"execution_terminal"
      [ "candidate", attempt_receipt_json candidate
      ; "failure_cause", `String (execution_error_cause_to_string cause.cause)
      ]
  | Flow_attempt_already_started _ -> Ok ()
  | Flow_before_dispatch_callback_failed { cause; _ }
  | Flow_before_advance_callback_failed { cause; _ } ->
    Error cause
;;

let extract_with_exact_output_classified_unlocked
    ?clock
    ~net
    ~keeper_id
    ~generation
    (inp : Keeper_librarian.input)
  =
  match clock with
  | None -> Error Provider_clock_unavailable
  | Some clock ->
    (match messages_for_librarian inp with
     | Error msg -> Error (Prompt_render_failed msg)
     | Ok messages ->
       (match preflight_exact_flow_state ~keeper_id with
        | Error error -> Error (Exact_setup_failed error)
        | Ok () ->
       (match Runtime_exact_output_registry.current () with
        | Error error ->
          Error (Exact_setup_failed (Exact_registry_unavailable error))
        | Ok registry ->
          (match
             Runtime_exact_output_registry.resolve_lane registry ~lane_id:exact_lane_id
           with
           | Error error ->
             Error (Exact_setup_failed (Exact_lane_unavailable error))
           | Ok resolved ->
             (match flow_candidates resolved.selected_slots with
              | Error error -> Error (Exact_setup_failed error)
              | Ok [] ->
                Error
                  (Exact_setup_failed
                     (Exact_lane_unavailable
                        (No_usable_lane_slots
                           { lane_id = exact_lane_id
                           ; unavailable_slots = resolved.unavailable_slots
                           })))
              | Ok (first :: rest) ->
                let requirement =
                  Exact_output.make_output_requirement
                    ~schema:
                      Keeper_structured_output_schema.librarian_episode_output_schema
                    ~minimum_guarantee:Exact_output.Json_syntax
                in
                (match
                   Exact_output.admit_flow
                     ~first
                     ~rest
                     ~messages
                     requirement
                 with
                 | Error error ->
                   Error (Exact_setup_failed (Exact_flow_admission_failed error))
                 | Ok ready_flow ->
                   (match Exact_output.start_flow ready_flow with
                    | Error error ->
                      Error (Exact_setup_failed (Exact_flow_start_failed error))
                    | Ok attempt ->
                      (match
                         Exact_output.execute_flow_once
                           ~net
                           ~clock
                           ~before_dispatch:(fun candidate ->
                             persist_exact_flow_state
                               ~keeper_id
                               ~trace_id:inp.trace_id
                               ~generation
                               ~state:"candidate_bound"
                               [ "candidate", attempt_receipt_json candidate ])
                           ~before_advance:(fun ~failed ~failure ~next ->
                             persist_exact_flow_state
                               ~keeper_id
                               ~trace_id:inp.trace_id
                               ~generation
                               ~state:"candidate_advance_committed"
                               [ "failed_candidate", attempt_receipt_json failed
                               ; ( "failure_cause"
                                 , `String
                                     (execution_error_cause_to_string
                                        failure.cause) )
                               ; "next_candidate", attempt_receipt_json next
                               ])
                           attempt
                       with
                       | Error error ->
                         let classified = exact_execution_error error in
                         (match
                            persist_exact_execution_terminal
                              ~keeper_id
                              ~trace_id:inp.trace_id
                              ~generation
                              error
                          with
                          | Ok () ->
                            Error (Exact_execution_failed classified)
                          | Error detail ->
                            Error
                              (Exact_execution_failed
                                 { dispatched = classified.dispatched
                                 ; failure =
                                     Exact_callback_persistence_failed detail
                                 }))
                       | Ok success ->
                         (match
                            persist_exact_flow_state
                              ~keeper_id
                              ~trace_id:inp.trace_id
                              ~generation
                              ~state:"oas_success"
                              [ "candidate", attempt_receipt_json success.candidate ]
                          with
                          | Error detail ->
                            Error
                              (Exact_execution_failed
                                 { dispatched = true
                                 ; failure =
                                     Exact_callback_persistence_failed detail
                                 })
                          | Ok () ->
                            (match
                               Keeper_librarian.episode_of_json_result
                                 ~generation
                                 inp
                                 success.success.output
                             with
                             | Ok episode ->
                               (match
                                  persist_exact_flow_state
                                    ~keeper_id
                                    ~trace_id:inp.trace_id
                                    ~generation
                                    ~state:"domain_valid"
                                    [ ( "candidate"
                                      , attempt_receipt_json success.candidate )
                                    ]
                                with
                                | Ok () -> Ok episode
                                | Error detail ->
                                  Error
                                    (Exact_execution_failed
                                       { dispatched = true
                                       ; failure =
                                           Exact_callback_persistence_failed detail
                                       }))
                             | Error error ->
                               let parse_error =
                                 Keeper_librarian.parse_error_to_string error
                               in
                               (match
                                  persist_exact_flow_state
                                    ~keeper_id
                                    ~trace_id:inp.trace_id
                                    ~generation
                                    ~state:"domain_invalid"
                                    [ ( "candidate"
                                      , attempt_receipt_json success.candidate )
                                    ; "parse_error", `String parse_error
                                    ]
                                with
                                | Error detail ->
                                  Error
                                    (Exact_execution_failed
                                       { dispatched = true
                                       ; failure =
                                           Exact_callback_persistence_failed detail
                                       })
                                | Ok () ->
                                  Error
                                    (Provider_unparseable_response
                                       (Printf.sprintf
                                          "librarian provider returned invalid episode JSON (%s)"
                                          parse_error)))))))))))))
;;

let extract_with_exact_output_classified
      ?clock
      ~net
      ~keeper_id
      ~generation
      inp
  =
  Eio_guard.with_mutex
    (exact_flow_mutex_for_keeper ~keeper_id)
    (fun () ->
      extract_with_exact_output_classified_unlocked
        ?clock
        ~net
        ~keeper_id
        ~generation
        inp)
;;

let extract_with_exact_output
    ?clock
    ~net
    ~keeper_id
    ~generation
    inp
  =
  match
    extract_with_exact_output_classified
      ?clock
      ~net
      ~keeper_id
      ~generation
      inp
  with
  | Error err -> Error (extraction_error_to_string err)
  | Ok episode -> Ok episode
;;

let extract_and_append_with_exact_output_classified
    ?clock
    ~net
    ~keeper_id
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
       extract_with_exact_output_classified
         ?clock
         ~net
         ~keeper_id
         ~generation
         inp
     with
  | Error _ as e -> e
  | Ok episode ->
    let now = episode.Keeper_memory_os_types.created_at in
    (* RFC-0243: UPSERT claims into the fact store instead of blind-appending. A claim
       re-extracted across turns is folded into the existing row
       (Keeper_memory_os_policy.reobserve_fact refreshes [last_verified_at]
       only) rather than accumulating as a duplicate. Every resulting fact is
       preserved. Only after the facts are durable do we publish the episode file
       and append the event row; the event row is
       the reader-visible commit marker for [read_episodes_tail].

       RFC-0285 §8: before folding, decide each claim's provenance. A claim
       whose identity was recall-injected into this keeper's recent prompts is
       an echo — the model restating what it just read — and must not advance
       the truth anchor recall's recency ranking reads. The judgment (window
       join + metric) lives here at the write boundary; the fold itself stays
       a pure function of the decision. *)
    Keeper_memory_os_io.with_episode_bundle_lock ?clock ~keeper_id (fun () ->
      match
        try
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
            File_lock_eio.with_lock ?clock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
              Keeper_memory_os_io.merge_facts
                ~keeper_id
                ~merge
                ~incoming:episode.Keeper_memory_os_types.claims)
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
        Ok episode
      | Error message -> Error (Memory_fact_upsert_failed message)))
;;

let extract_and_append_with_exact_output
    ?clock
    ~net
    ~keeper_id
    inp
  =
  match
    extract_and_append_with_exact_output_classified
      ?clock
      ~net
      ~keeper_id
      inp
  with
  | Error err -> Error (extraction_error_to_string err)
  | Ok episode -> Ok episode
;;

let run_best_effort ~keeper_id (inp : Keeper_librarian.input) =
  (* [cadence_due] short-circuits after [enabled]: a disabled keeper never
     advances its cadence counter, and a not-due turn skips extraction entirely
     (the messages remain in the window for the next due turn). The cadence
     counter is scoped to the active trace so a rollover does not inherit the
     previous trace's schedule. *)
  if enabled () && cadence_due ~keeper_id ~trace_id:inp.trace_id
  then (
    try
      match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
      | Some net, Some clock ->
        (match
           with_provider_slot ~keeper_id ~clock (fun () ->
             extract_and_append_with_exact_output_classified
               ~clock
               ~net
               ~keeper_id
               inp)
         with
             | None ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string MemoryLaneProviderSlotBusy)
                ~labels:
                  [ "keeper", keeper_id; "site", memory_os_librarian_provider_slot_site ]
               ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian skipped lane=%s: per-keeper provider slot busy (capacity=%d)"
                 exact_lane_id
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
                 "memory os librarian failed lane=%s: %s; cadence deferred=%b"
                 exact_lane_id
                 (extraction_error_to_string err)
                 (should_record_cadence_backoff_after_error err))
      | _ ->
        Log.Keeper.warn ~keeper_name:keeper_id
          "memory os librarian skipped: Eio net/clock context unavailable lane=%s"
          exact_lane_id
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string EpisodeCreateFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      Log.Keeper.warn ~keeper_name:keeper_id
        "memory os librarian failed lane=%s: %s"
        exact_lane_id
        (Printexc.to_string exn))
;;
