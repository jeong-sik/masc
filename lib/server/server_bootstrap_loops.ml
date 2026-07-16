(** Server_bootstrap_loops — Keeper loops and background maintenance.

    Extracted from Server_runtime_bootstrap to isolate the large
    subsystem-spawning functions into a focused module. *)

(* Stable djb2-style hash for the autoboot warmup jitter.

   Post-#13119 follow-up: the previous implementation used native
   [int] arithmetic with a final [land 0x3FFF_FFFF] mask.  That is
   NOT actually platform-stable: on 31-bit OCaml the intermediate
   [acc lsl 5] overflow wraps differently than on 63-bit OCaml
   before the mask is applied, so the same keeper name can hash to
   different buckets depending on architecture.

   Fix: do all arithmetic in [Int32], whose wrap-around behavior is
   identical on every supported runtime.  Mask to 30 bits and convert
   back to [int].  30 bits ≈ 1G distinct buckets, far more than any
   realistic [stagger_window_sec]. *)
let stable_keeper_name_hash_mask_i32 = 0x3FFF_FFFFl

let stable_keeper_name_hash name =
  let acc = ref 5381l in
  String.iter
    (fun ch ->
       let shifted = Int32.shift_left !acc 5 in
       let summed = Int32.add (Int32.add shifted !acc) (Int32.of_int (Char.code ch)) in
       acc := Int32.logand summed stable_keeper_name_hash_mask_i32)
    name;
  Int32.to_int !acc
;;

let autoboot_proactive_warmup_sec ~base_warmup ~stagger_window_sec ~keeper_name =
  let base_warmup = max 0 base_warmup in
  let stagger_window_sec = max 0 stagger_window_sec in
  if stagger_window_sec = 0
  then base_warmup
  else base_warmup + (stable_keeper_name_hash keeper_name mod (stagger_window_sec + 1))
;;

let keeper_agent_status_of_phase = function
  | Keeper_state_machine.Running -> Masc_domain.Active
  | Keeper_state_machine.Paused -> Masc_domain.Listening
  | Keeper_state_machine.Failing
  | Keeper_state_machine.Overflowed
  | Keeper_state_machine.Compacting
  | Keeper_state_machine.HandingOff
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Restarting -> Masc_domain.Busy
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Stopped
  | Keeper_state_machine.Crashed
  | Keeper_state_machine.Dead -> Masc_domain.Inactive
;;

let keeper_registry_agent ~now (entry : Keeper_registry.registry_entry) : Masc_domain.agent =
  let meta = entry.meta in
  let agent_name =
    match String.trim meta.agent_name with
    | "" -> Keeper_identity.keeper_agent_name entry.name
    | name -> name
  in
  let agent_meta : Masc_domain.agent_meta =
    { session_id = "keeper-registry:" ^ entry.name
    ; agent_type = "keeper"
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = Some entry.name
    ; keeper_id = None
    }
  in
  { Masc_domain.id = None
  ; name = agent_name
  ; agent_type = "keeper"
  ; status = keeper_agent_status_of_phase entry.phase
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = now
  ; last_seen = now
  ; meta = Some agent_meta
  }
;;

let keeper_registry_runtime_agents (config : Workspace_utils_backend_setup.config) =
  let now = Masc_domain.now_iso () in
  Keeper_registry.all ~base_path:config.base_path ()
  |> List.map (keeper_registry_agent ~now)
;;

let board_sse_event_params event =
  match event with
  | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth } ->
    let preview =
      if String.length content > 200 then String.sub content 0 200 else content
    in
    let base =
      [ "type", `String "post_created"
      ; "event_type", `String "post.created"
      ; "post_id", `String post_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ; "title", `String title
      ; "content", `String preview
      ; "post_kind", `String (Board.post_kind_to_string post_kind)
      ]
    in
    `Assoc
      (match hearth with
       | Some h -> ("hearth", `String h) :: base
       | None -> base)
  | Board_dispatch.Comment_added { post_id; comment_id; author } ->
    `Assoc
      [ "type", `String "comment_added"
      ; "event_type", `String "comment.created"
      ; "post_id", `String post_id
      ; "comment_id", `String comment_id
      ; "author", `String author
      ; "author_identity", Server_utils.board_actor_identity_json author
      ]
  | Board_dispatch.Post_voted { post_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "post_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "post"
      ; "post_id", `String post_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
    let dir = Board_votes.vote_direction_to_string direction in
    `Assoc
      [ "type", `String "comment_voted"
      ; "event_type", `String "vote.changed"
      ; "target_type", `String "comment"
      ; "comment_id", `String comment_id
      ; "voter", `String voter
      ; "voter_identity", Server_utils.board_actor_identity_json voter
      ; "direction", `String dir
      ]
  | Board_dispatch.Reaction_changed { target_type; target_id; user_id; emoji; reacted } ->
    `Assoc
      [ "type", `String "reaction_changed"
      ; "event_type", `String "reaction.changed"
      ; "target_type", `String (Board.reaction_target_type_to_string target_type)
      ; "target_id", `String target_id
      ; "user_id", `String user_id
      ; "user_identity", Server_utils.board_actor_identity_json user_id
      ; "emoji", `String emoji
      ; "reacted", `Bool reacted
      ]
;;

type queued_chat_projection = {
  payload_channel : string;
  payload_channel_user_id : string;
  payload_channel_user_name : string;
  payload_channel_workspace_id : string;
  agent_name : string;
}

let discord_channel_label = "discord"

let queued_chat_projection (queued_message : Keeper_chat_queue.queued_message) =
  match queued_message.source with
  | Keeper_chat_queue.Dashboard _ ->
    {
      payload_channel = "";
      payload_channel_user_id = "";
      payload_channel_user_name = "";
      payload_channel_workspace_id = "";
      agent_name = "dashboard";
    }
  | Keeper_chat_queue.Discord { channel_id; user_id } ->
    {
      payload_channel = discord_channel_label;
      payload_channel_user_id = user_id;
      payload_channel_user_name = "";
      payload_channel_workspace_id = channel_id;
      agent_name =
        Gate_keeper_backend.agent_name_for_channel_actor
          ~channel:discord_channel_label
          ~channel_workspace_id:channel_id
          ~channel_user_id:user_id;
    }
  | Keeper_chat_queue.Slack { channel_id; user_id; user_name; _ } ->
    {
      payload_channel = "slack";
      payload_channel_user_id = user_id;
      payload_channel_user_name = user_name;
      payload_channel_workspace_id = channel_id;
      agent_name =
        Gate_keeper_backend.agent_name_for_channel_actor
          ~channel:"slack"
          ~channel_workspace_id:channel_id
          ~channel_user_id:user_id;
    }

(* Queue-consumer turns need the same synthetic
   [Server_routes_http_keeper_stream.keeper_chat_stream_request] built from
   a dequeued/leased [Keeper_chat_queue.queued_message], and a duplicated
   copy would silently drift out of sync with [queued_chat_projection] the
   next time either changes. *)
let payload_of_queued_message ~keeper_name
    (queued_message : Keeper_chat_queue.queued_message) :
    Server_routes_http_keeper_stream.keeper_chat_stream_request =
  let projection = queued_chat_projection queued_message in
  { Server_routes_http_keeper_stream.name = keeper_name
  ; message = queued_message.content
  ; turn_instructions = None
  ; surface_context = None
  ; channel = projection.payload_channel
  ; channel_user_id = projection.payload_channel_user_id
  ; channel_user_name = projection.payload_channel_user_name
  ; channel_workspace_id = projection.payload_channel_workspace_id
  ; user_blocks = queued_message.user_blocks
  ; attachments = queued_message.attachments
  }

let trimmed_env_opt name =
  match Sys.getenv_opt name with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed

let discord_bot_token_opt () = trimmed_env_opt "DISCORD_BOT_TOKEN"

let broadcast_mention_wakeup_action = function
  | Some target when String.trim target <> "" -> `Wake_keeper target
  | Some _ | None -> `Suppress_no_target

module Projection_for_testing = struct
  type queued_chat_projection = {
    payload_channel : string;
    payload_channel_user_id : string;
    payload_channel_user_name : string;
    payload_channel_workspace_id : string;
    agent_name : string;
  }

  let autoboot_proactive_warmup_sec = autoboot_proactive_warmup_sec
  let board_sse_event_params = board_sse_event_params
  let broadcast_mention_wakeup_action = broadcast_mention_wakeup_action

  let queued_chat_projection queued_message : queued_chat_projection =
    let projection = queued_chat_projection queued_message in
    {
      payload_channel = projection.payload_channel;
      payload_channel_user_id = projection.payload_channel_user_id;
      payload_channel_user_name = projection.payload_channel_user_name;
      payload_channel_workspace_id = projection.payload_channel_workspace_id;
      agent_name = projection.agent_name;
    }
end

let fork_logged_fiber = Server_bootstrap_loops_fiber.fork_logged_fiber
let log_server_fiber_crash =
  Server_bootstrap_loops_fiber.log_server_fiber_crash
let log_dashboard_fiber_crash =
  Server_bootstrap_loops_fiber.log_dashboard_fiber_crash
let filteri_with_fair_yield =
  Server_bootstrap_loops_fiber.filteri_with_fair_yield
let iteri_with_fair_yield = Server_bootstrap_loops_fiber.iteri_with_fair_yield

type keeper_persistence_report =
  { shutdown : Keeper_shutdown_runtime.restored_inventory
  ; queue : Keeper_chat_queue.configure_report
  ; requests : Keeper_msg_async.recovery_report
  }

