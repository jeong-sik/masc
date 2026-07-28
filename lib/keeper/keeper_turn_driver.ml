(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named runtime
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

open Result.Syntax

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Runtime_oas_runner
include Keeper_internal_error
include Keeper_turn_driver_helpers

include Keeper_turn_driver_provider_attempt
include Keeper_turn_driver_backpressure

let release_client_capacity_quietly =
  Keeper_turn_driver_admission.release_client_capacity_quietly

let provider_config_identity_key =
  Keeper_turn_driver_admission.provider_config_identity_key

let runtime_candidates_of_providers =
  Keeper_turn_driver_admission.runtime_candidates_of_providers

let positive_modality_counts counts =
  counts
  |> List.filter (fun (_, n) -> n > 0)
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let modality_counts_summary counts =
  counts
  |> positive_modality_counts
  |> List.map (fun (modality, n) -> Printf.sprintf "%s=%d" modality n)
  |> String.concat ","

let modality_counts_total counts =
  counts
  |> positive_modality_counts
  |> List.fold_left (fun acc (_, n) -> acc + n) 0

let media_degrade_manifest_decision ~(runtime_id : string)
    (dropped : (string * int) list) =
  let summary = modality_counts_summary dropped in
  Keeper_runtime_manifest.with_payload_role
    ~payload_role:Keeper_runtime_manifest.Operator_evidence
    (`Assoc
      [
        ("routing_action", `String "media_degraded_to_text");
        ( "routing_reason",
          `String "no_configured_runtime_accepts_required_media" );
        ("degraded_runtime_id", `String runtime_id);
        ("media_dropped_total", `Int (modality_counts_total dropped));
        ("media_dropped_counts", `String summary);
      ])

type provider_run_result =
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result

type provider_attempt_outcomes =
  { provider_result : provider_run_result
  ; turn_result : provider_run_result
  }

type runtime_attempt_candidate =
  | Resolved_runtime of Runtime.t
  | Missing_runtime of string

type deferred_runtime_lane =
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Agent_sdk.Error.sdk_error
  }

let deferred_runtime_ids hint =
  hint.next_runtime_id :: hint.later_runtime_ids

let equal_deferred_runtime_lane left right =
  String.equal left.assignment_id right.assignment_id
  && String.equal left.failed_runtime_id right.failed_runtime_id
  && String.equal left.next_runtime_id right.next_runtime_id
  && left.later_runtime_ids = right.later_runtime_ids

let project_provider_attempt_result ~replay_prefix_projection provider_result =
  let turn_result =
    match provider_result with
    | Error _ as error -> error
    | Ok run_result ->
      (match run_result.Runtime_agent.checkpoint with
       | None -> Ok run_result
       | Some checkpoint ->
         (match
            Keeper_replay_prefix.restore_checkpoint
              replay_prefix_projection
              checkpoint
          with
          | Ok checkpoint ->
            Ok
              { run_result with
                Runtime_agent.checkpoint = Some checkpoint
              }
          | Error error ->
            Error
              (Agent_sdk.Error.Internal
                 (Keeper_replay_prefix.restore_error_to_string error))))
  in
  { provider_result; turn_result }
;;

