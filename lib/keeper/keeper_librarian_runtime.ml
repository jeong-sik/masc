(** Runtime adapter for Memory OS librarian extraction. *)

module Exact_output = Agent_sdk.Exact_output

let exact_lane_id = "librarian_exact"

let input_trace_id (inp : Keeper_librarian.input) =
  Ids.Turn_ref.trace_id inp.turn_ref
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
  | Exact_trace_id_invalid
  | Exact_generation_invalid of int
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

type outward_effect =
  | No_outward_effect
  | Outward_effect_started

type exact_execution_error =
  { outward_effect : outward_effect
  ; failure : exact_execution_failure
  }

type exact_flow_callback_error =
  | Callback_persistence_failed of string

type memory_publication_phase =
  | Publication_bundle_lock
  | Publication_facts
  | Publication_episode
  | Publication_event

type extraction_error =
  | Prompt_render_failed of string
  | Execution_clock_unavailable
  | Exact_setup_failed of exact_setup_error
  | Exact_execution_failed of exact_execution_error
  | Domain_output_invalid of string
  | Memory_publication_failed of
      { phase : memory_publication_phase
      ; detail : string
      }

type extraction_error_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_publication_failure

let extraction_error_kind = function
  | Prompt_render_failed _ -> Prompt_render_failure
  | Execution_clock_unavailable -> Execution_clock_unavailable
  | Exact_setup_failed _ -> Exact_setup_failure
  | Exact_execution_failed _ -> Exact_execution_failure
  | Domain_output_invalid _ -> Domain_output_invalid
  | Memory_publication_failed _ -> Memory_publication_failure
;;

let librarian_execution_clock_unavailable_error =
  "memory os librarian execution clock unavailable"
;;

let memory_publication_phase_to_string = function
  | Publication_bundle_lock -> "bundle_lock"
  | Publication_facts -> "facts"
  | Publication_episode -> "episode"
  | Publication_event -> "event"
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
  | Exact_trace_id_invalid -> "exact trace_id must be non-empty"
  | Exact_generation_invalid generation ->
    Printf.sprintf "exact generation must be non-negative, got %d" generation
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
    in
    Printf.sprintf
      "librarian exact execution failed outward_effect=%s cause=%s"
      (match outward_effect with
       | No_outward_effect -> "none"
       | Outward_effect_started -> "started")
      detail
  | Domain_output_invalid msg ->
    "librarian domain output invalid: " ^ msg
  | Memory_publication_failed { phase; detail } ->
    Printf.sprintf
      "memory os publication failed phase=%s: %s"
      (memory_publication_phase_to_string phase)
      detail
;;

let should_record_cadence_backoff_after_error = function
  | Exact_execution_failed { outward_effect = Outward_effect_started; _ } -> true
  | Exact_execution_failed { outward_effect = No_outward_effect; _ } -> false
  | Exact_setup_failed (Exact_previous_attempt_unsettled _) -> true
  | Domain_output_invalid _ -> true
  | Execution_clock_unavailable
  | Prompt_render_failed _
  | Exact_setup_failed _
  | Memory_publication_failed _ ->
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

let prepare_librarian_prompt (inp : Keeper_librarian.input) =
  let source_input =
    { inp with messages = select_recent_messages ~max_messages:(prompt_max_messages ()) inp.messages }
  in
  match render_prompt Keeper_prompt_names.librarian_system [] with
  | Error _ as e -> e
  | Ok system ->
    (match
       render_prompt
         Keeper_prompt_names.librarian_episode_extraction
         (Keeper_librarian.prompt_variables source_input)
     with
     | Error _ as e -> e
     | Ok user ->
       Ok
         ( source_input
         , [ message Agent_sdk.Types.System system
           ; message Agent_sdk.Types.User user
           ] ))
;;

let messages_for_librarian inp =
  Result.map snd (prepare_librarian_prompt inp)
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

type exact_journal_state =
  | Exact_flow_started
  | Exact_candidate_bound of Yojson.Safe.t
  | Exact_candidate_advance_committed of
      { candidate : Yojson.Safe.t
      ; failure_cause : string
      }
  | Exact_oas_success of Yojson.Safe.t
  | Exact_domain_valid of Yojson.Safe.t
  | Exact_domain_invalid of
      { candidate : Yojson.Safe.t
      ; parse_error : string
      }
  | Exact_execution_terminal of
      { candidate : Yojson.Safe.t option
      ; failure_cause : string option
      }