let recovery_candidate_lanes candidates =
  candidates
  |> List.fold_left
       (fun lanes (candidate : Keeper_msg_async.recovery_candidate) ->
          let keeper_name =
            Keeper_invocation_types.request_target_name candidate.entry.request
          in
          match lanes with
          | (current, rev_candidates) :: rest when String.equal current keeper_name ->
            (current, candidate :: rev_candidates) :: rest
          | _ -> (keeper_name, [ candidate ]) :: lanes)
       []
  |> List.rev_map (fun (keeper_name, rev_candidates) ->
    keeper_name, List.rev rev_candidates)
;;

type keeper_persistence_failure_phase =
  | Resolving_base_path
  | Restoring_shutdown
  | Configuring_queue
  | Recovering_requests
  | Starting_keeper_loops

type keeper_persistence_raised_cause =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type keeper_persistence_failure_cause =
  | Base_path_identity_unavailable_cause of keeper_persistence_raised_cause
  | Noncanonical_config_cause of
      { configured_base_path : string
      ; canonical_base_path : string
      ; configured_backend_base_path : string
      ; expected_backend_base_path : string
      }
  | Shutdown_inventory_unavailable_cause of Keeper_shutdown_store.error
  | Shutdown_admission_unavailable_cause of string
  | Unexpected_exception_cause of keeper_persistence_raised_cause
  | Lifecycle_invariant_cause of string

type keeper_persistence_failure =
  { phase : keeper_persistence_failure_phase
  ; base_path : string
  ; cause : keeper_persistence_failure_cause
  }

type keeper_persistence_prepare_error =
  | Shutdown_inventory_unavailable of Keeper_shutdown_store.error
  | Shutdown_admission_unavailable of string
  | Preparation_base_path_identity_unavailable of keeper_persistence_failure
  | Preparation_config_not_canonical of keeper_persistence_failure
  | Preparation_in_progress
  | Preparation_awaiting_claim
  | Preparation_already_claimed
  | Preparation_failed_previously of keeper_persistence_failure
  | Preparation_ownership_lost

type keeper_persistence_base_path =
  { requested : string
  ; canonical : string
  ; backend_base_path : string
  }

type prepared_keeper_persistence =
  { base_path : keeper_persistence_base_path
  ; config : Workspace.config
  ; report : keeper_persistence_report
  }

type claimed_keeper_persistence =
  { claimed_base_path : keeper_persistence_base_path
  ; claimed_config : Workspace.config
  ; claimed_report : keeper_persistence_report
  }

type keeper_persistence_claim_error =
  | Claim_base_path_mismatch
  | Claim_base_path_identity_unavailable of keeper_persistence_failure
  | Claim_superseded
  | Claim_already_claimed
  | Claim_failed_previously of keeper_persistence_failure

type keeper_persistence_start_error =
  | Start_base_path_mismatch of
      { claimed_base_path : string
      ; state_base_path : string
      }
  | Start_base_path_identity_unavailable of keeper_persistence_failure
  | Start_superseded
  | Start_in_progress
  | Start_already_started
  | Start_execution_failed of keeper_persistence_failure
  | Start_failed_previously of keeper_persistence_failure

exception Keeper_persistence_start_failed of keeper_persistence_start_error

type failed_lifecycle =
  { failure : keeper_persistence_failure
  ; prepared : prepared_keeper_persistence option
  ; claimed : claimed_keeper_persistence option
  }

type preparation_lifecycle =
  | Idle
  | Preparing of unit ref
  | Ready of prepared_keeper_persistence
  | Claimed of prepared_keeper_persistence * claimed_keeper_persistence
  | Starting of prepared_keeper_persistence * claimed_keeper_persistence
  | Started of prepared_keeper_persistence * claimed_keeper_persistence
  | Failed of failed_lifecycle

let persistence_lifecycle = Atomic.make Idle

module Keeper_name_set = Set.Make (String)

let preparation_stage_started () = Mtime_clock.now ()

let preparation_stage_elapsed_seconds started =
  Mtime.Span.to_float_ns (Mtime.span started (Mtime_clock.now ())) /. 1e9
;;

let observe_preparation_stage ~stage ~started ~examined ~failures =
  let elapsed_seconds = preparation_stage_elapsed_seconds started in
  let labels = [ "stage", stage ] in
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string PersistencePreparationStageDuration)
    ~labels
    elapsed_seconds;
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string PersistencePreparationExamined)
    ~labels
    (Float.of_int examined);
  Log.Server.info
    "keeper_persistence_prepare: stage=%s elapsed_seconds=%.6f examined=%d failures=%d"
    stage
    elapsed_seconds
    examined
    failures
;;

let keeper_persistence_failure_phase_to_string = function
  | Resolving_base_path -> "resolving_base_path"
  | Restoring_shutdown -> "restoring_shutdown"
  | Configuring_queue -> "configuring_queue"
  | Recovering_requests -> "recovering_requests"
  | Starting_keeper_loops -> "starting_keeper_loops"
;;

let keeper_persistence_raised_cause_to_string { exception_; backtrace } =
  let exception_text = Printexc.to_string exception_ in
  let backtrace_text = Printexc.raw_backtrace_to_string backtrace in
  if String.equal backtrace_text ""
  then exception_text
  else exception_text ^ "\n" ^ backtrace_text
;;

let keeper_persistence_failure_cause_to_string = function
  | Base_path_identity_unavailable_cause cause
  | Unexpected_exception_cause cause ->
    keeper_persistence_raised_cause_to_string cause
  | Noncanonical_config_cause
      { configured_base_path
      ; canonical_base_path
      ; configured_backend_base_path
      ; expected_backend_base_path
      } ->
    Printf.sprintf
      "noncanonical workspace config base_path=%S canonical=%S backend_base_path=%S expected_backend_base_path=%S"
      configured_base_path
      canonical_base_path
      configured_backend_base_path
      expected_backend_base_path
  | Shutdown_inventory_unavailable_cause error ->
    Keeper_shutdown_store.error_to_string error
  | Shutdown_admission_unavailable_cause detail -> detail
  | Lifecycle_invariant_cause detail -> detail
;;

let keeper_persistence_failure_to_string failure =
  Printf.sprintf
    "keeper persistence failed phase=%s base_path=%S detail=%s"
    (keeper_persistence_failure_phase_to_string failure.phase)
    failure.base_path
    (keeper_persistence_failure_cause_to_string failure.cause)
;;

let keeper_persistence_prepare_error_to_string = function
  | Shutdown_inventory_unavailable error ->
    "shutdown inventory unavailable: " ^ Keeper_shutdown_store.error_to_string error
  | Shutdown_admission_unavailable detail ->
    "shutdown admission restore unavailable: " ^ detail
  | Preparation_base_path_identity_unavailable failure ->
    keeper_persistence_failure_to_string failure
  | Preparation_config_not_canonical failure ->
    keeper_persistence_failure_to_string failure
  | Preparation_in_progress ->
    "keeper persistence preparation is already in progress"
  | Preparation_awaiting_claim ->
    "keeper persistence preparation is ready and awaiting its owning claim"
  | Preparation_already_claimed ->
    "keeper persistence ownership was already claimed for this process"
  | Preparation_failed_previously failure ->
    "keeper persistence lifecycle already failed in this process: "
    ^ keeper_persistence_failure_to_string failure
  | Preparation_ownership_lost ->
    "keeper persistence preparation lost its lifecycle ownership"
;;

let failure_cause_of_prepare_error = function
  | Shutdown_inventory_unavailable error ->
    Shutdown_inventory_unavailable_cause error
  | Shutdown_admission_unavailable detail ->
    Shutdown_admission_unavailable_cause detail
  | Preparation_base_path_identity_unavailable failure
  | Preparation_config_not_canonical failure ->
    failure.cause
  | ( Preparation_in_progress
    | Preparation_awaiting_claim
    | Preparation_already_claimed
    | Preparation_failed_previously _
    | Preparation_ownership_lost ) as error ->
    Lifecycle_invariant_cause
      (keeper_persistence_prepare_error_to_string error)
;;

