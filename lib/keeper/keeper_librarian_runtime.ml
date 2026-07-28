(** Runtime adapter for Memory OS librarian extraction. *)

module Exact_output = Agent_sdk.Exact_output
module Recognition = Keeper_librarian_recognition
module Recognition_ledger = Keeper_librarian_recognition_ledger

let exact_lane_id = "librarian_exact"

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

(* The live table is dashboard instrumentation only. Provider admission must
   survive a process restart, so the authoritative counter lives beside the
   keeper's Memory OS files and is updated under a file lock. *)
let durable_cadence_path ~base_path ~keeper_id =
  Filename.concat
    (Filename.concat
       (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
       keeper_id)
    "librarian-cadence.json"
;;

(* The durable state pairs the counter with the trace it was accumulated in,
   mirroring the live table: a counter from a rotated trace must not schedule
   the new trace (see [cadence_step_keyed]). A legacy file that predates the
   trace field decodes as [(None, counter)] — treated as an unknown trace, so
   the next turn is fresh/due, never silently inheriting a stale schedule. *)
let durable_cadence_state_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "counter" fields with
     | Some (`Int counter) when counter >= fresh_counter ->
       (match List.assoc_opt "trace" fields with
        | Some (`String trace) -> Ok (Some trace, counter)
        | None | Some `Null -> Ok (None, counter)
        | Some _ -> Error "cadence state has non-string trace")
     | Some (`Int counter) ->
       Error (Printf.sprintf "cadence counter below %d: %d" fresh_counter counter)
     | _ -> Error "cadence state is missing integer counter")
  | _ -> Error "cadence state is not an object"
;;

let load_durable_cadence_state path =
  if not (Sys.file_exists path)
  then Ok (None, fresh_counter)
  else
    try
      let channel = open_in_bin path in
      let raw =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      durable_cadence_state_of_json (Yojson.Safe.from_string raw)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Printexc.to_string exn)
;;