let exact_journal_state_label = function
  | Exact_flow_started -> "flow_started"
  | Exact_candidate_bound _ -> "candidate_bound"
  | Exact_candidate_advance_committed _ -> "candidate_advance_committed"
  | Exact_oas_success _ -> "oas_success"
  | Exact_domain_valid _ -> "domain_valid"
  | Exact_domain_invalid _ -> "domain_invalid"
  | Exact_execution_terminal _ -> "execution_terminal"
;;

let exact_journal_state_fields state =
  let state_field = "state", `String (exact_journal_state_label state) in
  match state with
  | Exact_flow_started -> [ state_field ]
  | Exact_candidate_bound candidate
  | Exact_oas_success candidate
  | Exact_domain_valid candidate ->
    [ state_field; "candidate", candidate ]
  | Exact_candidate_advance_committed { candidate; failure_cause } ->
    [ state_field
    ; "candidate", candidate
    ; "failure_cause", `String failure_cause
    ]
  | Exact_domain_invalid { candidate; parse_error } ->
    [ state_field
    ; "candidate", candidate
    ; "parse_error", `String parse_error
    ]
  | Exact_execution_terminal { candidate; failure_cause } ->
    [ state_field ]
    @ (match candidate with
       | Some candidate -> [ "candidate", candidate ]
       | None -> [])
    @ (match failure_cause with
       | Some failure_cause -> [ "failure_cause", `String failure_cause ]
       | None -> [])
;;

let exact_flow_state_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir keeper_id
  |> fun keeper_dir -> Filename.concat keeper_dir "exact-output"
;;

let exact_trace_key trace_id =
  trace_id
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id =
  Filename.concat
    (exact_flow_state_dir ~keepers_dir ~keeper_id)
    (exact_trace_key trace_id)
;;

let exact_flow_state_path ~keepers_dir ~keeper_id ~trace_id ~generation =
  Filename.concat
    (exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id)
    (Printf.sprintf "librarian-exact-state-%d.json" generation)
;;

let persist_exact_flow_state ~keepers_dir ~keeper_id ~trace_id ~generation state =
  let (_ : string) =
    Keeper_fs.ensure_dir
      (exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id)
  in
  let payload =
    `Assoc
      ([ "trace_id", `String trace_id
       ; "generation", `Int generation
       ]
       @ exact_journal_state_fields state)
    |> Yojson.Safe.pretty_to_string
  in
  Fs_compat.save_file_atomic_strict
    (exact_flow_state_path ~keepers_dir ~keeper_id ~trace_id ~generation)
    payload
;;

type exact_journal_disposition =
  | Journal_active
  | Journal_terminal

let exact_journal_disposition_of_state = function
  | Exact_flow_started
  | Exact_candidate_bound _
  | Exact_candidate_advance_committed _ ->
    Journal_active
  (* The provider response is not resumable because its body is deliberately
     absent from the journal, but no Memory OS domain write has begun. A later
     cadence may therefore start a fresh exact-output flow safely. *)
  | Exact_oas_success _
  | Exact_domain_valid _
  | Exact_domain_invalid _
  | Exact_execution_terminal _ ->
    Journal_terminal
;;

let exact_fields fields expected =
  List.length fields = List.length expected
  && List.for_all (fun expected_field -> List.mem_assoc expected_field fields) expected
;;

let exact_string_field field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when not (String.equal value "") -> Some value
  | Some _ | None -> None
;;

let exact_int_field field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) -> Some value
  | Some _ | None -> None
;;

let exact_nullable_int_field field fields =
  match List.assoc_opt field fields with
  | Some (`Int _ | `Null) -> true
  | Some _ | None -> false
;;

let exact_receipt_json = function
  | `Assoc fields ->
    exact_fields
      fields
      [ "call_id"
      ; "http_status"
      ; "plan_fingerprint"
      ; "request_body_sha256"
      ; "catalog_generation"
      ; "catalog_evidence_sha256"
      ; "target_identity"
      ]
    && Option.is_some (exact_string_field "call_id" fields)
    && exact_nullable_int_field "http_status" fields
    && Option.is_some (exact_string_field "plan_fingerprint" fields)
    && Option.is_some (exact_string_field "request_body_sha256" fields)
    && Option.is_some (exact_string_field "catalog_generation" fields)
    && Option.is_some (exact_string_field "catalog_evidence_sha256" fields)
    && Option.is_some (exact_string_field "target_identity" fields)
  | _ -> false