let prepare_keeper_persistence_owned ~base_path_identity ~set_phase ~config =
  let base_path = config.Workspace.base_path in
  set_phase Restoring_shutdown;
  let shutdown_started = preparation_stage_started () in
  let shutdown_inventory =
    match Keeper_shutdown_store.scan_inventory ~config with
    | Error error -> Error (Shutdown_inventory_unavailable error)
    | Ok entries ->
      (match Keeper_shutdown_runtime.restore_inventory_admission ~config entries with
       | Ok restored -> Ok restored
       | Error detail -> Error (Shutdown_admission_unavailable detail))
  in
  (match shutdown_inventory with
   | Ok restored ->
     observe_preparation_stage
       ~stage:"shutdown"
       ~started:shutdown_started
       ~examined:
         (List.length restored.operations + List.length restored.corrupt_records)
       ~failures:(List.length restored.corrupt_records)
   | Error _ ->
     observe_preparation_stage
       ~stage:"shutdown"
       ~started:shutdown_started
       ~examined:0
       ~failures:1);
  match shutdown_inventory with
  | Error _ as error -> error
  | Ok shutdown ->
  set_phase Configuring_queue;
  let queue_started = preparation_stage_started () in
  let queue_recovery = Keeper_chat_queue.configure_persistence ~base_path in
  observe_preparation_stage
    ~stage:"queue"
    ~started:queue_started
    ~examined:
      (queue_recovery.restored_keeper_count
       + List.length queue_recovery.load_errors)
    ~failures:(List.length queue_recovery.load_errors);
  List.iter
    (fun (keeper_name, (error : Keeper_chat_queue.snapshot_load_error)) ->
       let keeper_label =
         match keeper_name with
         | Some keeper_name -> keeper_name
         | None -> "<registry>"
       in
       Log.Keeper.error
         "keeper_chat_queue: snapshot unavailable keeper=%s kind=%s error=%s"
         keeper_label
         (Keeper_chat_queue.snapshot_load_error_kind_to_string error.kind)
         error.message)
    queue_recovery.load_errors;
  if
    queue_recovery.restored_keeper_count > 0
    || queue_recovery.recovery_required_receipt_count > 0
    || queue_recovery.load_errors <> []
  then
    Log.Keeper.warn
      "keeper_chat_queue: recovery restored_keepers=%d recovery_required_receipts=%d failures=%d"
      queue_recovery.restored_keeper_count
      queue_recovery.recovery_required_receipt_count
      (List.length queue_recovery.load_errors);
  (* Inspect request records only after queue receipts converge. This boundary
     preserves non-terminal restart provenance; it neither executes requests
     nor launders interrupted work into a terminal failure. *)
  set_phase Recovering_requests;
  let request_started = preparation_stage_started () in
  let keeper_msg_recovery =
    Keeper_msg_async.recover_request_records ~base_path ()
  in
  let candidates = keeper_msg_recovery.candidates in
  let completion_deliveries = keeper_msg_recovery.completion_deliveries in
  observe_preparation_stage
    ~stage:"request"
    ~started:request_started
    ~examined:
      (List.length candidates
       + List.length completion_deliveries
       + keeper_msg_recovery.finalized
       + keeper_msg_recovery.cleaned
       + keeper_msg_recovery.staging_files_inspected
       + keeper_msg_recovery.unreadable
       + keeper_msg_recovery.failed)
    ~failures:
      (keeper_msg_recovery.unreadable
       + keeper_msg_recovery.failed
       + List.length keeper_msg_recovery.store_errors);
  if
    candidates <> []
    || completion_deliveries <> []
    || keeper_msg_recovery.finalized > 0
    || keeper_msg_recovery.cleaned > 0
    || keeper_msg_recovery.staging_files_inspected > 0
    || keeper_msg_recovery.unreadable > 0
    || keeper_msg_recovery.failed > 0
  then
    Log.Keeper.warn
      "keeper_msg_async: recovery pending=%d completion_deliveries=%d finalized=%d cleaned=%d staging_files_inspected=%d staging_files_deleted=%d staging_files_preserved=%d unreadable=%d failed=%d"
      (List.length candidates)
      (List.length completion_deliveries)
      keeper_msg_recovery.finalized
      keeper_msg_recovery.cleaned
      keeper_msg_recovery.staging_files_inspected
      keeper_msg_recovery.staging_files_deleted
      keeper_msg_recovery.staging_files_preserved
      keeper_msg_recovery.unreadable
      keeper_msg_recovery.failed;
  List.iter
    (fun (candidate : Keeper_msg_async.recovery_candidate) ->
       Log.Keeper.warn
         "keeper_msg_async: restart candidate request_id=%s keeper=%s provenance=%s"
         candidate.entry.request_id
         (Keeper_invocation_types.request_target_name candidate.entry.request)
         (match candidate.provenance with
          | Keeper_msg_async.Queued_before_restart -> "queued"
          | Keeper_msg_async.Running_before_restart -> "running"
          | Keeper_msg_async.Cancelling_before_restart _ -> "cancelling"))
    candidates;
  List.iter
    (fun proof ->
       ignore
         (Keeper_tool_surface_ops.project_durable_keeper_completion ~base_path proof
           : Keeper_tool_surface_ops.keeper_completion_projection))
    completion_deliveries;
  let prepared =
    { base_path = base_path_identity
    ; config
    ; report =
        { shutdown
        ; queue = queue_recovery
        ; requests = keeper_msg_recovery
        }
    }
  in
  Ok prepared
;;

let rec acquire_preparation_ownership preparing =
  let current = Atomic.get persistence_lifecycle in
  match current with
  | Idle ->
    if Atomic.compare_and_set persistence_lifecycle current preparing
    then Ok ()
    else acquire_preparation_ownership preparing
  | Ready _ -> Error Preparation_awaiting_claim
  | Preparing _ -> Error Preparation_in_progress
  | Claimed _ | Starting _ | Started _ -> Error Preparation_already_claimed
  | Failed failed -> Error (Preparation_failed_previously failed.failure)
;;

let persistence_failure ~phase ~base_path ~cause = { phase; base_path; cause }

let raised_cause exception_ backtrace = { exception_; backtrace }

let failed_lifecycle ?prepared ?claimed failure =
  Failed { failure; prepared; claimed }
;;

let log_lifecycle_transition_loss ~from_phase ~failure =
  Log.Server.error
    "keeper persistence lifecycle lost terminal transition from=%s failure=%s"
    from_phase
    (keeper_persistence_failure_to_string failure)
;;

let prepare_keeper_persistence ?requested_base_path ~config () =
  let preparing = Preparing (ref ()) in
  match acquire_preparation_ownership preparing with
  | Error _ as error -> error
  | Ok () ->
    let config_base_path = config.Workspace.base_path in
    let requested_base_path =
      (* DET-OK: omission selects the explicit typed-config BasePath; no
         ambient path or guessed owner enters this branch. *)
      Option.value requested_base_path ~default:config_base_path
    in
    let phase = ref Resolving_base_path in
    let outcome =
      match
        let canonical_result =
          match Fs_compat.realpath config_base_path with
          | canonical -> Ok canonical
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception ((Unix.Unix_error _ | Sys_error _) as exception_) ->
            Error
              (raised_cause exception_ (Printexc.get_raw_backtrace ()))
        in
        match canonical_result with
        | Error raised ->
          let failure =
            persistence_failure
              ~phase:Resolving_base_path
              ~base_path:config_base_path
              ~cause:(Base_path_identity_unavailable_cause raised)
          in
          Error (Preparation_base_path_identity_unavailable failure)
        | Ok canonical_base_path ->
          let base_path_identity =
            let expected_backend_base_path =
            (Workspace.backend_config_for canonical_base_path)
              .Backend_types.base_path
            in
            { requested = requested_base_path
            ; canonical = canonical_base_path
            ; backend_base_path = expected_backend_base_path
            }
          in
          let expected_backend_base_path = base_path_identity.backend_base_path in
          let configured_backend_base_path =
            config.backend_config.Backend_types.base_path
          in
          if
            not (String.equal config_base_path canonical_base_path)
            || not
                 (String.equal
                    configured_backend_base_path
                    expected_backend_base_path)
          then
            let failure =
              persistence_failure
                ~phase:Resolving_base_path
                ~base_path:config_base_path
                ~cause:
                  (Noncanonical_config_cause
                     { configured_base_path = config_base_path
                     ; canonical_base_path
                     ; configured_backend_base_path
                     ; expected_backend_base_path
                     })
            in
            Error (Preparation_config_not_canonical failure)
          else
            prepare_keeper_persistence_owned
              ~base_path_identity
              ~set_phase:(fun next_phase -> phase := next_phase)
              ~config
      with
      | outcome -> outcome
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let failure =
          persistence_failure
            ~phase:!phase
            ~base_path:requested_base_path
            ~cause:
              (Unexpected_exception_cause (raised_cause exn backtrace))
        in
        if
          not
            (Atomic.compare_and_set
               persistence_lifecycle
               preparing
               (failed_lifecycle failure))
        then log_lifecycle_transition_loss ~from_phase:"preparing" ~failure;
        Printexc.raise_with_backtrace exn backtrace
    in
    (match outcome with
     | Ok prepared ->
       if Atomic.compare_and_set persistence_lifecycle preparing (Ready prepared)
       then Ok prepared
       else Error Preparation_ownership_lost
     | Error error ->
       let failure =
         match error with
         | Preparation_base_path_identity_unavailable failure
         | Preparation_config_not_canonical failure -> failure
         | _ ->
           persistence_failure
             ~phase:!phase
             ~base_path:requested_base_path
             ~cause:(failure_cause_of_prepare_error error)
       in
       if
         Atomic.compare_and_set
           persistence_lifecycle
           preparing
           (failed_lifecycle failure)
       then Error error
       else Error Preparation_ownership_lost)
;;

let keeper_persistence_report prepared = prepared.report

type base_path_validation_error =
  | Base_path_mismatch of { observed_canonical : string }
  | Base_path_identity_unavailable of keeper_persistence_failure

let validate_config_base_path ~phase base_path config =
  let state_base_path = config.Workspace.base_path in
  let state_backend_base_path =
    config.backend_config.Backend_types.base_path
  in
  match Fs_compat.realpath state_base_path with
  | observed_canonical ->
    if
      String.equal state_base_path base_path.canonical
      && String.equal observed_canonical base_path.canonical
      && String.equal state_backend_base_path base_path.backend_base_path
    then Ok ()
    else Error (Base_path_mismatch { observed_canonical })
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as cause) ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      (Base_path_identity_unavailable
         (persistence_failure
            ~phase
            ~base_path:state_base_path
            ~cause:
              (Base_path_identity_unavailable_cause
                 (raised_cause cause backtrace))))
;;

let rec claim_prepared_keeper_persistence ~config prepared =
  let current = Atomic.get persistence_lifecycle in
  match current with
  | Ready latest when latest == prepared ->
    (match
       validate_config_base_path
         ~phase:Resolving_base_path
         prepared.base_path
         config
     with
     | Error (Base_path_mismatch _) -> Error Claim_base_path_mismatch
     | Error (Base_path_identity_unavailable failure) ->
       Error (Claim_base_path_identity_unavailable failure)
     | Ok () ->
      let claimed =
        { claimed_base_path = prepared.base_path
        ; claimed_config = prepared.config
        ; claimed_report = prepared.report
        }
      in
      if
        Atomic.compare_and_set
          persistence_lifecycle
          current
          (Claimed (prepared, claimed))
      then Ok claimed
      else claim_prepared_keeper_persistence ~config prepared)
  | Claimed (latest, _) when latest == prepared -> Error Claim_already_claimed
  | Starting (latest, _) when latest == prepared -> Error Claim_already_claimed
  | Started (latest, _) when latest == prepared -> Error Claim_already_claimed
  | Failed { prepared = Some latest; failure; _ } when latest == prepared ->
    Error (Claim_failed_previously failure)
  | Idle
  | Preparing _
  | Ready _
  | Claimed _
  | Starting _
  | Started _
  | Failed _ ->
    Error Claim_superseded