let runtime_attempt_decision ~idx ~runtime_id =
  `Assoc [ ("idx", `Int idx); ("runtime_id", `String runtime_id) ]

let runtime_failed_decision ~idx ~runtime_id error =
  `Assoc
    [
      ("idx", `Int idx);
      ("runtime_id", `String runtime_id);
      ("error_kind", `String (Oas_compat.error_kind error));
    ]

let lane_should_retry
    ~is_last
    ~allow_retry
    ~allow_accept_no_progress_retry
    error =
  if is_last || not allow_retry then
    false
  else if Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next error
  then
    allow_accept_no_progress_retry
  else if Keeper_turn_driver_try_runtime.context_overflow_should_try_next error
  then
    (* A typed ContextOverflow is a per-candidate capacity bound, not a request
       defect: a later lane candidate with a larger context window can still
       serve the same turn. [sdk_error_to_http_error] folds it into a generic
       HTTP 400 which [Runtime_attempt_fsm.should_try_next] treats as terminal,
       so the typed error must be read before that mapping. Overflow on the
       last candidate still returns the typed error, keeping the reactive
       compaction trigger ([context_overflow_event_of_error]) intact. *)
    true
  else
    match Keeper_turn_driver_try_runtime.sdk_error_to_http_error error with
    | Some http_err -> Runtime_attempt_fsm.should_try_next http_err
    | None -> false

let attempt_runtime_candidates
    ?(allow_retry = fun ~runtime_id:_ ~attempt:_ _error -> true)
    ?(allow_accept_no_progress_retry = fun ~runtime_id:_ ~attempt:_ _error ->
      true)
    ?lane_id
    ?(on_retry_deferred = fun _ -> ())
    ~runtime_id ~runtime_id_of
    ~(emit_runtime_manifest :
       ?status:string ->
       ?decision:Yojson.Safe.t ->
       Keeper_runtime_manifest.event_kind ->
       unit) ~run_attempt candidates =
  let rec loop idx = function
    | [] ->
      Error
        (Agent_sdk.Error.Internal
           (Printf.sprintf "runtime lane %S exhausted all candidates" runtime_id))
    | candidate :: rest ->
      let is_last = rest = [] in
      let attempt_runtime_id = runtime_id_of candidate in
      emit_runtime_manifest
        ~status:"attempt"
        ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
        Keeper_runtime_manifest.Runtime_routed;
      (match
         run_attempt ~idx ~runtime_id:attempt_runtime_id candidate
       with
       | Ok value, _checkpoint_after ->
         emit_runtime_manifest
           ~status:"completed"
           ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
           Keeper_runtime_manifest.Runtime_completed;
         (* Sticky failover: remember the winning candidate so later turns on
            this lane start from it (idx 0 or a failover success alike). *)
         (match lane_id with
          | Some lane_id ->
            Runtime_lane_preference.note_success ~lane_id
              ~candidate:attempt_runtime_id
          | None -> ());
         Ok value
       | Error error, _checkpoint_after ->
         emit_runtime_manifest
           ~status:"failed"
           ~decision:(runtime_failed_decision ~idx ~runtime_id:attempt_runtime_id error)
           Keeper_runtime_manifest.Runtime_failed;
         let retry_admitted =
           allow_retry ~runtime_id:attempt_runtime_id ~attempt:idx error
         in
         let allow_accept_no_progress_retry =
           if
             Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next
               error
           then
             allow_accept_no_progress_retry
               ~runtime_id:attempt_runtime_id
               ~attempt:idx
               error
           else true
         in
         let retryable_with_input_authority =
           lane_should_retry
             ~is_last
             ~allow_retry:true
             ~allow_accept_no_progress_retry
             error
         in
         if retry_admitted && retryable_with_input_authority
         then loop (idx + 1) rest
         else (
           (match retryable_with_input_authority, rest with
            | true, next :: later ->
              on_retry_deferred
                { assignment_id = runtime_id
                ; failed_runtime_id = attempt_runtime_id
                ; next_runtime_id = runtime_id_of next
                ; later_runtime_ids = List.map runtime_id_of later
                ; failure = error
                }
            | false, _ | true, [] -> ());
           Error error))
  in
  loop 0 candidates

let runtime_candidate_missing_error id =
  Agent_sdk.Error.Internal
    (Printf.sprintf
       "keeper_turn_driver: lane candidate %S disappeared from runtimes"
       id)

let resolve_runtime_candidate id =
  match Runtime.get_runtime_by_id id with
  | Some runtime -> Ok runtime
  | None -> Error (runtime_candidate_missing_error id)

let resolve_runtime_candidate_for_attempt ?on_missing id =
  match resolve_runtime_candidate id with
  | Ok _ as resolved -> resolved
  | Error _ as missing ->
    Option.iter (fun consume -> consume ()) on_missing;
    missing

let resolve_runtime_candidates ids =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | id :: rest ->
      let* runtime = resolve_runtime_candidate id in
      loop (runtime :: acc) rest
  in
  loop [] ids

let dedupe_runtimes_preserve_order runtimes =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | runtime :: rest ->
      let runtime_id = runtime.Runtime.id in
      if List.exists (String.equal runtime_id) seen then
        loop seen acc rest
      else
        loop (runtime_id :: seen) (runtime :: acc) rest
  in
  loop [] [] runtimes

let lane_modality_reroute_decision ~checkpoint_messages ~initial_messages
    ~goal_blocks ~first_candidate ~remaining_runtimes =
  Runtime_agent.decide_modality_reroute_for_runtime_candidates
    ~assigned:first_candidate
    ~candidates:remaining_runtimes
    ~checkpoint_messages
    ~initial_messages
    goal_blocks

let first_runtime_after_modality_reroute ~keeper_name ~assignment_id
    ~first_candidate_id ~first_candidate = function
  | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ ->
    first_candidate_id, first_candidate
  | Runtime_agent.Reroute { to_runtime_id; reason } ->
    (match Runtime.get_runtime_by_id to_runtime_id with
     | None -> first_candidate_id, first_candidate
     | Some rerouted ->
       Log.Keeper.warn
         "%s: RFC-0265 modality reroute %s -> %s (%s)"
         keeper_name
         assignment_id
         to_runtime_id
         reason;
       to_runtime_id, rerouted)

type attempt_inference_policy =
  { attempt_enable_thinking : bool option
  ; attempt_preserve_thinking : bool option
  }

let attempt_inference_policy
    ~runtime_id
    ~fallback_enable_thinking
    ()
  =
  let runtime_seed = Runtime_inference.for_runtime ~name:runtime_id in
  let attempt_enable_thinking =
    match runtime_seed.thinking_enabled with
    | Some _ as enabled -> enabled
    | None -> fallback_enable_thinking
  in
  { attempt_enable_thinking
  ; attempt_preserve_thinking = runtime_seed.preserve_thinking
  }

let run_named
    ~runtime_id
    ?(keeper_name = "")
    ~base_path
    ~goal
    ?goal_blocks
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?model_input_projection
    ?stream_idle_timeout_s
    ?body_timeout_s
    ?temperature
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?hooks
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?transport
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?checkpoint_sink
    ?context_injector
    ?context
    ?enable_thinking
    ?cooperative_yield_probe
    ?oas_checkpoint
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?deferred_runtime_lane
    ?on_runtime_retry_deferred
    ?on_deferred_runtime_consumed
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
	  (* Lane-aware dispatch: resolve a runtime id or ordered failover lane, then
	     attempt candidates sequentially with manifest evidence per attempt. *)
	  let runtime_id = String.trim runtime_id in
	  (* Audit F8: removed dead routing knobs from the signature so callers cannot
	     pass values that would be silently ignored. *)
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  let checkpoint_stage_observed = Atomic.make false in
  let emit_runtime_manifest ?status ?decision event =
    match runtime_manifest_context, runtime_manifest_append with
    | Some manifest_ctx, Some append ->
      let decision =
        match decision with
        | None -> Some (`Assoc [])
        | Some (`Assoc _) as d -> d
        | Some other -> Some (`Assoc [ ("decision", other) ])
      in
      seq_ref := !seq_ref + 1;
      let elapsed_ms =
        let ns =
          Mtime.Span.to_uint64_ns
            (Mtime.span turn_start (Mtime_clock.now ()))
        in
        Some (Int64.to_int (Int64.div ns 1_000_000L))
      in
      let decision =
        let decision =
          match decision with
          | Some value -> value
          | None -> `Assoc []
        in
        Some
          (Keeper_runtime_manifest.with_clock_refs
             ~clock_refs:
               (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx
                  ~event ?elapsed_ms ~logical_seq:!seq_ref ())
             decision)
      in
      Keeper_runtime_manifest.make_for_context manifest_ctx ~event
        ~runtime_id ?logical_seq:(Some !seq_ref) ?status ?decision ()
      |> append
    | _ -> ()
  in
  (* Lanes shadow runtimes: a lane id takes precedence over a runtime id so
     operators can route through explicit failover groups.  Lane candidate
     order passes through the sticky last-good preference so a known-healthy
     failover candidate is tried before re-hitting a dead head candidate. *)
  let lane_id_opt, lane_candidate_ids =
    match deferred_runtime_lane with
    | Some hint -> Some hint.assignment_id, deferred_runtime_ids hint
    | None ->
      (match Runtime.resolve_assignment runtime_id with
       | `Missing -> None, []
       | `Single_runtime runtime -> None, [ runtime.Runtime.id ]
       | `Lane lane ->
         let lane_id = Runtime_lane.id lane in
         ( Some lane_id
         , Runtime_lane_preference.prefer_order ~lane_id
             (Runtime_lane.ordered_candidates lane) ))
  in
  if lane_candidate_ids = []
  then
    Error
      (Agent_sdk.Error.Internal
         (Printf.sprintf
            "requested runtime or lane %S not found among configured runtimes"
            runtime_id))
  else
  (* RFC-0265: reroute when active input modality exceeds the first candidate's
     capabilities; later lane candidates remain in declared order. *)
  let current_goal_blocks =
    match goal_blocks with
    | Some blocks -> blocks
    | None ->
      []
  in
  let checkpoint_messages =
    match oas_checkpoint with
    | None -> []
    | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages
  in
  (* [initial_messages] is the caller's canonical pre-turn history and is the
     exact prefix checked later by replay persistence.  A resumed checkpoint is
     only the OAS dispatch carrier; media degradation may project its messages
     without changing this canonical history. *)
  let canonical_replay_prefix = initial_messages in
  let first_candidate_id, remaining_candidate_ids =
    match lane_candidate_ids with
    | first :: rest -> first, rest
    | [] -> runtime_id, []
  in
  let* first_candidate =
    resolve_runtime_candidate_for_attempt
      ?on_missing:
        (match deferred_runtime_lane with
         | Some _ -> on_deferred_runtime_consumed
         | None -> None)
      first_candidate_id
  in
  let* remaining_runtimes =
    match deferred_runtime_lane with
    | Some _ -> Ok []
    | None -> resolve_runtime_candidates remaining_candidate_ids
  in
  let reroute_decision =
    match deferred_runtime_lane with
    | Some _ -> Runtime_agent.No_reroute_needed
    | None ->
      lane_modality_reroute_decision
        ~checkpoint_messages
        ~initial_messages
        ~goal_blocks:current_goal_blocks
        ~first_candidate
        ~remaining_runtimes
  in
  let first_runtime_id, first_runtime =
    first_runtime_after_modality_reroute ~keeper_name ~assignment_id:runtime_id
      ~first_candidate_id ~first_candidate reroute_decision
  in
  let attempt_runtimes =
    dedupe_runtimes_preserve_order (first_runtime :: remaining_runtimes)
  in
  let attempt_candidates =
    match deferred_runtime_lane with
    | None -> List.map (fun runtime -> Resolved_runtime runtime) attempt_runtimes
    | Some hint ->
      List.map
        (fun runtime_id ->
           match Runtime.get_runtime_by_id runtime_id with
           | Some runtime -> Resolved_runtime runtime
           | None -> Missing_runtime runtime_id)
        (deferred_runtime_ids hint)
  in
  let assigned_runtime_context_window =
    Runtime.max_context_of_runtime first_candidate
  in
  let first_runtime_context_window =
    Runtime.max_context_of_runtime first_runtime
  in
  (match reroute_decision with
   | Runtime_agent.Reroute { reason; _ } ->
     emit_runtime_manifest
       ~status:"rerouted"
       ~decision:
         (Keeper_runtime_manifest.with_payload_role
            ~payload_role:Keeper_runtime_manifest.Operator_evidence
            (`Assoc
              [
                ("routing_action", `String "modality_rerouted");
                ("routing_reason", `String reason);
                ("assigned_runtime_id", `String first_candidate_id);
                ("rerouted_runtime_id", `String first_runtime_id);
                ("assigned_context_window", `Int assigned_runtime_context_window);
                ("rerouted_context_window", `Int first_runtime_context_window);
              ]))
       Keeper_runtime_manifest.Runtime_routed
   | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ -> ());
  (* RFC-0265 follow-up — graceful media degrade floor. When no configured
     runtime can accept the turn's input modality ([No_capable_runtime]), strip
     the unsupported media blocks from the goal, prior [initial_messages], and
     resumed checkpoint, then append a degraded [Runtime_routed] manifest row
     and inject a text notice so the turn runs on text instead of the loud
     terminal reject in [Runtime_agent.run_blocks]. Modality-satisfied turns and
     reroutes are untouched. The drop is non-silent (WARN log + runtime manifest
     row + injected model-input notice — RFC-0126/0145). The stripped checkpoint
     is the dispatch view only; the persisted checkpoint is unchanged, so a
     later vision-capable runtime still sees the original media. *)
  let goal_blocks, initial_messages, oas_checkpoint, replay_prefix_projection =
    match reroute_decision with
    | Runtime_agent.No_capable_runtime _ ->
      let caps = Runtime_agent.input_capabilities_of_runtime first_runtime in
      let stripped_goal, goal_dropped =
        Runtime_agent.strip_unsupported_modality_blocks caps current_goal_blocks
      in
      let stripped_initial, initial_dropped =
        Runtime_agent.strip_unsupported_modality_messages caps initial_messages
      in
      let stripped_checkpoint, checkpoint_dropped =
        match oas_checkpoint with
        | None -> None, []
        | Some (checkpoint : Agent_sdk.Checkpoint.t) ->
          let messages, dropped =
            Runtime_agent.strip_unsupported_modality_messages
              caps
              checkpoint.messages
          in
          Some { checkpoint with messages }, dropped
      in
      let dropped =
        Runtime_agent.merge_modality_counts
          (Runtime_agent.merge_modality_counts goal_dropped initial_dropped)
          checkpoint_dropped
      in
      (match Runtime_agent.media_degrade_note ~runtime_id:first_runtime_id dropped with
       | None ->
         (* Nothing strippable (e.g. only ToolResult-nested media): keep the
            inputs unchanged so the loud capability floor still applies. *)
         goal_blocks, initial_messages, oas_checkpoint, Keeper_replay_prefix.unchanged
       | Some note ->
         Log.Keeper.warn
           "%s: RFC-0265 media degrade on %s — dropped %s, continuing text-only"
           keeper_name
           first_runtime_id
           (modality_counts_summary dropped);
         emit_runtime_manifest
           ~status:"degraded"
           ~decision:(media_degrade_manifest_decision ~runtime_id:first_runtime_id dropped)
           Keeper_runtime_manifest.Runtime_routed;
         let goal_with_note =
           stripped_goal @ [ Agent_sdk.Types.text_block note ]
         in
         let dispatch_prefix =
           match stripped_checkpoint with
           | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages
           | None -> stripped_initial
         in
         ( Some goal_with_note
         , stripped_initial
         , stripped_checkpoint
         , Keeper_replay_prefix.media_degraded
             ~canonical_prefix:canonical_replay_prefix
             ~dispatch_prefix ))
    | Runtime_agent.No_reroute_needed | Runtime_agent.Reroute _ ->
      goal_blocks, initial_messages, oas_checkpoint, Keeper_replay_prefix.unchanged
  in
  let transport_resolved =
    match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return. *)
  attempt_runtime_candidates
    ?lane_id:lane_id_opt
    ?on_retry_deferred:on_runtime_retry_deferred
    ~allow_retry:(fun ~runtime_id:attempt_runtime_id ~attempt error ->
      let allowed =
        Keeper_turn_driver_try_provider.same_run_retry_allowed
          checkpoint_stage_observed
      in
      if not allowed
      then
        Log.Keeper.info
          "%s: runtime lane retry deferred after typed OAS checkpoint stage \
           (runtime_id=%s attempt=%d error_kind=%s); the next keeper cycle \
           remains eligible"
          keeper_name
          attempt_runtime_id
          attempt
          (Oas_compat.error_kind error);
      allowed)
    ~runtime_id:
      (match deferred_runtime_lane with
       | Some hint -> hint.assignment_id
       | None -> runtime_id)
    ~runtime_id_of:(function
      | Resolved_runtime runtime -> runtime.Runtime.id
      | Missing_runtime runtime_id -> runtime_id)
    ~emit_runtime_manifest
    ~run_attempt:(fun ~idx:_ ~runtime_id:attempt_runtime_id candidate ->
      match candidate with
      | Missing_runtime runtime_id ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        Error (runtime_candidate_missing_error runtime_id), None
      | Resolved_runtime runtime ->
      let error_runtime_id = attempt_runtime_id in
      let inference_policy =
        attempt_inference_policy
          ~runtime_id:attempt_runtime_id
          ~fallback_enable_thinking:enable_thinking
          ()
      in
      match
         match provider_config_transform with
         | None -> Ok runtime.Runtime.provider_config
         | Some transform -> transform runtime.Runtime.provider_config
      with
      | Error err ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        Error err, None
      | Ok provider_config ->
        let candidate = Runtime_candidate.of_provider_config provider_config in
        (* Cached provider health is observation only. Every eligible runtime
           reaches the real provider boundary; only the resulting typed error
           may drive fallback. *)
        let name = Printf.sprintf "oas-%s" attempt_runtime_id in
          let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx =
            { runtime_id = attempt_runtime_id
            ; error_runtime_id
            ; base_path
            ; keeper_name
            ; name
            ; goal
            ; goal_blocks
            ; session_id
            ; system_prompt
            ; tools
            ; initial_messages
            ; model_input_projection
            ; stream_idle_timeout_s
            ; body_timeout_s
            ; temperature
            ; accept
            ; hooks
            ; raw_trace
            ; transport_resolved
            ; checkpoint_sidecar
            ; cache_system_prompt
            ; yield_on_tool
            ; checkpoint_sink
            ; checkpoint_stage_observed
            ; context_injector
            ; context
            ; enable_thinking = inference_policy.attempt_enable_thinking
            ; preserve_thinking = inference_policy.attempt_preserve_thinking
            ; cooperative_yield_probe
            ; oas_checkpoint
            ; trace_link
            ; sw
            ; net
            ; on_event
            ; on_yield
            ; on_resume
            ; agent_ref
            ; on_runtime_observation
            ; event_bus
            ; runtime_manifest_context
            ; runtime_manifest_append
            ; turn_start
            ; seq_ref
            }
          in
          Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
          let provider_result, checkpoint_after, _success_sample =
            Keeper_turn_driver_try_provider.run_try_provider
              try_provider_ctx candidate
          in
          let outcomes =
            project_provider_attempt_result
              ~replay_prefix_projection
              provider_result
          in
          outcomes.turn_result, checkpoint_after)
    attempt_candidates


module For_testing = struct
  type nonrec provider_attempt_outcomes = provider_attempt_outcomes

  let make_deferred_runtime_lane ~assignment_id ~failed_runtime_id
        ~next_runtime_id ~later_runtime_ids ~failure =
    { assignment_id
    ; failed_runtime_id
    ; next_runtime_id
    ; later_runtime_ids
    ; failure
    }
  ;;

  let project_provider_attempt_result = project_provider_attempt_result
  let provider_result outcomes = outcomes.provider_result
  let turn_result outcomes = outcomes.turn_result
  let checkpoint_after_attempt = checkpoint_after_attempt
  let success_selected_model_raw = success_selected_model_raw
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let first_runtime_after_modality_reroute =
    first_runtime_after_modality_reroute

  let lane_modality_reroute_decision = lane_modality_reroute_decision
  let dedupe_runtimes_preserve_order = dedupe_runtimes_preserve_order
  let resolve_runtime_candidates = resolve_runtime_candidates
  let resolve_runtime_candidate_for_attempt =
    resolve_runtime_candidate_for_attempt

	  let media_degrade_manifest_decision = media_degrade_manifest_decision
	  let attempt_inference_policy = attempt_inference_policy
  let attempt_runtime_candidates = attempt_runtime_candidates

  let observe_checkpoint_stage =
    Keeper_turn_driver_try_provider.observe_checkpoint_stage

  let same_run_retry_allowed =
    Keeper_turn_driver_try_provider.same_run_retry_allowed

  let accept_no_progress_should_try_next =
    Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next

end