;;

let exact_candidate_field field fields =
  match List.assoc_opt field fields with
  | Some (`Assoc candidate_fields as value)
    when exact_fields candidate_fields [ "candidate_id"; "receipt" ]
         && Option.is_some
              (exact_string_field "candidate_id" candidate_fields)
         && (match List.assoc_opt "receipt" candidate_fields with
             | Some receipt -> exact_receipt_json receipt
             | None -> false) ->
    Some value
  | Some _ | None -> None
;;

let decode_exact_journal_state fields =
  match exact_string_field "state" fields with
  | Some "flow_started" when exact_fields fields [ "trace_id"; "generation"; "state" ] ->
    Some Exact_flow_started
  | Some "candidate_bound"
    when exact_fields fields [ "trace_id"; "generation"; "state"; "candidate" ] ->
    Option.map
      (fun candidate -> Exact_candidate_bound candidate)
      (exact_candidate_field "candidate" fields)
  | Some "candidate_advance_committed"
    when
      exact_fields
        fields
        [ "trace_id"; "generation"; "state"; "candidate"; "failure_cause" ] ->
    (match
       exact_candidate_field "candidate" fields
       , exact_string_field "failure_cause" fields
     with
     | Some candidate, Some failure_cause ->
       Some (Exact_candidate_advance_committed { candidate; failure_cause })
     | _ -> None)
  | Some "oas_success"
    when exact_fields fields [ "trace_id"; "generation"; "state"; "candidate" ] ->
    Option.map
      (fun candidate -> Exact_oas_success candidate)
      (exact_candidate_field "candidate" fields)
  | Some "domain_valid"
    when exact_fields fields [ "trace_id"; "generation"; "state"; "candidate" ] ->
    Option.map
      (fun candidate -> Exact_domain_valid candidate)
      (exact_candidate_field "candidate" fields)
  | Some "domain_invalid"
    when
      exact_fields
        fields
        [ "trace_id"; "generation"; "state"; "candidate"; "parse_error" ] ->
    (match exact_candidate_field "candidate" fields, exact_string_field "parse_error" fields with
     | Some candidate, Some parse_error ->
       Some (Exact_domain_invalid { candidate; parse_error })
     | _ -> None)
  | Some "execution_terminal"
    when exact_fields fields [ "trace_id"; "generation"; "state" ] ->
    Some (Exact_execution_terminal { candidate = None; failure_cause = None })
  | Some "execution_terminal"
    when
      exact_fields
        fields
        [ "trace_id"; "generation"; "state"; "candidate"; "failure_cause" ] ->
    (match
       exact_candidate_field "candidate" fields
       , exact_string_field "failure_cause" fields
     with
     | Some candidate, Some failure_cause ->
       Some
         (Exact_execution_terminal
            { candidate = Some candidate; failure_cause = Some failure_cause })
     | _ -> None)
  | Some _
  | None -> None
;;

type exact_journal =
  { trace_id : string
  ; generation : int
  ; state : exact_journal_state
  }

let decode_exact_journal_identity = function
  | `Assoc fields ->
    (match
       exact_string_field "trace_id" fields
       , exact_int_field "generation" fields
       , decode_exact_journal_state fields
     with
     | Some trace_id, Some generation, Some state ->
       Ok { trace_id; generation; state }
     | _ -> Error "journal does not match the current closed shape")
  | _ -> Error "journal must be a JSON object"
;;

let decode_exact_journal ~trace_id ~generation json =
  match decode_exact_journal_identity json with
  | Error _ as error -> error
  | Ok journal ->
    if not (String.equal journal.trace_id trace_id)
    then
       Error
         (Printf.sprintf
            "journal trace mismatch: expected=%S actual=%S"
            trace_id
            journal.trace_id)
    else if not (Int.equal journal.generation generation)
    then
      Error
        (Printf.sprintf
           "journal generation mismatch: expected=%d actual=%d"
           generation
           journal.generation)
    else Ok journal.state
;;

let preflight_exact_flow_state ~keepers_dir ~keeper_id ~trace_id ~generation =
  let path =
    exact_flow_state_path ~keepers_dir ~keeper_id ~trace_id ~generation
  in
  if not (Sys.file_exists path)
  then Ok ()
  else
    try
      let json =
        In_channel.with_open_bin path In_channel.input_all
        |> Yojson.Safe.from_string
      in
      match decode_exact_journal ~trace_id ~generation json with
      | Error detail -> Error (Exact_journal_unavailable detail)
      | Ok state ->
        (match exact_journal_disposition_of_state state with
         | Journal_terminal -> Ok ()
         | Journal_active ->
           Error
             (Exact_previous_attempt_unsettled
                { state = exact_journal_state_label state
                ; trace_id
                ; generation
                }))
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | exn -> Error (Exact_journal_unavailable (Printexc.to_string exn))
;;

let exact_trace_lock_path ~keepers_dir ~keeper_id ~trace_id =
  Filename.concat
    (exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id)
    "librarian-exact-trace"
;;

let exact_journal_paths ~keepers_dir ~keeper_id ~trace_id =
  let dir =
    exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id
  in
  if not (Sys.file_exists dir)
  then Ok []
  else
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun name ->
        String.equal (Filename.extension name) ".json")
      |> List.sort String.compare
      |> List.map (Filename.concat dir)
      |> fun paths -> Ok paths
    with
    | Eio.Cancel.Cancelled _ as error -> raise error
    | Sys_error detail -> Error detail