;;

let keeper_persistence_claim_error_to_string = function
  | Claim_base_path_mismatch ->
    "prepared persistence BasePath does not match server state"
  | Claim_base_path_identity_unavailable failure ->
    "server state BasePath identity is unavailable during persistence claim: "
    ^ keeper_persistence_failure_to_string failure
  | Claim_superseded -> "prepared persistence token is stale"
  | Claim_already_claimed -> "prepared persistence token was already claimed"
  | Claim_failed_previously failure ->
    "prepared persistence token claim already failed: "
    ^ keeper_persistence_failure_to_string failure
;;

type keeper_loops_start_ownership =
  { starting : preparation_lifecycle
  ; prepared : prepared_keeper_persistence
  ; claimed : claimed_keeper_persistence
  }

let rec acquire_keeper_loops_start ~config claimed =
  let current = Atomic.get persistence_lifecycle in
  match current with
  | Claimed (prepared, latest) when latest == claimed ->
    (match
       validate_config_base_path
         ~phase:Starting_keeper_loops
         claimed.claimed_base_path
         config
     with
     | Error (Base_path_mismatch _) ->
       Error
         (Start_base_path_mismatch
            { claimed_base_path = claimed.claimed_base_path.canonical
            ; state_base_path = config.Workspace.base_path
            })
     | Error (Base_path_identity_unavailable failure) ->
       Error (Start_base_path_identity_unavailable failure)
     | Ok () ->
      let starting = Starting (prepared, claimed) in
      if Atomic.compare_and_set persistence_lifecycle current starting
      then Ok { starting; prepared; claimed }
      else acquire_keeper_loops_start ~config claimed)
  | Starting (_, latest) when latest == claimed -> Error Start_in_progress
  | Started (_, latest) when latest == claimed -> Error Start_already_started
  | Failed { claimed = Some latest; failure; _ } when latest == claimed ->
    Error (Start_failed_previously failure)
  | Idle
  | Preparing _
  | Ready _
  | Claimed _
  | Starting _
  | Started _
  | Failed _ ->
    Error Start_superseded
;;

let finish_keeper_loops_start ownership =
  if
    Atomic.compare_and_set
      persistence_lifecycle
      ownership.starting
      (Started (ownership.prepared, ownership.claimed))
  then Ok ()
  else
    match Atomic.get persistence_lifecycle with
    | Started (_, latest) when latest == ownership.claimed ->
      Error Start_already_started
    | Failed { claimed = Some latest; failure; _ }
      when latest == ownership.claimed ->
      Error (Start_failed_previously failure)
    | Idle
    | Preparing _
    | Ready _
    | Claimed _
    | Starting _
    | Started _
    | Failed _ ->
      Error Start_superseded
;;

let keeper_persistence_start_error_to_string = function
  | Start_base_path_mismatch { claimed_base_path; state_base_path } ->
    Printf.sprintf
      "claimed persistence BasePath %S does not match server state BasePath %S"
      claimed_base_path
      state_base_path
  | Start_base_path_identity_unavailable failure ->
    "server state BasePath identity is unavailable during Keeper-loop start: "
    ^ keeper_persistence_failure_to_string failure
  | Start_superseded -> "claimed persistence token is stale"
  | Start_in_progress -> "claimed persistence token is already starting Keeper loops"
  | Start_already_started -> "claimed persistence token already started Keeper loops"
  | Start_execution_failed failure ->
    "claimed persistence token failed while starting Keeper loops: "
    ^ keeper_persistence_failure_to_string failure
  | Start_failed_previously failure ->
    "claimed persistence token start already failed: "
    ^ keeper_persistence_failure_to_string failure
;;

let () =
  Printexc.register_printer (function
    | Keeper_persistence_start_failed error ->
      Some (keeper_persistence_start_error_to_string error)
    | _ -> None)
;;