let save_durable_cadence_state path (trace, counter) =
  Keeper_fs.save_json_atomic
    path
    (`Assoc [ "counter", `Int counter; "trace", `String trace ])
;;

let observe_live_cadence ~keeper_id ~counter =
  Eio_guard.with_mutex cadence_mu (fun () ->
    Hashtbl.replace cadence_counters keeper_id ("durable", counter))
;;

let update_durable_cadence ~base_path ~keeper_id update =
  let path = durable_cadence_path ~base_path ~keeper_id in
  try
    let _ = Keeper_fs.ensure_dir (Filename.dirname path) in
    File_lock_eio.with_lock path (fun () ->
      match load_durable_cadence_state path with
      | Error _ as error -> error
      | Ok prior ->
        let ((_, counter) as state), result = update prior in
        match save_durable_cadence_state path state with
        | Error _ as error -> error
        | Ok () ->
          observe_live_cadence ~keeper_id ~counter;
          Ok result)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)
;;

let durable_cadence_due ~base_path ~keeper_id ~trace_id =
  update_durable_cadence ~base_path ~keeper_id (fun (prior_trace, prior_counter) ->
    let prior =
      match prior_trace with
      | Some trace -> Some (trace, prior_counter)
      | None -> None
    in
    cadence_step_keyed ~cadence:(cadence_turns ()) ~current_trace:trace_id ~prior)
;;

let durable_cadence_record_completed_attempt ~base_path ~keeper_id ~trace_id =
  update_durable_cadence ~base_path ~keeper_id (fun _ -> (trace_id, 0), ())
;;

let record_completed_attempt ~base_path ~keeper_id ~trace_id =
  match durable_cadence_record_completed_attempt ~base_path ~keeper_id ~trace_id with
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.warn ~keeper_name:keeper_id
      "memory os librarian published, but durable cadence accounting failed: %s"
      detail
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
  | Exact_flow_snapshot_failed of Exact_output.flow_snapshot_error
  | Exact_flow_start_failed of Exact_output.flow_start_error

type exact_execution_failure =
  | Exact_attempt_already_started
  | Exact_callback_persistence_failed of string
  | Oas_execution_failed
  | Exact_flow_progress_failed of string
  | Exact_domain_settlement_failed

type outward_effect =
  | No_outward_effect
  | Outward_effect_started

type exact_execution_error =
  { outward_effect : outward_effect
  ; failure : exact_execution_failure
  }

type exact_flow_callback_error =
  | Callback_persistence_failed of string

type extraction_error =
  | Prompt_render_failed of string
  | Execution_clock_unavailable
  | Store_read_failed of string
  | Store_snapshot_changed of
      { snapshot : int
      ; current : int
      }
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Domain_output_invalid of string
  | Memory_apply_failed of string

type extraction_error_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Store_read_failure
  | Store_snapshot_change
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_apply_failure

let extraction_error_kind = function
  | Prompt_render_failed _ -> Prompt_render_failure
  | Execution_clock_unavailable -> Execution_clock_unavailable
  | Store_read_failed _ -> Store_read_failure
  | Store_snapshot_changed _ -> Store_snapshot_change
  | Exact_setup_failed _ -> Exact_setup_failure
  | Exact_execution_failed _ -> Exact_execution_failure
  | Domain_output_invalid _ -> Domain_output_invalid
  | Memory_apply_failed _ -> Memory_apply_failure
;;

let librarian_execution_clock_unavailable_error =
  "memory os librarian execution clock unavailable"
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
  | Exact_flow_snapshot_failed
      (Exact_output.Duplicate_flow_candidate_id
         { candidate_id; first_position; duplicate_position }) ->
    Printf.sprintf
      "exact flow duplicate candidate id=%S first_position=%d duplicate_position=%d"
      candidate_id
      first_position
      duplicate_position
  | Exact_flow_start_failed
      (Exact_output.Flow_id_generation_failed detail) ->
    "exact flow identity allocation failed: " ^ detail
;;

let extraction_error_to_string = function
  | Prompt_render_failed msg -> msg
  | Execution_clock_unavailable -> librarian_execution_clock_unavailable_error
  | Store_read_failed msg -> "memory os fact store read failed: " ^ msg
  | Store_snapshot_changed { snapshot; current } ->
    Printf.sprintf
      "memory os fact store changed during extraction (snapshot=%d current=%d); \
       operations abandoned"
      snapshot
      current
  | Exact_setup_failed error -> exact_setup_error_to_string error
  | Exact_execution_failed { outward_effect; failure } ->
    let detail =
      match failure with
      | Exact_attempt_already_started -> "attempt_already_started"
      | Exact_callback_persistence_failed detail ->
        "callback_persistence_failed: " ^ detail
      | Oas_execution_failed -> "oas_execution_failed"
      | Exact_flow_progress_failed detail ->
        "flow_progress_failed: " ^ detail
      | Exact_domain_settlement_failed ->
        "domain_settlement_failed"
    in
    Printf.sprintf
      "librarian exact execution failed outward_effect=%s cause=%s"
      (match outward_effect with
       | No_outward_effect -> "none"
       | Outward_effect_started -> "started")
      detail
  | Domain_output_invalid msg ->
    "librarian domain output invalid: " ^ msg
  | Memory_apply_failed msg -> "memory os recognition apply failed: " ^ msg
;;

let should_record_cadence_backoff_after_error = function
  | Exact_execution_failed { outward_effect = Outward_effect_started; _ } -> true
  | Exact_execution_failed { outward_effect = No_outward_effect; _ } -> false
  | Exact_setup_failed (Exact_previous_attempt_unsettled _) -> true
  | Domain_output_invalid _ -> true
  | Execution_clock_unavailable
  | Prompt_render_failed _
  | Store_read_failed _
    (* A concurrent writer invalidated the snapshot; the next turn re-reads a
       fresh store, so staying due is the correct retry. *)
  | Store_snapshot_changed _
  | Exact_setup_failed _
  | Memory_apply_failed _ ->
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

let input_for_librarian (inp : Keeper_librarian.input) =
  { inp with
    messages =
      select_recent_messages
        ~max_messages:(prompt_max_messages ())
        inp.messages
  }
;;

let messages_for_librarian (inp : Keeper_librarian.input) =
  let input = input_for_librarian inp in
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

let receipt_json (receipt : Exact_output.receipt) =
  `Assoc
    [ ( "call_id"
      , `String
          (Exact_output.call_id_to_string
             (Exact_output.receipt_call_id receipt)) )
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
    [ "candidate_id", `String attempt.visit.identity.candidate_id
    ; "receipt", receipt_json attempt.receipt
    ]
;;

let exact_flow_state_dir ~keeper_id =
  Keeper_memory_os_io.facts_path ~keeper_id
  |> Filename.dirname
  |> fun keepers_dir -> Filename.concat keepers_dir keeper_id
  |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
;;

let exact_flow_state_path ~keeper_id ~trace_id ~generation =
  let generation_key =
    String.concat "\000" [ trace_id; string_of_int generation ]
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  Filename.concat
    (exact_flow_state_dir ~keeper_id)
    ("librarian-exact-state-v2-" ^ generation_key ^ ".json")
;;

let persist_exact_flow_state ~keeper_id ~trace_id ~generation ~state fields =
  let (_ : string) = Keeper_fs.ensure_dir (exact_flow_state_dir ~keeper_id) in
  let payload =
    `Assoc
      ([ "schema_version", `Int 2
       ; "trace_id", `String trace_id
       ; "generation", `Int generation
       ; "state", `String state
       ]
       @ fields)
    |> Yojson.Safe.pretty_to_string
  in
  Fs_compat.save_file_atomic_strict
    (exact_flow_state_path ~keeper_id ~trace_id ~generation)
    payload
;;

type exact_journal_disposition =
  | Journal_active
  | Journal_terminal

let exact_journal_disposition_of_state = function
  | "flow_started"
  | "candidate_bound"
  | "candidate_advance_committed" ->
    Ok Journal_active
  (* The provider response is not resumable because its body is deliberately
     absent from the journal, but no Memory OS domain write has begun. A later
     cadence may therefore start a fresh exact-output flow safely. *)
  | "oas_success"
  | "domain_valid"
  | "domain_invalid"
  | "execution_terminal" ->
    Ok Journal_terminal
  | state -> Error state
;;

let preflight_exact_flow_state ~keeper_id ~trace_id ~generation =
  let path = exact_flow_state_path ~keeper_id ~trace_id ~generation in
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
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
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

let exact_execution_error error =
  let outward_effect =
    match Exact_output.flow_execution_error_generation_dispatch error with
    | Exact_output.No_generation_dispatch -> No_outward_effect
    | Exact_output.Generation_dispatch_started -> Outward_effect_started
  in
  let failure =
    match error with
    | Exact_output.Flow_attempt_already_started _ ->
      Exact_attempt_already_started
    | Flow_attempt_start_failed { cause; _ } ->
      let detail =
        match cause with
        | Exact_output.Call_id_generation_failed detail -> detail
      in
      Exact_flow_progress_failed ("attempt_start_failed: " ^ detail)
    | Flow_measurement_start_failed _
    | Flow_candidates_exhausted _ ->
      Exact_flow_progress_failed "candidates_exhausted"
    | Flow_before_measurement_dispatch_callback_failed { cause; _ }
    | Flow_measurement_terminal_callback_failed { cause; _ }
    | Flow_before_dispatch_callback_failed { cause; _ }
    | Flow_before_advance_callback_failed { cause; _ } ->
      (match cause with
       | Callback_persistence_failed detail ->
         Exact_callback_persistence_failed detail)
    | Flow_exact_execution_failed { cause; _ } ->
      ignore cause;
      Oas_execution_failed
  in
  { outward_effect; failure }
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
    ignore cause;
    persist_exact_flow_state
      ~keeper_id
      ~trace_id
      ~generation
      ~state:"execution_terminal"
      [ "candidate", attempt_receipt_json candidate
      ; "failure_cause", `String "oas_execution_failed"
      ]
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_candidates_exhausted _ ->
    persist_exact_flow_state
      ~keeper_id
      ~trace_id
      ~generation
      ~state:"execution_terminal"
      []
  | Flow_attempt_already_started _ -> Ok ()
  | Flow_before_measurement_dispatch_callback_failed { cause; _ }
  | Flow_measurement_terminal_callback_failed { cause; _ }
  | Flow_before_dispatch_callback_failed { cause; _ }
  | Flow_before_advance_callback_failed { cause; _ } ->
    (match cause with
     | Callback_persistence_failed detail -> Error detail)
;;

let extract_with_exact_output_classified_unlocked
    ?clock
    ~base_path
    ~net
    ~keeper_id
    ~generation
    (inp : Keeper_librarian.input)
  =
  let ( let* ) = Result.bind in
  let prepare_attempt messages =
    let* () =
      preflight_exact_flow_state
        ~keeper_id
        ~trace_id:inp.trace_id
        ~generation
      |> Result.map_error (fun error -> Exact_setup_failed error)
    in
    let* registry =
      Runtime_exact_output_registry.current ()
      |> Result.map_error (fun error ->
        Exact_setup_failed (Exact_registry_unavailable error))
    in
    let* resolved =
      Runtime_exact_output_registry.resolve_lane registry ~lane_id:exact_lane_id
      |> Result.map_error (fun error ->
        Exact_setup_failed (Exact_lane_unavailable error))
    in
    let* candidates =
      flow_candidates resolved.selected_slots
      |> Result.map_error (fun error -> Exact_setup_failed error)
    in
    match candidates with
    | [] ->
      Error
        (Exact_setup_failed
           (Exact_lane_unavailable
              (No_admitted_lane_slots { lane_id = exact_lane_id })))
    | first :: rest ->
      let requirement =
        Exact_output.make_output_requirement
          ~schema:Keeper_structured_output_schema.librarian_episode_output_schema
          ~minimum_guarantee:Exact_output.Json_syntax
      in
      let* snapshot =
        Exact_output.snapshot_flow ~first ~rest ~messages requirement
        |> Result.map_error (fun error ->
          Exact_setup_failed (Exact_flow_snapshot_failed error))
      in
      let* attempt =
        Exact_output.start_flow snapshot
        |> Result.map_error (fun error ->
          Exact_setup_failed (Exact_flow_start_failed error))
      in
      let* () =
        persist_exact_flow_state
          ~keeper_id
          ~trace_id:inp.trace_id
          ~generation
          ~state:"flow_started"
          []
        |> Result.map_error (fun detail ->
          Exact_setup_failed (Exact_journal_unavailable detail))
      in
      Ok attempt
  in
  let bound_candidate = ref None in
  let before_dispatch candidate =
    let result =
      let* () =
        match !bound_candidate with
        | None -> Ok ()
        | Some previous ->
          persist_exact_flow_state
            ~keeper_id
            ~trace_id:inp.trace_id
            ~generation
            ~state:"candidate_advance_committed"
            [ "candidate", attempt_receipt_json previous
            ; "failure_cause", `String "domain_invalid_output"
            ]
      in
      let* () =
        persist_exact_flow_state
          ~keeper_id
          ~trace_id:inp.trace_id
          ~generation
          ~state:"candidate_bound"
          [ "candidate", attempt_receipt_json candidate ]
      in
      bound_candidate := Some candidate;
      Ok ()
    in
    Result.map_error (fun detail -> Callback_persistence_failed detail) result
  in
  let before_advance ~failed ~next:_ =
    let result =
      match failed with
      | Exact_output.Flow_candidate_rejected _ -> Ok ()
      | Exact_output.Flow_candidate_execution_failed { candidate; cause } ->
        ignore cause;
        persist_exact_flow_state
          ~keeper_id
          ~trace_id:inp.trace_id
          ~generation
          ~state:"candidate_advance_committed"
          [ "candidate", attempt_receipt_json candidate
          ; "failure_cause", `String "oas_execution_failed"
          ]
    in
    let* () =
      Result.map_error (fun detail -> Callback_persistence_failed detail) result
    in
    bound_candidate := None;
    Ok ()
  in
  let terminalize_success success recognition =
    let candidate = Exact_output.flow_success_candidate success in
    let persistence_failure detail =
      Error
        (Exact_execution_failed
           { outward_effect = Outward_effect_started
           ; failure = Exact_callback_persistence_failed detail
           })
    in
    match
      persist_exact_flow_state
        ~keeper_id
        ~trace_id:inp.trace_id
        ~generation
        ~state:"oas_success"
        [ "candidate", attempt_receipt_json candidate ]
    with
    | Error detail -> persistence_failure detail
    | Ok () ->
      (match
         persist_exact_flow_state
           ~keeper_id
           ~trace_id:inp.trace_id
           ~generation
           ~state:"domain_valid"
           [ "candidate", attempt_receipt_json candidate ]
       with
       | Ok () -> Ok recognition
       | Error detail -> persistence_failure detail)
  in
  match clock with
  | None -> Error (Execution_clock_unavailable : extraction_error)
  | Some clock ->
    let validation_input = input_for_librarian inp in
    let* messages =
      messages_for_librarian validation_input
      |> Result.map_error (fun detail -> Prompt_render_failed detail)
    in
    let* attempt = prepare_attempt messages in
    let validate flow_success =
      let output = Exact_output.flow_success_output flow_success in
      match
        Keeper_librarian.recognition_output_of_json_result
          validation_input
          output.output
      with
      | Ok recognition -> Exact_output.Accept recognition
      | Error error -> Exact_output.Reject_and_advance error
    in
    match
      Exact_output.execute_flow_once
        ~net
        ~clock
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch
        ~before_advance
        ~validate
        attempt
    with
    | Error (Exact_output.Flow_execution_terminal { cause = error; _ }) ->
      let classified = exact_execution_error error in
      (match
         persist_exact_execution_terminal
           ~keeper_id
           ~trace_id:inp.trace_id
           ~generation
           error
       with
       | Ok () -> Error (Exact_execution_failed classified)
       | Error detail ->
         Error
           (Exact_execution_failed
              { outward_effect = classified.outward_effect
              ; failure = Exact_callback_persistence_failed detail
              }))
    | Error
        (Exact_output.Flow_semantic_candidates_exhausted { rejections; _ }) ->
      let rejection =
        List.fold_left
          (fun _ rejection -> rejection)
          rejections.first
          rejections.rest
      in
      let candidate =
        rejection.transport_success
        |> Exact_output.flow_success_candidate
      in
      let parse_error =
        Keeper_librarian.parse_error_to_string rejection.rejection
      in
      (match
         persist_exact_flow_state
           ~keeper_id
           ~trace_id:inp.trace_id
           ~generation
           ~state:"domain_invalid"
           [ "candidate", attempt_receipt_json candidate
           ; "parse_error", `String parse_error
           ]
       with
       | Error detail ->
         Error
           (Exact_execution_failed
              { outward_effect = Outward_effect_started
              ; failure = Exact_callback_persistence_failed detail
              })
       | Ok () ->
         Error
           (Domain_output_invalid
              (Printf.sprintf
                 "librarian exact output was not a valid episode (%s)"
                 parse_error)))
    | Ok success ->
      terminalize_success success.transport_success success.accepted
;;

let extract_with_exact_output_classified
      ?clock
      ~base_path
      ~net
      ~keeper_id
      ~generation
      inp
  =
  extract_with_exact_output_classified_unlocked
    ?clock
    ~base_path
    ~net
    ~keeper_id
    ~generation
    inp
;;

type recognition_write =
  | Recognized of Keeper_memory_os_types.episode

(* Apply an accepted recognition output and persist the whole bundle.

   Optimistic concurrency, mirroring the consolidation rewrite path: the store
   snapshot was read WITHOUT the lock before the provider call; here the facts
   lock is taken, the snapshot revalidated ([same_fact_snapshot]), and a stale
   snapshot abandons the operations as a typed [Store_snapshot_changed] — the
   indices the model emitted refer to rows a concurrent writer may have moved,
   so applying them would corrupt unrelated facts. The next due turn re-reads
   a fresh store.

   No programmable identity comparison participates (masc#26122): the model
   already judged what is known against the snapshot it saw; code only applies
   the typed operations and persists the evidence. *)
let apply_and_persist
    ?clock
    ~base_path
    ~keeper_id
    ~generation
    (inp : Keeper_librarian.input)
    (recognition : Keeper_librarian.recognition_output)
  =
  (* NDT-OK: application timestamps are provenance/retention metadata only. *)
  let now = Unix.gettimeofday () in
  let recognition_masc_root =
    Workspace_utils.masc_root_dir_from
      ~base_path
      ~cluster_name:(Env_config_core.cluster_name ())
  in
  let recover_pending current =
    match
      Recognition_ledger.recover_pending
        ~masc_root:recognition_masc_root
        ~keeper_id
        ~current_store:current
        ~now
        ()
    with
    | Ok _ -> Ok ()
    | Error detail ->
      Error
        (Memory_apply_failed
           ("recognition publication recovery failed: " ^ detail))
  in
  match recognition.Keeper_librarian.operations with
  | [] ->
    (* A schema-valid zero-op result still carries episode metadata authored
       for this conversation slice. Facts remain byte-identical, but the
       episode/event pair uses the same recoverable publication boundary. *)
    let episode =
      Keeper_librarian.episode_of_recognition
        ~now
        ~generation
        inp
        recognition
        ~recognized_facts:[]
        ~source_turns:[]
    in
    let recovered =
      Keeper_memory_os_io.with_recognition_fact_transaction
        ?clock
        ~masc_root:recognition_masc_root
        ~keeper_id
        ~on_timeout:(fun msg -> Error (Memory_apply_failed msg))
        (fun ~rewrite:_ ~masc_root:_ ->
             match Keeper_memory_os_io.read_facts_all_strict_offloaded ~keeper_id with
             | Error msg -> Error (Store_read_failed msg)
             | Ok current ->
               (match recover_pending current with
                | Error _ as error -> error
                | Ok () ->
                  let publication_id =
                    Recognition_ledger.publication_id
                      ~keeper_id
                      ~trace_id:inp.trace_id
                      ~generation
                      ~store_before:current
                      ~operations:[]
                      ~dispositions:[]
                      ~store_after:current
                      ~episode
                      ~facts_rewrite_required:false
                  in
                  (match
                     Recognition_ledger.publish
                       ~prepare:(fun () ->
                         Recognition_ledger.append_prepared
                           ~masc_root:recognition_masc_root
                           ~publication_id
                           ~keeper_id
                           ~trace_id:inp.trace_id
                           ~generation
                           ~store_before:current
                           ~operations:[]
                           ~dispositions:[]
                           ~store_after:current
                           ~episode
                           ~facts_rewrite_required:false
                           ~now
                           ())
                       ~rewrite:(fun () -> Ok ())
                       ~episode:(fun () ->
                         Keeper_memory_os_io.ensure_recognition_episode
                           ~keeper_id
                           ~publication_id
                           episode)
                       ~event:(fun () ->
                         Keeper_memory_os_io.ensure_recognition_event
                           ~keeper_id
                           ~publication_id
                           episode)
                       ~commit:(fun () ->
                         Recognition_ledger.append_committed
                           ~masc_root:recognition_masc_root
                           ~publication_id
                           ~keeper_id
                           ~trace_id:inp.trace_id
                           ~generation
                           ~now
                           ())
                   with
                   | Ok _ -> Ok ()
                   | Error (Recognition_ledger.Prepare_failed detail) ->
                     Error
                       (Memory_apply_failed
                          ("recognition prepare write failed: " ^ detail))
                   | Error (Recognition_ledger.Rewrite_failed detail) ->
                     Error
                       (Memory_apply_failed
                          ("recognition metadata transition failed: " ^ detail))
                   | Error (Recognition_ledger.Episode_failed detail) ->
                     Error
                       (Memory_apply_failed
                          ("recognition episode write failed: " ^ detail))
                   | Error (Recognition_ledger.Event_failed detail) ->
                     Error
                       (Memory_apply_failed
                          ("recognition event write failed after episode: " ^ detail))
                   | Error (Recognition_ledger.Commit_failed detail) ->
                     Error
                       (Memory_apply_failed
                          ("recognition commit marker failed; prepared \
                            publication remains recoverable: "
                           ^ detail)))))
    in
    (match recovered with
     | Error _ as error -> error
     | Ok () -> Ok (Recognized episode))
  | _ :: _ ->
    let applied =
      Keeper_memory_os_io.with_recognition_fact_transaction
        ?clock
        ~masc_root:recognition_masc_root
        ~keeper_id
        ~on_timeout:(fun msg -> Error (Memory_apply_failed msg))
        (fun ~rewrite ~masc_root:_ ->
             match Keeper_memory_os_io.read_facts_all_strict_offloaded ~keeper_id with
             | Error msg -> Error (Store_read_failed msg)
             | Ok current ->
               (match recover_pending current with
                | Error _ as error -> error
                | Ok () ->
                  if not (Keeper_memory_os_io.same_fact_snapshot inp.store current)
                  then
                    Error
                      (Store_snapshot_changed
                         { snapshot = List.length inp.store
                         ; current = List.length current
                         })
                  else (
                 let recalled_reinforcement_indices =
                   recognition.operations
                   |> List.filter_map (function
                     | Recognition.Reinforce { index; _ } ->
                       (match List.nth_opt inp.store index with
                        | Some fact
                          when
                            Keeper_recall_injection_window.recently_injected
                              ~keeper_id
                              ~key:(Keeper_memory_os_types.claim_identity fact) ->
                            Some index
                        | None | Some _ -> None)
                     | Recognition.Add _
                     | Recognition.Merge _
                     | Recognition.Revise _
                     | Recognition.Forget _ -> None)
                 in
                 let result =
                   Recognition.apply
                     ~recalled_reinforcement_indices
                     ~now
                     ~operations:recognition.operations
                     inp.store
                 in
                 let facts_rewrite_required =
                   List.exists
                     (function Recognition.Applied -> true | _ -> false)
                     result.Recognition.dispositions
                 in
                 let recalled_echo_only =
                   result.Recognition.dispositions <> []
                   && List.for_all
                        (function
                          | Recognition.Rejected_recalled_echo -> true
                          | Recognition.Applied
                          | Recognition.Rejected_index_out_of_bounds
                          | Recognition.Rejected_target_overlap
                          | Recognition.Rejected_target_consumed -> false)
                        result.Recognition.dispositions
                 in
                 if facts_rewrite_required || recalled_echo_only
                 then
                   let episode =
                     Keeper_librarian.episode_of_recognition
                       ~now
                       ~generation
                       inp
                       recognition
                       ~recognized_facts:result.Recognition.recognized_facts
                       ~source_turns:result.Recognition.applied_source_turns
                   in
                   let publication_id =
                     Recognition_ledger.publication_id
                       ~keeper_id
                       ~trace_id:inp.trace_id
                       ~generation
                       ~store_before:inp.store
                       ~operations:recognition.operations
                       ~dispositions:result.Recognition.dispositions
                       ~store_after:result.Recognition.facts
                       ~episode
                       ~facts_rewrite_required
                   in
                   (match
                      Recognition_ledger.publish
                        ~prepare:(fun () ->
                          Recognition_ledger.append_prepared
                            ~masc_root:recognition_masc_root
                            ~publication_id
                            ~keeper_id
                            ~trace_id:inp.trace_id
                            ~generation
                            ~store_before:inp.store
                            ~operations:recognition.operations
                            ~dispositions:result.Recognition.dispositions
                            ~store_after:result.Recognition.facts
                            ~episode
                            ~facts_rewrite_required
                            ~now
                            ())
                        ~rewrite:(fun () ->
                          if not facts_rewrite_required
                          then Ok ()
                          else
                            try
                              rewrite result.Recognition.facts;
                              Ok ()
                            with
                            | Eio.Cancel.Cancelled _ as exn -> raise exn
                            | exn -> Error (Printexc.to_string exn))
                        ~episode:(fun () ->
                          Keeper_memory_os_io.ensure_recognition_episode
                            ~keeper_id
                            ~publication_id
                            episode)
                        ~event:(fun () ->
                          Keeper_memory_os_io.ensure_recognition_event
                            ~keeper_id
                            ~publication_id
                            episode)
                        ~commit:(fun () ->
                          Recognition_ledger.append_committed
                            ~masc_root:recognition_masc_root
                            ~publication_id
                            ~keeper_id
                            ~trace_id:inp.trace_id
                            ~generation
                            ~now
                            ())
                    with
                    | Ok _ -> Ok episode
                    | Error (Recognition_ledger.Prepare_failed detail) ->
                      Error
                        (Memory_apply_failed
                           ("recognition prepare write failed: " ^ detail))
                    | Error (Recognition_ledger.Rewrite_failed detail) ->
                      Error
                        (Memory_apply_failed
                           ("recognition fact rewrite failed after prepare: "
                            ^ detail))
                    | Error (Recognition_ledger.Episode_failed detail) ->
                      Error
                        (Memory_apply_failed
                           ("recognition episode write failed after fact rewrite: "
                            ^ detail))
                    | Error (Recognition_ledger.Event_failed detail) ->
                      Error
                        (Memory_apply_failed
                           ("recognition event write failed after episode: " ^ detail))
                    | Error (Recognition_ledger.Commit_failed detail) ->
                      Error
                        (Memory_apply_failed
                           ("recognition commit marker failed; prepared \
                             publication remains recoverable: "
                            ^ detail)))
                 else
                   Error
                     (Domain_output_invalid
                        "recognition output applied no operations to the current store"))))
    in
    (match applied with
     | Error _ as error -> error
     | Ok episode -> Ok (Recognized episode))
;;

let persist_cadence_backoff ~should_defer ~write =
  if not should_defer
  then Ok false
  else
    match write () with
    | Ok () -> Ok true
    | Error detail -> Error detail
;;

let reserve_recognition_input ~keeper_id (inp : Keeper_librarian.input) =
  let generation =
    Keeper_memory_os_io.next_generation_with_floor
      ~floor:inp.generation
      ~keeper_id
      ~trace_id:inp.trace_id
  in
  generation, { inp with Keeper_librarian.generation }
;;

module For_testing = struct
  let apply_and_persist = apply_and_persist
  let persist_cadence_backoff = persist_cadence_backoff
  let reserve_recognition_input = reserve_recognition_input
end

let extract_and_append_with_exact_output_classified
    ?clock
    ~base_path
    ~net
    ~keeper_id
    inp
  : (recognition_write, extraction_error) result =
  match clock with
  | None -> Error Execution_clock_unavailable
  | Some _ ->
    (* The store snapshot is read here, outside any lock, and rides the input
       into both the prompt (numbered rendering) and the post-provider CAS
       revalidation in [apply_and_persist]. Offloaded: a large fact file must
       not run blocking channel IO on the calling Eio fiber. *)
    (match Keeper_memory_os_io.read_facts_all_strict_offloaded ~keeper_id with
     | Error msg -> Error (Store_read_failed msg)
     | Ok store ->
       let inp = { inp with Keeper_librarian.store } in
       let generation, inp = reserve_recognition_input ~keeper_id inp in
       (match
          extract_with_exact_output_classified
            ?clock
            ~base_path
            ~net
            ~keeper_id
            ~generation
            inp
        with
        | Error _ as error -> error
        | Ok recognition ->
          apply_and_persist
            ?clock
            ~base_path
            ~keeper_id
            ~generation
            inp
            recognition))
;;

let run_best_effort ~base_path ~keeper_id (inp : Keeper_librarian.input) =
  (* Disabled keepers do not touch cadence. A failed durable read/write is an
     admission failure, not an excuse to resume per-turn provider requests. *)
  if enabled () then
    match durable_cadence_due ~base_path ~keeper_id ~trace_id:inp.trace_id with
    | Error detail ->
      Log.Keeper.warn ~keeper_name:keeper_id
        "memory os librarian skipped: durable cadence state unavailable: %s"
        detail
    | Ok false -> ()
    | Ok true ->
    try
      match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
      | Some net, Some clock ->
        (match
           extract_and_append_with_exact_output_classified
             ~clock
             ~base_path
             ~net
             ~keeper_id
             inp
         with
         | Ok (Recognized episode) ->
           record_completed_attempt ~base_path ~keeper_id ~trace_id:inp.trace_id;
           Log.Keeper.info
             ~keeper_name:keeper_id
             "memory os librarian wrote episode trace_id=%s generation=%d claims=%d"
             episode.Keeper_memory_os_types.trace_id
             episode.generation
             (List.length episode.claims)
         | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string EpisodeCreateFailures)
             ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
             ();
           (* deferred=true only once the backoff counter reset is durably
              written: a discarded write failure would log "deferred" while
              the counter stays due, re-dispatching on the very next turn. *)
           let deferred =
             match
               persist_cadence_backoff
                 ~should_defer:(should_record_cadence_backoff_after_error err)
                 ~write:(fun () ->
                   durable_cadence_record_completed_attempt
                     ~base_path
                     ~keeper_id
                     ~trace_id:inp.trace_id)
             with
             | Ok deferred -> deferred
             | Error detail ->
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "memory os librarian cadence backoff write failed: %s"
                 detail;
               false
           in
           Log.Keeper.warn
             ~keeper_name:keeper_id
             "memory os librarian failed lane=%s: %s; cadence deferred=%b"
             exact_lane_id
             (extraction_error_to_string err)
             deferred)
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
        (Printexc.to_string exn)
;;