;;

let read_exact_journal path =
  try
    In_channel.with_open_bin path In_channel.input_all
    |> Yojson.Safe.from_string
    |> decode_exact_journal_identity
    |> Result.map_error (fun detail ->
      Printf.sprintf "%s: %s" path detail)
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Sys_error detail -> Error (Printf.sprintf "%s: %s" path detail)
  | Yojson.Json_error detail -> Error (Printf.sprintf "%s: %s" path detail)
;;

let discover_active_exact_generation_blocking
      ~keepers_dir
      ~keeper_id
      ~trace_id
  =
  let ( let* ) = Result.bind in
  let* paths =
    exact_journal_paths ~keepers_dir ~keeper_id ~trace_id
  in
  let* active =
    List.fold_left
      (fun result path ->
         let* active = result in
         let* journal = read_exact_journal path in
         if not (String.equal journal.trace_id trace_id)
         then
           Error
             (Printf.sprintf
                "%s: journal trace mismatch inside trace authority directory"
                path)
         else
           let canonical_path =
             exact_flow_state_path
               ~keepers_dir
               ~keeper_id
               ~trace_id
               ~generation:journal.generation
           in
           if not (String.equal path canonical_path)
           then
             Error
               (Printf.sprintf
                  "%s: journal path does not match decoded generation"
                  path)
           else if
             exact_journal_disposition_of_state journal.state = Journal_active
           then Ok ((path, journal.generation) :: active)
           else Ok active)
      (Ok [])
      paths
  in
  match active with
  | [] -> Ok None
  | [ _, generation ] -> Ok (Some generation)
  | active ->
    let evidence =
      active
      |> List.rev
      |> List.map (fun (path, generation) ->
        Printf.sprintf "%s:g%d" path generation)
      |> String.concat ","
    in
    Error
      (Printf.sprintf
         "multiple active exact journals for trace_id=%S: %s"
         trace_id
         evidence)
;;