let start_keeper_loops_owned
      ~claimed_persistence
      ~workspace_scope
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      (state : Mcp_server.server_state)
  =
  Progress.set_sse_callback Sse.broadcast;
  (* Wire stop_keeper hook so zombie GC can terminate keeper fibers *)
  Atomic.set Workspace_hooks.stop_keeper_fn Keeper_keepalive.stop_keepalive;
  Atomic.set Workspace_hooks.runtime_agents_fn keeper_registry_runtime_agents;
  (* Bus creation carries no queue policy. Each subscriber owns its bounded,
     non-blocking queue contract. *)
  let event_bus = Agent_sdk.Event_bus.create () in
  (* Eio fiber isolation: each subsystem runs in its own fiber.
     If one crashes, others keep running — Eio's structured concurrency.
     Subsystem_health tracks liveness at module level (no init timing dependency). *)
  let fork_subsystem name f =
    Subsystem_health.register name;
    fork_logged_fiber
      ~sw
      ~on_error:(fun exn ->
        Subsystem_health.mark_dead name;
        Log.Server.error "subsystem %s crashed: %s" name (Printexc.to_string exn))
      f
  in
  let config = workspace_scope.Mcp_server.config in
  (* [claimed_persistence] can only be constructed by the typed one-shot claim
     boundary before readiness publication. No late exception can turn an
     already-visible HTTP state into a degraded bootstrap. *)
  (* Completion recovery can publish [Dead_cleaned] and invoke
     [Tombstone_reaped]. Install the production hook before any durable
     receipt is replayed. *)
  Keeper_subprocess_registry.register_default_cleanup_hook ();
  Keeper_shutdown_finalize.register_completion_handler
    Server_dashboard_http_delete_actions.handle_keeper_lifecycle_completion;
  let wait_for_lazy_startup () =
    (* Combines #10843 (per-task elapsed diagnostic, merged via #10854) with
       a per-task boot guard.  The diagnostic surface stays as #10854
       intended — running/HUNG tags + INFO→WARN escalation at 60s — and
       the boot guard kicks in at [boot_guard_sec] (default 120s) to
       fail-out tasks that exceed it via [Server_startup_state.fail_lazy_task].
       Without a hard ceiling, a single hung task (e.g. [restore_sessions]
       hanging 17 min, #10843) blocks keeper boot indefinitely; the 240s
       startup watchdog still observes the blocking phase because
       [prepare_lazy_tasks] records the pending inventory without publishing
       readiness. *)
    let started_at = Hashtbl.create 16 in
    let hung_threshold_sec = 60.0 in
    let boot_guard_sec =
      match Sys.getenv_opt "MASC_LAZY_TASK_BOOT_GUARD_SEC" with
      | Some v ->
        (match float_of_string_opt (String.trim v) with
         | Some f when f > 0.0 -> f
         | _ -> 120.0)
      | None -> 120.0
    in
    let format_pending now pending =
      pending
      |> List.map (fun task ->
        let elapsed =
          match Hashtbl.find_opt started_at task with
          | Some t -> now -. t
          | None -> 0.0
        in
        let tag = if elapsed >= hung_threshold_sec then "HUNG" else "running" in
        Printf.sprintf "%s (%s %.1fs)" task tag elapsed)
      |> String.concat ", "
    in
    let rec loop last_log_at =
      let pending = Server_startup_state.pending_lazy_tasks () in
      if pending = []
      then ()
      else (
        let now = Eio.Time.now clock in
        List.iter
          (fun task ->
             if not (Hashtbl.mem started_at task) then Hashtbl.add started_at task now)
          pending;
        Hashtbl.filter_map_inplace
          (fun task t -> if List.mem task pending then Some t else None)
          started_at;
        let stuck =
          List.filter
            (fun task ->
               match Hashtbl.find_opt started_at task with
               | Some seen_at -> now -. seen_at >= boot_guard_sec
               | None -> false)
            pending
        in
        if stuck <> []
        then (
          List.iter
            (fun task ->
               let elapsed =
                 match Hashtbl.find_opt started_at task with
                 | Some seen_at -> now -. seen_at
                 | None -> 0.0
               in
               Log.Keeper.error
                 "autoboot: lazy task %s exceeded boot guard %.0fs (elapsed %.1fs) — \
                  failing it so keeper boot can proceed"
                 task
                 boot_guard_sec
                 elapsed;
               Otel_metric_store.inc_counter
                 "masc_lazy_task_boot_guard_fired_total"
                 ~labels:[ "task", task ]
                 ();
               Server_startup_state.fail_lazy_task
                 ~task
                 ~error:(Printf.sprintf "lazy_task_boot_guard:%.0fs" boot_guard_sec))
            stuck;
          loop last_log_at)
        else (
          let last_log_at =
            if now -. last_log_at >= 5.0
            then (
              let max_elapsed =
                List.fold_left
                  (fun m task ->
                     match Hashtbl.find_opt started_at task with
                     | Some s -> Float.max m (now -. s)
                     | None -> m)
                  0.0
                  pending
              in
              let log_fn =
                if max_elapsed >= hung_threshold_sec
                then Log.Keeper.warn
                else Log.Keeper.info
              in
              log_fn
                "autoboot: waiting for lazy startup tasks to finish before keeper boot \
                 [%s]"
                (format_pending now pending);
              now)
            else last_log_at
          in
          Eio.Time.sleep
            clock
            Env_config_keeper.KeeperBootstrap.lazy_startup_poll_interval_sec;
          loop last_log_at))
    in
    loop (Eio.Time.now clock)
  in
  (* Create and install the MASC-owned Event_bus alongside OAS's.
     MASC domain events (masc.broadcast, masc.heartbeat, masc.keeper.*,
     masc.harness.*, ...) publish here per OAS event_bus.mli:103-107
     boundary. Dashboard SSE consumers see both channels as one stream
     — the relay translates masc.* →
     masc:* on the wire for backward compatibility. *)
  let masc_event_bus = Agent_sdk.Event_bus.create () in
  Masc_event_bus.set masc_event_bus;
  (* Event_bus → SSE bridge: relay both OAS and MASC buses to dashboard *)
  Keeper_event_bridge.start ~sw ~clock ~config:(Mcp_server.workspace_config state) ~bus:event_bus;
  Keeper_event_bridge.start ~sw ~clock ~config:(Mcp_server.workspace_config state) ~bus:masc_event_bus;
  (* Telemetry feedback loop: observe OAS per-turn signals without
     deserializing provider/model-bearing payloads. *)
  Keeper_telemetry_consumer.spawn_subscriber
    ~sw ~clock ~base_path:(Env_config.base_path ()) ~bus:event_bus;
  let keeper_lifecycle_sub =
    Agent_sdk_metrics_bridge.subscribe
      ~capacity:256
      ~overflow:Agent_sdk.Event_bus.Drop_oldest
      ~purpose:"lifecycle_listener"
      ~filter:(Agent_sdk.Event_bus.filter_topic "masc.keeper.lifecycle")
      masc_event_bus
  in
  Eio.Switch.on_release sw (fun () ->
    Agent_sdk_metrics_bridge.unsubscribe masc_event_bus keeper_lifecycle_sub);
  (* Replay durable completion receipts only after the MASC event bus has its
     SSE/metrics subscribers and lifecycle hooks are installed. Otherwise a
     boot-time [Dead_cleaned] publish can return successfully while every
     process-local sink is still absent. *)
  fork_subsystem "keeper_shutdown_recovery" (fun () ->
    let restored = claimed_persistence.claimed_report.shutdown in
      List.iter
        (fun corrupt ->
           Log.Keeper.error
             "corrupt shutdown operation retained under an exact Keeper admission fence: keeper=%s operation=%s path=%s error=%s"
             corrupt.Keeper_shutdown_store.keeper_name
             (Keeper_shutdown_types.Operation_id.to_string corrupt.operation_id)
             corrupt.path
             (Keeper_shutdown_store.error_to_string corrupt.error))
        restored.corrupt_records;
      Eio.Switch.run (fun recovery_sw ->
        List.iter
          (fun operation ->
             Eio.Fiber.fork ~sw:recovery_sw (fun () ->
               try
                 match Keeper_shutdown_runtime.recover_operation ~config operation with
                 | Ok recovered ->
                   Log.Keeper.info
                     "recovered shutdown operation keeper=%s operation=%s"
                     recovered.Keeper_shutdown_types.keeper_name
                     (Keeper_shutdown_types.Operation_id.to_string recovered.operation_id)
                 | Error detail ->
                   Log.Keeper.error
                     "shutdown recovery failed keeper=%s operation=%s error=%s"
                     operation.Keeper_shutdown_types.keeper_name
                     (Keeper_shutdown_types.Operation_id.to_string operation.operation_id)
                     detail
               with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn ->
                 Log.Keeper.error
                   "shutdown recovery crashed keeper=%s operation=%s error=%s"
                   operation.Keeper_shutdown_types.keeper_name
                   (Keeper_shutdown_types.Operation_id.to_string operation.operation_id)
                   (Printexc.to_string exn)))
          restored.operations));
  fork_logged_fiber
    ~sw
    ~on_error:(log_dashboard_fiber_crash "keeper lifecycle listener")
    (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk_metrics_bridge.drain keeper_lifecycle_sub in
         List.iter
           (fun (evt : Agent_sdk.Event_bus.event) ->
              match evt.payload with
              | Agent_sdk.Event_bus.Custom ("masc.keeper.lifecycle", payload) ->
                (match
                   ( Safe_ops.json_string_opt "event" payload
                   , Safe_ops.json_string_opt "keeper_name" payload )
                 with
                 | Some event, Some keeper_name ->
                   Server_dashboard_http.patch_keeper_dependent_caches ~keeper_name ~event
                 | None, _ | Some _, None ->
                   (* P3 cleanup: previously malformed lifecycle events
                       (missing `event` or `keeper_name` field) were
                       silently dropped.  A systematic encoding bug
                       could lose every cache invalidation indefinitely
                       with no signal.  Bumping a Otel_metric_store counter
                       lets `rate(...)` alerts catch the regression
                       even though the dashboard cache continues to
                       degrade gracefully (just stale, not broken). *)
                   Otel_metric_store.inc_counter "masc_keeper_lifecycle_malformed_total" ())
              | _ -> Log.Dashboard.debug "ignored non-lifecycle event")
           events;
         if events <> []
         then (
           Log.Dashboard.info
             "patched keeper-dependent dashboard caches (%d lifecycle event(s))"
             (List.length events);
           Server_dashboard_http.broadcast_namespace_truth_snapshot state)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Dashboard.error
           "keeper lifecycle listener iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep
        clock
        Env_config_keeper.KeeperBootstrap.keeper_listener_retry_interval_sec;
      loop ()
    in
    loop ());
  (* Inject Event_bus into keeper keepalive runtime for telemetry publishing *)
  Keeper_keepalive.set_bus event_bus;
  let project_recovery_terminal (entry : Keeper_msg_async.entry) =
    match
      Keeper_msg_async.load_canonical_durable_terminal
        ~base_path:config.base_path
        ~caller:entry.submitted_by
        entry.request_id
    with
    | Ok proof ->
      ignore
        (Keeper_tool_surface_ops.project_durable_keeper_completion
           ~base_path:config.base_path proof
          : Keeper_tool_surface_ops.keeper_completion_projection)
    | Error error ->
      Log.Keeper.error
        "keeper invocation restart terminal reload failed request_id=%s error=%s"
        entry.request_id
        (Keeper_msg_async.canonical_terminal_error_to_string error)
  in
  let explicit_recovery_failure request_id reason =
    Tool_result.error
      ~tool_name:"keeper_invocation_recovery"
      ~start_time:(Time_compat.now ())
      (Printf.sprintf "restart recovery failed request_id=%s: %s" request_id reason)
  in
  let run_recovery_candidate (candidate : Keeper_msg_async.recovery_candidate) =
    let entry = candidate.entry in
    let settled, resolve_settled = Eio.Promise.create () in
    let on_worker_settled ~request_id settlement =
      Fun.protect
        ~finally:(fun () ->
          ignore (Eio.Promise.try_resolve resolve_settled () : bool))
        (fun () ->
           ignore
             (Keeper_tool_surface_ops.project_keeper_completion
                ~base_path:config.base_path
                ~submitted_by:entry.submitted_by
                ~request_id
                settlement
               : Keeper_tool_surface_ops.keeper_completion_projection))
    in
    let f request_sw =
      match candidate.provenance with
      | Keeper_msg_async.Running_before_restart ->
        explicit_recovery_failure
          entry.request_id
          "execution had already started before process restart; effect replay was refused"
      | Keeper_msg_async.Cancelling_before_restart _ ->
        explicit_recovery_failure
          entry.request_id
          "persisted cancellation did not reach the worker admission boundary"
      | Keeper_msg_async.Queued_before_restart ->
        (match Keeper_invocation_types.request_direct_delivery entry.request with
         | Some _ ->
           explicit_recovery_failure
             entry.request_id
             "direct delivery requires its transcript checkpoint executor; delegated replay was refused"
         | None ->
           let recovery_ctx : _ Keeper_types_profile.context =
             { config
             ; agent_name = entry.submitted_by
             ; sw = request_sw
             ; clock
             ; proc_mgr = Some proc_mgr
             ; net = state.net
             ; publication_recovery_provider =
                 Mcp_server.publication_recovery_availability_provider state
             }
           in
           Keeper_turn.handle_keeper_delegate
             ~event_bus
             recovery_ctx
             entry.request)
    in
    match
      Keeper_msg_async.resume_recovery_candidate
        ~on_worker_settled
        ~background_sw:sw
        ~f
        candidate
    with
    | Ok _ -> Eio.Promise.await settled
    | Error error ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string LifecycleCallbackFailures)
        ~labels:[ "callback", "keeper_invocation_restart" ]
        ();
      Log.Keeper.error
        "keeper_msg_async: restart convergence failed request_id=%s keeper=%s error=%s"
        entry.request_id
        (Keeper_invocation_types.request_target_name entry.request)
        (Keeper_msg_async.recovery_resume_error_to_string error);
      project_recovery_terminal entry
  in
  claimed_persistence.claimed_report.requests.candidates
  |> recovery_candidate_lanes
  |> List.iter (fun (keeper_name, candidates) ->
    fork_logged_fiber
      ~sw
      ~on_error:(fun exn ->
        Log.Keeper.error
          "keeper invocation restart lane crashed keeper=%s error=%s"
          keeper_name
          (Printexc.to_string exn))
      (fun () -> List.iter run_recovery_candidate candidates));
  Board_dispatch.set_board_signal_hook (fun signal ->
    Keeper_keepalive.wakeup_relevant_keeper_for_board_signal
      ~config:(Mcp_server.workspace_config state)
      signal);
  Board_dispatch.set_board_sse_hook (fun event ->
    let params = board_sse_event_params event in
    Sse.broadcast
      (`Assoc
          [ "jsonrpc", `String "2.0"
          ; "method", `String "notifications/board"
          ; "params", params
          ]);
    (* Emit activity event so Discord/external connectors can detect board posts *)
    let activity_kind, activity_actor, activity_subject, activity_payload =
      match event with
      | Board_dispatch.Post_created { post_id; author; title; content; post_kind; hearth }
        ->
        let base =
          [ "post_id", `String post_id
          ; "title", `String title
          ; "content", `String content
          ; "author", `String author
          ; "author_identity", Server_utils.board_actor_identity_json author
          ; "post_kind", `String (Board.post_kind_to_string post_kind)
          ]
        in
        let payload_fields =
          match hearth with
          | Some h -> ("hearth", `String h) :: base
          | None -> base
        in
        ( Event_kind.Board.to_string Event_kind.Board.Posted
        , Server_utils.board_actor_entity author
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc payload_fields )
      | Board_dispatch.Comment_added { post_id; comment_id; author } ->
        ( Event_kind.Board.to_string Event_kind.Board.Commented
        , Server_utils.board_actor_entity author
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc
            [ "post_id", `String post_id
            ; "comment_id", `String comment_id
            ; "author", `String author
            ; "author_identity", Server_utils.board_actor_identity_json author
            ] )
      | Board_dispatch.Post_voted { post_id; voter; direction } ->
        let dir = Board_votes.vote_direction_to_string direction in
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity voter
        , Some (Activity_graph.entity ~kind:"post" post_id)
        , `Assoc
            [ "post_id", `String post_id
            ; "voter", `String voter
            ; "voter_identity", Server_utils.board_actor_identity_json voter
            ; "direction", `String dir
            ] )
      | Board_dispatch.Comment_voted { comment_id; voter; direction } ->
        let dir = Board_votes.vote_direction_to_string direction in
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity voter
        , Some (Activity_graph.entity ~kind:"comment" comment_id)
        , `Assoc
            [ "comment_id", `String comment_id
            ; "voter", `String voter
            ; "voter_identity", Server_utils.board_actor_identity_json voter
            ; "direction", `String dir
            ] )
      | Board_dispatch.Reaction_changed
          { target_type; target_id; user_id; emoji; reacted } ->
        ( Event_kind.Board.to_string Event_kind.Board.Voted
        , Server_utils.board_actor_entity user_id
        , Some
            (Activity_graph.entity
               ~kind:(Board.reaction_target_type_to_string target_type)
               target_id)
        , `Assoc
            [ "target_type", `String (Board.reaction_target_type_to_string target_type)
            ; "target_id", `String target_id
            ; "user_id", `String user_id
            ; "user_identity", Server_utils.board_actor_identity_json user_id
            ; "emoji", `String emoji
            ; "reacted", `Bool reacted
            ] )
    in
    (* P2 silent-failure fix: Activity_graph.emit failures (Discord
       webhook, audit trail writes, etc.) were previously ignored
       entirely.  An operator seeing board activity on the dashboard
       had no signal that the external systems failed to receive the
       event.  Catch + warn surfaces the failure in operator logs
       without aborting the SSE broadcast that already succeeded. *)
    try
      ignore
        (Activity_graph.emit
           (Mcp_server.workspace_config state)
           ~actor:activity_actor
           ?subject:activity_subject
           ~kind:activity_kind
           ~payload:activity_payload
           ~tags:[ "board"; activity_kind ]
           ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Misc.warn
        "board: Activity_graph.emit kind=%s failed: %s"
        activity_kind
        (Printexc.to_string exn));
  (* Wire broadcast -> keeper wakeup. Explicit mentions wake the target
     keeper immediately; unmentioned broadcasts remain passive SSE/message
     fanout so one broad announcement cannot create a fleet-wide turn storm.
     Board signals have their own capped keeper wake path above. *)
  let broadcast_mention_handler =
    fun mention ->
    match broadcast_mention_wakeup_action mention with
    | `Wake_keeper target ->
      Keeper_keepalive.wakeup_keeper ~base_path:(Mcp_server.workspace_config state).base_path target;
      Log.Keeper.info "broadcast mention → wakeup keeper %s" target
    | `Suppress_no_target ->
      Log.Keeper.info
        "broadcast without mention -> keeper wakeup suppressed (passive fanout)"
  in
  Workspace_broadcast.on_broadcast_mention := broadcast_mention_handler;
  (* Orchestrator needs synchronous registration for shutdown hook *)
  (try
     let cancel_orchestrator =
       Orchestrator.start ~sw ~proc_mgr ~clock ~domain_mgr (Mcp_server.workspace_config state)
     in
     Shutdown_hooks.register_cancel_orchestrator cancel_orchestrator
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Server.error
       "subsystem orchestrator failed to start: %s"
       (Printexc.to_string exn));
  (* Build read-only tool surface shared by both judges. *)
  let judge_tool_names =
    [ "masc_status"
    ; Tool_name.Task_name.to_string Tool_name.Task_name.Tasks
    ; Tool_name.Board_name.to_string Tool_name.Board_name.Board_list
    ]
  in
  let judge_masc_tools =
    match Keeper_tool_surfaces.local_worker_tool_schemas ~names:judge_tool_names () with
    | Ok schemas -> schemas
    | Error e ->
      Log.Server.warn "judge tool schema resolution failed: %s" e;
      []
  in
  let make_judge_dispatch ~actor ~(name : string) ~(args : Yojson.Safe.t) : Tool_result.result =
    let start_time = Time_compat.now () in
    let config = (Mcp_server.workspace_config state) in
    let agent_name = actor in
    let ctx_workspace : Tool_workspace.context = { config; agent_name } in
    let ctx_task : Task.Tool.context = { config; agent_name; sw = Some sw } in
    (* ctx_agent removed with the masc_agents judge dispatch case (2026-06-09). *)
    match name with
    | "masc_status" ->
      (match Tool_workspace.dispatch ctx_workspace ~name ~args with
       | Some result -> result
       | None ->
         (* RFC-0189: [Tool_*.dispatch] returning [None] when the
            name is hard-coded here is a server-side invariant
            violation (registry says the name routes here).
            [Runtime_failure] — not caller-actionable. *)
         Tool_result.error
           ~failure_class:(Some Tool_result.Runtime_failure)
           ~tool_name:name ~start_time "masc_status: dispatch failed")
    | "masc_tasks" ->
      (match Task.Tool.dispatch ctx_task ~name ~args with
       | Some result -> result
       | None ->
         Tool_result.error
           ~failure_class:(Some Tool_result.Runtime_failure)
           ~tool_name:name ~start_time "masc_tasks: dispatch failed")
    | "masc_board_list" ->
      Board_tool.handle_tool name args
    | _ ->
      (* RFC-0189: operator judge dispatch caller
         judge runner) requested a tool outside the allow-list.
         Caller-misuse = [Workflow_rejection]. *)
      Tool_result.error
        ~failure_class:(Some Tool_result.Workflow_rejection)
        ~tool_name:name
        ~start_time
        (Printf.sprintf "judge: tool '%s' not allowed" name)
  in
  (* Legacy dashboard judge subsystem removed (2026-06-09): its only factual input
     was [Workspace.get_agents_status], which read the disk-backed
     [.masc/agents/] registry whose producer ([Workspace_eio.register_agent])
     had zero call sites. items/activity were already hardcoded []. So the
     judge ran ~100 empty LLM cycles/day producing 0 judgments for ~12 days.
     Removing the daemon rather than leaving a permanently-empty input. *)
  let operator_judge_dispatch = make_judge_dispatch ~actor:"operator-judge" in
  fork_subsystem "operator_judge" (fun () ->
    let operator_judge_ctx : _ Operator_control.context =
      { config = workspace_scope.config
      ; agent_name = "operator-judge"
      ; sw
      ; clock
      ; proc_mgr = Some proc_mgr
      ; net = state.net
      ; delegated_dispatch = None
      ; mcp_session_id = None
      }
    in
    Dashboard_operator_judge.start
      ~sw
      ~clock
      ~config:workspace_scope.config
      ~masc_tools:judge_masc_tools
      ~dispatch:operator_judge_dispatch
      ~build_facts:(fun () ->
        Operator_control.snapshot_json
          ~actor:"operator-judge"
          ~view:"summary"
          ~include_messages:false
          ~include_keepers:true
          operator_judge_ctx)
      ());
  fork_subsystem "session_cleanup" (fun () ->
    Session.start_mcp_session_cleanup_loop ~sw ~clock ());
  (* No verification_timeout fork: RFC-0220 §11 PR-3 deleted the sweep —
     the wall-clock deadline rescue was removed in §5 and the fork had been
     spinning on a no-op since PR-1. *)
  (* Auto-boot keepers from keeper meta and start keepalive loops.
     Each unbooted keeper retries in its own fiber until it registers, so
     transient model/discovery failures neither abandon that lane nor block
     supervisor startup or sibling lanes. See #5717. *)
  fork_subsystem "keeper_autoboot" (fun () ->
    if not Env_config.KeeperBootstrap.enabled
    then Log.Keeper.info "autoboot: disabled via MASC_KEEPER_BOOTSTRAP_ENABLED=false"
    else (
      wait_for_lazy_startup ();
      Log.Keeper.info "autoboot: lazy startup complete; keeper bootstrap will start last";
      (* Brief delay so other subsystems (SSE, board, orchestrator) settle first. *)
      Eio.Time.sleep clock Env_config_keeper.KeeperBootstrap.post_startup_settle_sec;
      let masc_root = Workspace.masc_root_dir config in
      let keeper_dir = Keeper_fs.keeper_dir config in
      let shutdown_blocked_names =
        claimed_persistence.claimed_report.shutdown.blocked_keeper_names
        |> Keeper_name_set.of_list
      in
      let all_names = Keeper_meta_store.keeper_names config in
      let all_count = List.length all_names in
      Log.Keeper.info
        "autoboot: base_path=%s masc_root=%s keeper_dir=%s keeper_json_count=%d"
        config.base_path
        masc_root
        keeper_dir
        all_count;
      let names =
        Keeper_runtime.bootable_keeper_names config
        |> List.filter (fun name ->
          not (Keeper_name_set.mem name shutdown_blocked_names))
      in
      let exclusions = Keeper_runtime.autoboot_excluded_keeper_reasons config in
      let keeper_boot_ctx : _ Keeper_types_profile.context =
        { config
        ; agent_name = "keeper-autoboot"
        ; sw
        ; clock
        ; proc_mgr = Some proc_mgr
        ; net = state.net
        ; publication_recovery_provider =
            Mcp_server.publication_recovery_availability_provider state
        }
      in
      Log.Keeper.info "autoboot: %d keeper(s) to boot" (List.length names);
      Log.Keeper.info "autoboot: keeper set [%s]" (String.concat ", " names);
      if exclusions <> []
      then (
        let rendered =
          exclusions
          |> List.map (fun Keeper_runtime.{ keeper_name; reason } ->
            Printf.sprintf
              "%s=%s"
              keeper_name
              (Keeper_runtime.autoboot_exclusion_reason_to_string reason))
          |> String.concat ", "
        in
        Log.Keeper.info
          "autoboot: excluded %d configured keeper(s): [%s]"
          (List.length exclusions)
          rendered);
      let base_warmup = Keeper_config.keeper_bootstrap_proactive_warmup_sec () in
      let stagger_window = Keeper_config.keeper_bootstrap_stagger_step_sec () in
      (* Attempt to boot a single keeper. Returns true if started. *)
      let try_boot_one ?(log_prefix = "autoboot") _idx name =
        try
          Log.Keeper.info "%s: loading meta for %s" log_prefix name;
          match Keeper_runtime.load_or_materialize_boot_meta keeper_boot_ctx name with
          | Error e ->
            Log.Keeper.error "%s: failed to load meta for %s: %s" log_prefix name e;
            false
          | Ok { meta = m; materialized } ->
            if Keeper_registry.is_running ~base_path:config.base_path m.name
            then (
              Log.Keeper.info
                "%s: %s already running%s"
                log_prefix
                m.name
                (if materialized then " (materialized from TOML)" else "");
              true)
            else (
              let warmup =
                autoboot_proactive_warmup_sec
                  ~base_warmup
                  ~stagger_window_sec:stagger_window
                  ~keeper_name:name
              in
              Log.Keeper.info
                "%s: calling start_keepalive for %s (warmup=%ds)"
                log_prefix
                name
                warmup;
              let ctx : _ Keeper_types_profile.context =
                { config
                ; agent_name = m.agent_name
                ; sw
                ; clock
                ; proc_mgr = Some proc_mgr
                ; net = state.net
                ; publication_recovery_provider =
                    Mcp_server.publication_recovery_availability_provider state
                }
              in
              let launch_outcome =
                Keeper_keepalive.start_keepalive
                  ~proactive_warmup_sec:warmup
                  ctx
                  m
              in
              (match launch_outcome with
               | Keeper_keepalive.Keepalive_started _
               | Keeper_keepalive.Keepalive_already_registered _ -> ()
               | outcome ->
                 Log.Keeper.warn
                   "%s: start_keepalive rejected %s: %s"
                   log_prefix
                   m.name
                   (Keeper_keepalive.start_keepalive_outcome_to_string outcome));
              (* start_keepalive registers the keeper synchronously via
                 register_offline and then forks the keepalive fiber.  The
                 fiber flips the registry to running asynchronously on the
                 next Eio tick, so querying is_running here is a race that
                 keepers with a larger proactive-warmup idx lose
                 deterministically (verdict=165s / sojin=150s / sangsu=135s
                 produced the bulk of the false-positive "not in registry"
                 WARNs).  Check the synchronous is_registered predicate
                 instead — the running transition is observed later by the
                 retry loop.  See #7889. *)
              let registered =
                Keeper_registry.is_registered ~base_path:config.base_path m.name
              in
              if registered
              then Log.Keeper.info "%s: started keepalive for %s" log_prefix m.name
              else
                Log.Keeper.warn
                  "%s: start_keepalive returned but %s not registered"
                  log_prefix
                  m.name;
              registered)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.error
            "%s: exception for %s: %s"
            log_prefix
            name
            (Printexc.to_string exn);
          false
      in
      (* Initial boot pass *)
      let booted =
        filteri_with_fair_yield (fun idx name -> try_boot_one idx name) names
      in
      let booted_count = List.length booted in
      let total = List.length names in
      Log.Keeper.info "autoboot: initial pass %d/%d keepers started" booted_count total;
      (* Retry loop for keepers that failed initial boot *)
      if booted_count < total
      then (
        let retry_interval_s =
          Float.of_int (Keeper_config.keeper_bootstrap_retry_interval_sec ())
        in
        let unbooted =
          List.filter (fun name -> not (List.mem name booted)) names
        in
        List.iteri
          (fun idx name ->
             Eio.Fiber.fork ~sw (fun () ->
               let rec retry_loop round =
                 if Keeper_registry.is_registered ~base_path:config.base_path name
                 then
                   Log.Keeper.info
                     "autoboot: %s registered after %d retry round(s)"
                     name
                     (round - 1)
                 else (
                   Eio.Time.sleep clock retry_interval_s;
                   Log.Keeper.info
                     "autoboot: retry round %d for unbooted keeper %s"
                     round
                     name;
                   if try_boot_one ~log_prefix:"autoboot-retry" idx name
                   then
                     Log.Keeper.info
                       "autoboot: %s registered on retry round %d"
                       name
                       round
                   else retry_loop (round + 1))
               in
               retry_loop 1))
          unbooted);
      (* #10125: start the supervisor sweep here, after autoboot
         completes.  Without this call the sweep would only fire
         on the first [masc_keeper_msg] tool dispatch (the single
         caller of [start_existing_keepalives] in [keeper_tool_surface.ml]
         — see #10125 timeline 2026-04-24, where 14 keepers ran
         under autoboot but the sweep never came up because no
         operator [masc_keeper_msg] arrived after the restart;
         four hours later the entire fleet was dead with no
         supervisor to recover them).

         [start_supervisor_sweep] is idempotent — its internal
         [supervisor_sweep_running] guard makes a second call a
         noop, so this stays correct if [masc_keeper_msg] later
         races into [start_existing_keepalives] anyway. *)
      (try Keeper_runtime.start_supervisor_sweep keeper_boot_ctx with
       | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.error
          "autoboot: supervisor sweep failed to start: %s"
          (Printexc.to_string exn))));
  (* Queue acceptance and draining are runtime persistence concerns, not an
     autoboot policy. The blocking control loop is the supervised subsystem
     body, so a loop exception cannot fail the server root through an
     unobserved child fiber. *)
  let consumer_started, consumer_started_resolver = Eio.Promise.create () in
  fork_subsystem "keeper_chat_consumer" (fun () ->
    let base_path = config.base_path in
    let setup =
      try
        (* A durable queue mutation both refreshes the dashboard (SSE) and must
           wake this consumer: [notify_transition] is a non-blocking Wake_inbox
           post, so a message enqueued after boot is actually leased and
           delivered instead of sitting queued until the next unrelated wake. *)
        Keeper_chat_queue.set_transition_observer
          (Some
             (fun ~keeper_name ~revision ->
                Keeper_chat_broadcast.queue_changed ~keeper_name ~revision ();
                Keeper_chat_consumer.notify_transition ~keeper_name));
        (* A freed turn slot (turn released / shutdown rolled back) makes the
           lane dispatchable again; wake the consumer so any receipt that was
           deferred while the lane was busy is re-examined. The admission
           observer is non-blocking and its failures cannot alter admission. *)
        Keeper_turn_admission.set_slot_transition_observer
          (Some
             (fun ~base_path:_ ~keeper_name ~transition:_ ->
                Keeper_chat_consumer.notify_transition ~keeper_name));
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error exn
    in
    Eio.Promise.resolve consumer_started_resolver setup;
    (match setup with
     | Ok () -> ()
     | Error exn -> raise exn);
    Keeper_chat_consumer.run ~sw ~clock
           ~base_path
           ~handle_turn:(fun ~sw ~keeper_name ~delivery_key ~queued_message ->
             let open Server_routes_http_keeper_stream in
             let now = Time_compat.now () in
             let run_id =
               Printf.sprintf "keeper-consumer-run-%d"
                 (int_of_float (now *. 1000.0))
             in
             let message_id =
               Printf.sprintf "keeper-consumer-msg-%d"
                 (int_of_float ((now +. 0.001) *. 1000.0))
             in
             let payload = payload_of_queued_message ~keeper_name queued_message in
             let agent_name = (queued_chat_projection queued_message).agent_name in
             let events = Keeper_chat_events.create () in
             let closed = ref false in
             let thread_id = "keeper-consumer:" ^ keeper_name in
             let delivery, delivery_resolver = Eio.Promise.create () in
             let resolve_delivery result =
               ignore
                 (Eio.Promise.try_resolve delivery_resolver result : bool)
             in
             let drain_events () =
               let rec loop () =
                 match Keeper_chat_events.subscribe events with
                 | Keeper_chat_events.Run_finished _
                 | Keeper_chat_events.Event_error _ -> ()
                 | _ -> loop ()
               in
               loop ()
             in
             let fork_delivery_adapter ~label ~run =
               fork_logged_fiber ~sw
                 ~on_error:(fun exn ->
                   let detail =
                     Printf.sprintf "%s adapter crashed for keeper=%s: %s"
                       label keeper_name (Printexc.to_string exn)
                   in
                   resolve_delivery
                     (Error (Keeper_chat_queue.Delivery_failed, detail));
                   Log.Keeper.error "keeper_chat_consumer: %s" detail;
                   (* Keep consuming the bounded event stream after an
                      unexpected adapter crash so producer backpressure cannot
                      deadlock the turn before it emits its terminal outcome. *)
                   drain_events ())
                 (fun () ->
                   let callback_observed = ref false in
                   run (fun result ->
                     callback_observed := true;
                     resolve_delivery result);
                   if not !callback_observed then
                     resolve_delivery
                       (Error
                          ( Keeper_chat_queue.Delivery_failed,
                            Printf.sprintf
                              "%s adapter terminated without a terminal delivery receipt"
                              label )))
             in
             (match queued_message.source with
              | Keeper_chat_queue.Dashboard _ ->
                  Log.Keeper.info
                    "keeper_chat_consumer: processing dashboard queue \
                     message for keeper=%s"
                    keeper_name;
                  fork_logged_fiber ~sw
                    ~on_error:(fun exn ->
                      resolve_delivery
                        (Error
                           ( Keeper_chat_queue.Internal_error,
                             Printf.sprintf
                               "dashboard event drain crashed for keeper=%s: %s"
                               keeper_name (Printexc.to_string exn) )))
                    (fun () ->
                      drain_events ();
                      resolve_delivery (Ok ()))
              | Keeper_chat_queue.Discord { channel_id; _ } ->
                  Log.Keeper.info
                    "keeper_chat_consumer: forking Discord adapter \
                     for keeper=%s"
                    keeper_name;
                  (match discord_bot_token_opt () with
                   | Some token ->
                       fork_delivery_adapter ~label:"Discord"
                         ~run:(fun settle ->
                           Keeper_chat_discord.adapter_loop ~clock ~token
                             ~channel_id ~events
                             ~on_send_result:(fun result ->
                               settle
                                 (Result.map_error
                                    (fun error ->
                                      ( Keeper_chat_queue.Delivery_failed,
                                        Format.asprintf "%a"
                                          Keeper_chat_discord.pp_error error ))
                                    result))
                             ())
                   | None ->
                       resolve_delivery
                         (Error
                            ( Keeper_chat_queue.Connector_unavailable,
                              "DISCORD_BOT_TOKEN is not configured" ));
                       fork_logged_fiber ~sw
                         ~on_error:(fun _ -> ()) drain_events;
                       Log.Keeper.warn
                         "keeper_chat_consumer: \
                          DISCORD_BOT_TOKEN not set, \
                          skipping Discord delivery for keeper=%s"
                         keeper_name)
              | Keeper_chat_queue.Slack { channel_id; thread_ts; _ } ->
                  Log.Keeper.info
                    "keeper_chat_consumer: forking Slack adapter \
                     for keeper=%s"
                    keeper_name;
                  (match Env_config_slack.bot_token_opt () with
                   | Some token ->
                       fork_delivery_adapter ~label:"Slack"
                         ~run:(fun settle ->
                           Keeper_chat_slack.adapter_loop ~clock ~token
                             ~channel:channel_id ?thread_ts ~events
                             ~on_send_result:(fun result ->
                               Slack_observability.record_reply
                                 (match result with
                                  | Ok () -> Slack_observability.Reply_send_ok
                                  | Error _ ->
                                      Slack_observability.Reply_send_failed);
                               settle
                                 (Result.map_error
                                    (fun error ->
                                      ( Keeper_chat_queue.Delivery_failed,
                                        Format.asprintf "%a"
                                          Keeper_chat_slack.pp_error error ))
                                    result))
                             ())
                   | None ->
                       resolve_delivery
                         (Error
                            ( Keeper_chat_queue.Connector_unavailable,
                              "SLACK_BOT_TOKEN is not configured" ));
                       fork_logged_fiber ~sw
                         ~on_error:(fun _ -> ()) drain_events;
                       Log.Keeper.error
                         "keeper_chat_consumer: \
                          SLACK_BOT_TOKEN not set; \
                          Slack delivery skipped for keeper=%s \
                          (queued reply will not be delivered)"
                         keeper_name));
             (* Derive the typed reply-continuation channel from the queued
                message source so [process_single_turn] can route the
                assistant reply to the originating connector (Discord/Slack)
                or exact dashboard thread. *)
             let continuation_channel =
               Keeper_chat_queue.continuation_channel_of_message_source
                 queued_message.source
             in
             let turn_outcome =
               match
                 process_single_turn
                   ~user_row_origin:queued_message.user_row_origin
                   ~queued_turn:true
                   ~delivery_key:(Some delivery_key)
                   ~state ~clock ~auth_token:None
                   ~thread_id ~continuation_channel ~closed
                   ~client_disconnects:None
                   ~payload ~run_id ~message_id ~agent_name
                   ~submitted_by:agent_name
                   ~events
               with
               | outcome -> outcome
               | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
               | exception exn ->
                   Keeper_chat_events.publish events
                     (Keeper_chat_events.Event_error
                        { message = Printexc.to_string exn });
                   let _delivery_outcome = Eio.Promise.await delivery in
                   raise exn
             in
             let delivery_outcome = Eio.Promise.await delivery in
             match turn_outcome, delivery_outcome with
             | Some (Deferred { rejection }), _ ->
                 Keeper_chat_consumer.Deferred { rejection }
             | Some (Delivered { outcome_ref }), Ok () ->
                 Keeper_chat_consumer.Delivered
                   { outcome_ref }
             | Some (Delivered { outcome_ref }), Error (kind, detail) ->
                 Keeper_chat_consumer.Failed
                   { kind; detail; outcome_ref = Some outcome_ref }
             | Some (Failed { kind = turn_kind; detail = turn_detail }),
               Error (delivery_kind, delivery_detail) ->
                 Keeper_chat_consumer.Failed
                   { kind = delivery_kind
                   ; detail =
                       Printf.sprintf
                         "turn failed (%s): %s; terminal connector delivery also failed: %s"
                         (queued_turn_failure_kind_to_string turn_kind)
                         turn_detail delivery_detail
                   ; outcome_ref = None
                   }
             | Some (Failed { kind; detail }), Ok () ->
                 let kind =
                   match kind with
                   | Turn_failed -> Keeper_chat_queue.Turn_failed
                   | Turn_cancelled -> Keeper_chat_queue.Cancelled
                   | No_visible_reply
                   | Continuation_checkpoint_without_reply ->
                       Keeper_chat_queue.No_visible_reply
                   | Missing_turn_ref -> Keeper_chat_queue.Internal_error
                   | Transcript_persist_failed ->
                       Keeper_chat_queue.Transcript_persist_failed
                   | Stream_projection_failed ->
                       Keeper_chat_queue.Internal_error
                 in
                 Keeper_chat_consumer.Failed
                   { kind; detail; outcome_ref = None }
             | None, _ ->
                 Keeper_chat_consumer.Failed
                   { kind = Keeper_chat_queue.Internal_error
                   ; detail =
                       "queued turn returned no terminal outcome (invariant violation)"
                   ; outcome_ref = None
                   }));
  (match Eio.Promise.await consumer_started with
   | Ok () -> ()
   | Error exn -> raise exn);
  (* Discord presence bridge — syncs keeper liveness to bot status. *)
  fork_subsystem "discord_presence" (fun () ->
    Discord_presence_bridge.start
      ~sw ~clock ~workspace_config:(Mcp_server.workspace_config state) ());
  (* Phase 5: unified startup subsystem summary *)
  Log.Startup.info "subsystems: keeper loops started"
;;

let start_keeper_loops
      ~claimed_persistence
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      (state : Mcp_server.server_state)
  =
  let workspace_scope = Mcp_server.workspace_scope state in
  let state_config = workspace_scope.config in
  (* Claim has already committed admission. Mask cancellation only across the
     second BasePath validation and [Claimed -> Starting] CAS so a cancelled
     startup cannot strand a claimed token. The long-running startup body is
     deliberately outside protection and terminalizes cancellation below. *)
  match
    Eio.Cancel.protect (fun () ->
      acquire_keeper_loops_start ~config:state_config claimed_persistence)
  with
  | Error error -> raise (Keeper_persistence_start_failed error)
  | Ok ownership ->
    let outcome =
      match
        start_keeper_loops_owned
          ~claimed_persistence
          ~workspace_scope
          ~sw
          ~clock
          ~net
          ~domain_mgr
          ~proc_mgr
          state
      with
      | () -> Ok ()
      | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
    in
    (match outcome with
     | Ok () ->
       (match finish_keeper_loops_start ownership with
        | Ok () -> ()
        | Error error -> raise (Keeper_persistence_start_failed error))
     | Error (exn, backtrace) ->
       let failure =
         persistence_failure
           ~phase:Starting_keeper_loops
           ~base_path:claimed_persistence.claimed_base_path.canonical
           ~cause:
             (Unexpected_exception_cause (raised_cause exn backtrace))
       in
       if
         not
           (Atomic.compare_and_set
              persistence_lifecycle
              ownership.starting
              (failed_lifecycle
                 ~prepared:ownership.prepared
                 ~claimed:ownership.claimed
                 failure))
       then log_lifecycle_transition_loss ~from_phase:"starting" ~failure;
       (match exn with
        | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace exn backtrace
        | _ ->
          Printexc.raise_with_backtrace
            (Keeper_persistence_start_failed
               (Start_execution_failed failure))
            backtrace))
;;

module For_testing = struct
  include Projection_for_testing

  type nonrec keeper_loops_start_ownership = keeper_loops_start_ownership

  let reset_keeper_persistence_lifecycle () = Atomic.set persistence_lifecycle Idle

  let prepared_base_paths prepared =
    prepared.base_path.requested, prepared.base_path.canonical
  ;;

  let recovery_candidate_lanes = recovery_candidate_lanes

  let begin_keeper_loops_start = acquire_keeper_loops_start
  let finish_keeper_loops_start = finish_keeper_loops_start
end


(* Background maintenance loops
   extracted to [Server_bootstrap_maintenance] (godfile decomp). *)
include Server_bootstrap_maintenance