let discover_active_exact_generation ~keepers_dir ~keeper_id ~trace_id =
  Eio_guard.run_in_systhread (fun () ->
    discover_active_exact_generation_blocking
      ~keepers_dir
      ~keeper_id
      ~trace_id)
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
      ~keepers_dir
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
      ~keepers_dir
      ~keeper_id
      ~trace_id
      ~generation
      (Exact_execution_terminal
         { candidate = Some (attempt_receipt_json candidate)
         ; failure_cause = Some "oas_execution_failed"
         })
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_candidates_exhausted _ ->
    persist_exact_flow_state
      ~keepers_dir
      ~keeper_id
      ~trace_id
      ~generation
      (Exact_execution_terminal { candidate = None; failure_cause = None })
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
    ~keepers_dir
    ~net
    ~keeper_id
    ~generation
    (inp : Keeper_librarian.input)
  =
  let ( let* ) = Result.bind in
  let prepare_attempt messages =
    let* () =
      preflight_exact_flow_state
        ~keepers_dir
        ~keeper_id
        ~trace_id:(input_trace_id inp)
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
          ~keepers_dir
          ~keeper_id
          ~trace_id:(input_trace_id inp)
          ~generation
          Exact_flow_started
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
            ~keepers_dir
            ~keeper_id
            ~trace_id:(input_trace_id inp)
            ~generation
            (Exact_candidate_advance_committed
               { candidate = attempt_receipt_json previous
               ; failure_cause = "domain_invalid_output"
               })
      in
      let* () =
        persist_exact_flow_state
          ~keepers_dir
          ~keeper_id
          ~trace_id:(input_trace_id inp)
          ~generation
          (Exact_candidate_bound (attempt_receipt_json candidate))
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
          ~keepers_dir
          ~keeper_id
          ~trace_id:(input_trace_id inp)
          ~generation
          (Exact_candidate_advance_committed
             { candidate = attempt_receipt_json candidate
             ; failure_cause = "oas_execution_failed"
             })
    in
    let* () =
      Result.map_error (fun detail -> Callback_persistence_failed detail) result
    in
    bound_candidate := None;
    Ok ()
  in
  let terminalize_success success episode =
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
        ~keepers_dir
        ~keeper_id
        ~trace_id:(input_trace_id inp)
        ~generation
        (Exact_oas_success (attempt_receipt_json candidate))
    with
    | Error detail -> persistence_failure detail
    | Ok () ->
      (match
         persist_exact_flow_state
           ~keepers_dir
           ~keeper_id
           ~trace_id:(input_trace_id inp)
           ~generation
           (Exact_domain_valid (attempt_receipt_json candidate))
       with
       | Ok () -> Ok episode
       | Error detail -> persistence_failure detail)
  in
  match clock with
  | None -> Error (Execution_clock_unavailable : extraction_error)
  | Some clock ->
    let* source_input, messages =
      prepare_librarian_prompt inp
      |> Result.map_error (fun detail -> Prompt_render_failed detail)
    in
    let* attempt = prepare_attempt messages in
    let validate flow_success =
      let output = Exact_output.flow_success_output flow_success in
      match
        Keeper_librarian.episode_of_json_result
          ~generation
          source_input
          output.output
      with
      | Ok episode -> Exact_output.Accept episode
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
           ~keepers_dir
           ~keeper_id
           ~trace_id:(input_trace_id inp)
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
           ~keepers_dir
           ~keeper_id
           ~trace_id:(input_trace_id inp)
           ~generation
           (Exact_domain_invalid
              { candidate = attempt_receipt_json candidate; parse_error })
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
  if String.equal (String.trim (input_trace_id inp)) ""
  then Error (Exact_setup_failed Exact_trace_id_invalid)
  else if generation < 0
  then Error (Exact_setup_failed (Exact_generation_invalid generation))
  else
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    extract_with_exact_output_classified_unlocked
      ?clock
      ~keepers_dir
      ~net
      ~keeper_id
      ~generation
      inp
;;

let append_episode
    ?clock
    ~keepers_dir
    ~keeper_id
    episode
  =
  let now = episode.Keeper_memory_os_types.created_at in
  let fail phase exn =
    let detail = Printexc.to_string exn in
    Log.Keeper.warn
      "memory os publication failed keeper=%s phase=%s: %s"
      keeper_id
      (memory_publication_phase_to_string phase)
      detail;
    Error (Memory_publication_failed { phase; detail })
  in
  let protect phase f =
    try Ok (f ()) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> fail phase exn
  in
  try
    Keeper_memory_os_io.with_episode_bundle_lock_for_keepers_dir
      ?clock
      ~keepers_dir
      ~keeper_id
      (fun () ->
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
          Keeper_memory_os_policy.reobserve_fact
            ~now
            ~provenance
            ~existing
            ~incoming
        in
        match
          protect Publication_facts (fun () ->
            File_lock_eio.with_lock
              ?clock
              (Keeper_memory_os_io.facts_path_for_keepers_dir
                 ~keepers_dir
                 ~keeper_id)
              (fun () ->
                 Keeper_memory_os_io.merge_facts_for_keepers_dir
                   ~keepers_dir
                   ~keeper_id
                   ~merge
                   ~incoming:episode.Keeper_memory_os_types.claims))
        with
        | Error _ as error -> error
        | Ok (_ : Keeper_memory_os_io.fact_merge_stats) ->
          (match
             protect Publication_episode (fun () ->
               Keeper_memory_os_io.append_episode_for_keepers_dir
                 ~keepers_dir
                 ~keeper_id
                 episode)
           with
           | Error _ as error -> error
           | Ok () ->
             (match
                protect Publication_event (fun () ->
                  Keeper_memory_os_io.append_event_for_keepers_dir
                    ~keepers_dir
                    ~keeper_id
                    episode)
              with
              | Error _ as error -> error
              | Ok () -> Ok episode)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> fail Publication_bundle_lock exn
;;

let extract_and_append_with_exact_output_classified
    ?clock
    ~base_path
    ~generation_floor
    ~net
    ~keeper_id
    inp
  : (Keeper_memory_os_types.episode, extraction_error) result =
  match clock with
  | None -> Error Execution_clock_unavailable
  | Some _ when String.equal (String.trim (input_trace_id inp)) "" ->
    Error (Exact_setup_failed Exact_trace_id_invalid)
  | Some _ when generation_floor < 0 ->
    Error (Exact_setup_failed (Exact_generation_invalid generation_floor))
  | Some clock ->
    let trace_id = input_trace_id inp in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    (try
       let (_ : string) =
         Keeper_fs.ensure_dir
           (exact_flow_trace_dir ~keepers_dir ~keeper_id ~trace_id)
       in
       File_lock_eio.with_lock
         ~clock
         (exact_trace_lock_path ~keepers_dir ~keeper_id ~trace_id)
         (fun () ->
            let generation =
              match
                discover_active_exact_generation
                  ~keepers_dir
                  ~keeper_id
                  ~trace_id
              with
              | Error detail ->
                Error (Exact_setup_failed (Exact_journal_unavailable detail))
              | Ok (Some generation) -> Ok generation
              | Ok None ->
                (try
                   Ok
                     (Keeper_memory_os_io.next_generation_with_floor_for_keepers_dir
                        ~keepers_dir
                        ~floor:generation_floor
                        ~keeper_id
                        ~trace_id)
                 with
                 | Eio.Cancel.Cancelled _ as error -> raise error
                 | exn ->
                   Error
                     (Exact_setup_failed
                        (Exact_journal_unavailable
                           ("generation reservation failed: "
                            ^ Printexc.to_string exn))))
            in
            match generation with
            | Error _ as error -> error
            | Ok generation ->
              (match
                 extract_with_exact_output_classified_unlocked
                   ~clock
                   ~keepers_dir
                   ~net
                   ~keeper_id
                   ~generation
                   inp
               with
               | Error _ as error -> error
               | Ok episode ->
                 append_episode
                   ~clock
                   ~keepers_dir
                   ~keeper_id
                   episode))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Exact_setup_failed
            (Exact_journal_unavailable
               ("exact flow authority failed: " ^ Printexc.to_string exn))))
;;

let run_best_effort
      ~base_path
      ~generation_floor
      ~keeper_id
      (inp : Keeper_librarian.input)
  =
  (* [cadence_due] short-circuits after [enabled]: a disabled keeper never
     advances its cadence counter, and a not-due turn skips extraction entirely
     (the messages remain in the window for the next due turn). The cadence
     counter is scoped to the active trace so a rollover does not inherit the
     previous trace's schedule. *)
  let trace_id = input_trace_id inp in
  if enabled () && cadence_due ~keeper_id ~trace_id
  then (
    try
      match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
      | Some net, Some clock ->
        (match
           extract_and_append_with_exact_output_classified
             ~clock
             ~base_path
             ~generation_floor
             ~net
             ~keeper_id
             inp
         with
         | Ok episode ->
           cadence_record_success ~keeper_id ~trace_id;
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
           if should_record_cadence_backoff_after_error err
           then cadence_record_attempt ~keeper_id ~trace_id;
           Log.Keeper.warn
             ~keeper_name:keeper_id
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
