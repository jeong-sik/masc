(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running AGENT_CORE agents through MASC-managed named runtime
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    Owns one Keeper turn over the MASC runtime boundary. *)

open Result.Syntax

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Runtime_agent_core_runner
include Keeper_internal_error
include Keeper_turn_driver_helpers

include Keeper_turn_driver_provider_attempt
include Keeper_turn_driver_backpressure

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
  (Runtime_agent.run_result, Agent_core.Error.t) result

type provider_attempt_outcomes =
  { provider_result : provider_run_result
  ; turn_result : provider_run_result
  }

type named_run_result =
  { run_result : Runtime_agent.run_result
  ; selected_runtime_id : string
  ; selected_max_context : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  ; lane_attempt_index : int
  }

type runtime_attempt =
  { runtime_id : string
  ; lane_attempt_index : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  }

type runtime_attempt_candidate =
  | Resolved_runtime of Runtime.t
  | Missing_runtime of string

let selected_runtime_result (runtime : Runtime.t) ~lane_attempt_index result =
  Result.map
    (fun run_result ->
       { run_result
       ; selected_runtime_id = runtime.id
       ; selected_max_context = Runtime.max_context_of_runtime runtime
       ; checkpoint_owner = Runtime_execution.checkpoint_owner runtime.execution
       ; lane_attempt_index
       })
    result
;;

let apply_official_client_accept ~runtime_id ~accept ~terminal_effect_state
    (run_result : Runtime_agent.run_result) =
  match run_result.stop_reason, terminal_effect_state () with
  | ( Runtime_agent.Completed
    , Keeper_tools_agent_core.Terminal_effect_completed _ ) ->
    Ok run_result
  | _ ->
    Keeper_turn_driver_try_provider.apply_accept
      ~runtime_id
      ~accept
      run_result
;;

type deferred_runtime_lane =
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Agent_core.Error.t
  }

let deferred_runtime_ids hint =
  hint.next_runtime_id :: hint.later_runtime_ids

(* Quota demotion must never promote a candidate the runtime table cannot
   resolve (for example one removed by a runtime.toml reload while a deferred
   suffix was frozen): a missing id at the head fails the attempt with a
   non-rotating error before resolvable alternatives are tried. Order is
   therefore resolvable-active, then resolvable-exhausted, then unresolvable —
   declared relative order preserved within each class (PR #28219 review). *)
let quota_ordered_runtime_ids ~now runtime_ids =
  let resolvable, unresolvable =
    List.partition
      (fun id -> Option.is_some (Runtime.get_runtime_by_id id))
      runtime_ids
  in
  Runtime_quota_window.demote_order
    ~now
    ~quota_scope_of:Runtime.quota_scope_of_runtime_id
    resolvable
  @ unresolvable
;;

let quota_ordered_deferred_runtime_lane ~now hint =
  match quota_ordered_runtime_ids ~now (deferred_runtime_ids hint) with
  | next_runtime_id :: later_runtime_ids ->
    { hint with next_runtime_id; later_runtime_ids }
  | [] -> hint
;;

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
              (Agent_core.Error.Internal
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
      ( "error_kind"
      , `String Agent_core.Error.(category error |> category_label) );
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
       serve the same turn. [core_error_to_http_error] folds it into a generic
       HTTP 400 which [Runtime_attempt_fsm.should_try_next] treats as terminal,
       so the typed error must be read before that mapping. Overflow on the
       last candidate still returns the typed error, keeping the typed
       overflow observation (blocker label, failure route) intact. *)
    true
  else if Keeper_turn_driver_try_runtime.attempt_rejected_should_try_next error
  then
    true
  else
    match Keeper_turn_driver_try_runtime.core_error_to_http_error error with
    | Some http_err -> Runtime_attempt_fsm.should_try_next http_err
    | None -> false

let attempt_runtime_candidates
    ?(pre_tool_rejects = ref [])
    ?(allow_retry = fun ~runtime_id:_ ~attempt:_ _error -> true)
    ?(allow_accept_no_progress_retry = fun ~runtime_id:_ ~attempt:_ _error ->
      true)
    ?lane_id
    ?(on_retry_deferred = fun _ -> ())
    ?(on_attempt_error = fun ~runtime_id:_ ~attempt:_ _error -> ())
    ?quota_scope_of
    ?candidate_dispatchable
    ~runtime_id ~runtime_id_of
    ~(emit_runtime_manifest :
       ?status:string ->
       ?decision:Yojson.Safe.t ->
       Keeper_runtime_manifest.event_kind ->
       unit) ~run_attempt candidates =
  (* A typed overflow observed on any candidate is a fact about this turn's
     input, not about whichever candidate happened to fail last. When the
     lane ends on a different recoverable error (for example a rate-limited
     fallback), returning that last error would hide the overflow from the
     lane classifier: the failure route would misreport a transient error
     instead of the deterministic capacity bound, and the operator-facing
     blocker would name the wrong cause (#26530). Remember the first typed
     overflow and let it represent a naturally exhausted lane. A lane that
     stops on a non-recoverable error keeps that error: it is the immediate
     operator signal, and the overflow will be observed again on the next
     cycle. *)
  let quota_scope_of =
    match quota_scope_of with
    | Some quota_scope_of -> quota_scope_of
    | None ->
      fun candidate ->
        Runtime.quota_scope_of_runtime_id (runtime_id_of candidate)
  in
  (* Mid-walk demotion shares the pre-walk rule: never move an
     exhausted-but-dispatchable candidate behind one that cannot dispatch, or
     the walk fails on the dead head with a non-rotating error before real
     alternatives are tried (PR #28219 review). Dispatchability is judged on
     the candidate value itself — production candidates are materialized
     snapshots that stay dispatchable across a runtime.toml reload, so a
     global-registry re-read here would wrongly sink a frozen [Resolved_runtime]
     and promote a known-exhausted sibling ahead of it (PR #28219 review,
     frozen-candidates thread). Callers with richer candidate types inject the
     judgment; the id-table default serves plain-id callers, and a fixture-less
     table judges everything undispatchable, which leaves order unchanged. *)
  let candidate_dispatchable =
    match candidate_dispatchable with
    | Some candidate_dispatchable -> candidate_dispatchable
    | None ->
      fun candidate ->
        Option.is_some (Runtime.get_runtime_by_id (runtime_id_of candidate))
  in
  let demote_rest rest =
    let dispatchable, undispatchable =
      List.partition candidate_dispatchable rest
    in
    Runtime_quota_window.demote_order
      ~now:(Unix.gettimeofday ())
      ~quota_scope_of
      dispatchable
    @ undispatchable
  in
  let rec loop ~observed_overflow idx = function
    | [] ->
      (match observed_overflow with
       | Some overflow_error -> Error overflow_error
       | None ->
         Error
           (Agent_core.Error.Internal
              (Printf.sprintf
                 "runtime lane %S exhausted all candidates"
                 runtime_id)))
    | candidate :: rest ->
      let is_last = rest = [] in
      let attempt_runtime_id = runtime_id_of candidate in
      (* Bind quota ownership to the exact candidate that will be dispatched.
         [run_attempt] may span a runtime.toml reload; resolving the id after
         the provider returns could then attribute the old credential's
         response to the replacement catalog row. *)
      let attempt_quota_scope = quota_scope_of candidate in
      emit_runtime_manifest
        ~status:"attempt"
        ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
        Keeper_runtime_manifest.Runtime_routed;
      (match
         run_attempt ~idx ~runtime_id:attempt_runtime_id candidate
       with
       | Ok value, _checkpoint_after, _effect_disposition ->
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
       | Error error, _checkpoint_after, effect_disposition ->
         emit_runtime_manifest
           ~status:"failed"
           ~decision:(runtime_failed_decision ~idx ~runtime_id:attempt_runtime_id error)
           Keeper_runtime_manifest.Runtime_failed;
         on_attempt_error
           ~runtime_id:attempt_runtime_id
           ~attempt:idx
           error;
         (* A hard-quota rejection with a provider-stated reset time is an
            account-scoped fact; remember it so later lane ordering stops
            re-dispatching into the exhausted window (RFC-0370 §3.3). The
            provider identity comes from the attempted candidate's catalog
            row, not the error payload, so both sides of the window share
            one namespace. Quota errors without [retry_after] record
            nothing — a cooldown the provider never stated would be a
            synthesized default. *)
         (match error with
          | Agent_core.Error.Provider
              (Llm_provider.Error.HardQuota { retry_after = Some retry_after_s; _ })
            ->
            (* Quota is credential-account-owned, so the window is keyed by
               the row's quota scope: siblings sharing the credential are
               demoted together (PR #28202 review P2). *)
            (match attempt_quota_scope with
             | Some scope ->
               Runtime_quota_window.note_exhausted
                 ~scope
                 (* NDT-OK: [retry_after] is relative to the provider response;
                    convert it to the wall-clock expiry at this ingress. *)
                 ~resets_at:(Unix.gettimeofday () +. retry_after_s)
             | None -> ())
          | _ -> ());
         (* The window just learned above must affect this same lane walk.
            Otherwise a sibling on the same credential is retried before an
            unrelated candidate even though the provider has already stated
            that the shared account is exhausted.  This remains ordering,
            not admission: if every remaining candidate is demoted they are
            all still attempted in their prior relative order. *)
         let rest = demote_rest rest in
         let retry_admitted =
           allow_retry ~runtime_id:attempt_runtime_id ~attempt:idx error
         in
         let effect_retry_admitted =
           Keeper_provider_attempt_effect.allows_same_turn_retry
             effect_disposition
         in
         let terminal_error =
           match effect_disposition with
           | Keeper_provider_attempt_effect.No_effect_observed -> error
           | Keeper_provider_attempt_effect.Effect_attempted
           | Keeper_provider_attempt_effect.Observation_unavailable ->
             (* masc#28885: a fence on a turn that also recorded typed
                pre_tool_use rejections gets its own terminal label — the
                model's correction round-trip was the visible casualty.
                Disposition is identical to the plain fence. *)
             (match !pre_tool_rejects with
              | [] ->
                core_error_of_masc_internal_error
                  (Provider_attempt_effect_fenced
                     { runtime_id = attempt_runtime_id
                     ; effect_disposition
                     ; diagnostic = Agent_core.Error.to_string error
                     })
              | rejects ->
                core_error_of_masc_internal_error
                  (Tool_correction_lost
                     { runtime_id = attempt_runtime_id
                     ; effect_disposition
                     ; reject_count = List.length rejects
                     ; diagnostic = Agent_core.Error.to_string error
                     }))
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
         let error_is_retryable =
           lane_should_retry
             ~is_last
             ~allow_retry:true
             ~allow_accept_no_progress_retry
             error
         in
         let observed_overflow =
           match observed_overflow with
           | Some _ -> observed_overflow
           | None ->
             if
               Keeper_turn_driver_try_runtime.context_overflow_should_try_next
                 error
             then Some error
             else None
         in
         if not effect_retry_admitted
         then Error terminal_error
         else if retry_admitted && error_is_retryable
         then loop ~observed_overflow (idx + 1) rest
         else if is_last
         then (
           (* Lane fully exhausted: an overflow seen anywhere in the rotation
              outranks the last candidate's error so the failure route and
              blocker report the deterministic capacity bound. Cascade
              telemetry already published each candidate's own error. *)
           match observed_overflow with
           | Some overflow_error -> Error overflow_error
           | None -> Error error)
         else (
           (match error_is_retryable, effect_retry_admitted, rest with
            | true, true, next :: later ->
              on_retry_deferred
                { assignment_id = runtime_id
                ; failed_runtime_id = attempt_runtime_id
                ; next_runtime_id = runtime_id_of next
                ; later_runtime_ids = List.map runtime_id_of later
                ; failure = error
                }
            | false, _, _ | true, false, _ | true, true, [] -> ());
           Error terminal_error))
  in
  loop ~observed_overflow:None 0 candidates

let runtime_candidate_missing_error id =
  Agent_core.Error.Internal
    (Printf.sprintf
       "keeper_turn_driver: lane candidate %S disappeared from runtimes"
       id)

let runtime_candidate_missing_request_cap_error error =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "max-request-body-bytes"
       ; detail = Runtime.request_body_cap_error_to_string error
       })

let validate_provider_request_cap ~runtime_id
    (provider_config : Llm_provider.Provider_config.t) =
  match Runtime.validate_request_body_cap ~runtime_id provider_config with
  | Ok cap -> Ok cap
  | Error error -> Error (runtime_candidate_missing_request_cap_error error)

let resolve_runtime_candidate id =
  match Runtime.get_runtime_by_id id with
  | Some runtime ->
    (match runtime.Runtime.execution with
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ -> Ok runtime
     | Runtime_execution.Agent_core provider_config ->
       let* _request_body_cap =
         validate_provider_request_cap
           ~runtime_id:runtime.id
           provider_config
       in
       Ok runtime)
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
  { attempt_enable_thinking; attempt_preserve_thinking = runtime_seed.preserve_thinking }

let run_named
    ~runtime_id
    ?(keeper_name = "")
    ?pre_tool_rejects
    ~base_path
    ~goal
    ?goal_blocks
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?deferred_tool_surface
    ?(initial_messages = [])
    ?model_input_projection
    ?stream_idle_timeout_s
    ?body_timeout_s
    ?temperature
    ?(accept = fun (_ : Agent_core.Types.api_response) -> true)
    ?hooks
    ?approval_gate
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
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?enable_thinking
    ?cooperative_yield_probe
    ?agent_core_checkpoint
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?on_request_wire_observation
    ?on_official_client_result_handoff
    ?on_official_client_native_action
    ?on_model_input_window_observation
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?deferred_runtime_lane
    ?on_runtime_attempt
    ?on_runtime_retry_deferred
    ?on_runtime_attempt_error
    ?on_deferred_runtime_consumed
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (named_run_result, Agent_core.Error.t) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_core_error e)
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
  (* Quota-window demotion is ordering only — a demoted candidate is still
     attempted when the lane has nothing else (RFC-0370 §3.3). Apply it while
     selecting a fresh lane walk. A deferred suffix was already frozen before
     pre-dispatch shaping, so re-reading wall-clock quota state here could make
     the actual provider differ from the runtime used to shape the request. *)
  let pre_tool_rejects =
    match pre_tool_rejects with
    | Some rejects -> rejects
    | None -> ref []
  in
  let demote_quota_exhausted candidates =
    quota_ordered_runtime_ids
      (* NDT-OK: scheduling intentionally compares the stored expiry with
         wall clock; [demote_order] stays pure via injected [now]. *)
      ~now:(Unix.gettimeofday ())
      candidates
  in
  let lane_id_opt, lane_candidate_ids =
    match deferred_runtime_lane with
    | Some hint ->
      Some hint.assignment_id, deferred_runtime_ids hint
    | None ->
      (match Runtime.resolve_assignment runtime_id with
       | `Missing -> None, []
       | `Lane lane ->
         let lane_id = Runtime_lane.id lane in
         ( Some lane_id
         , (* Demotion runs after sticky preference: a provider that stated
              "exhausted until T" outranks a remembered last-good candidate
              on that same account. *)
           Runtime_lane_preference.prefer_order ~lane_id
             (Runtime_lane.ordered_candidates lane)
           |> demote_quota_exhausted ))
  in
  if lane_candidate_ids = []
  then
    Error
      (Agent_core.Error.Internal
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
    match agent_core_checkpoint with
    | None -> []
    | Some (checkpoint : Agent_core.Checkpoint.t) -> checkpoint.messages
  in
  (* [initial_messages] is the caller's canonical pre-turn history and is the
     exact prefix checked later by replay persistence.  A resumed checkpoint is
     only the AGENT_CORE dispatch carrier; media degradation may project its messages
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
        lane_candidate_ids
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
  let goal_blocks, initial_messages, agent_core_checkpoint, replay_prefix_projection =
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
        match agent_core_checkpoint with
        | None -> None, []
        | Some (checkpoint : Agent_core.Checkpoint.t) ->
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
         goal_blocks, initial_messages, agent_core_checkpoint, Keeper_replay_prefix.unchanged
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
           stripped_goal @ [ Agent_core.Types.text_block note ]
         in
         let dispatch_prefix =
           match stripped_checkpoint with
           | Some (checkpoint : Agent_core.Checkpoint.t) -> checkpoint.messages
           | None -> stripped_initial
         in
         ( Some goal_with_note
         , stripped_initial
         , stripped_checkpoint
         , Keeper_replay_prefix.media_degraded
             ~canonical_prefix:canonical_replay_prefix
             ~dispatch_prefix ))
    | Runtime_agent.No_reroute_needed | Runtime_agent.Reroute _ ->
      goal_blocks, initial_messages, agent_core_checkpoint, Keeper_replay_prefix.unchanged
  in
  let transport_resolved =
    match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return. *)
  attempt_runtime_candidates
    ~pre_tool_rejects
    ?lane_id:lane_id_opt
    ?on_retry_deferred:on_runtime_retry_deferred
    ?on_attempt_error:on_runtime_attempt_error
    ~allow_retry:(fun ~runtime_id:attempt_runtime_id ~attempt error ->
      let allowed =
        Keeper_turn_driver_try_provider.same_run_retry_allowed
          checkpoint_stage_observed
      in
      if not allowed
      then
        Log.Keeper.info
          "%s: runtime lane retry deferred after typed AGENT_CORE checkpoint stage \
           (runtime_id=%s attempt=%d error_kind=%s); the next keeper cycle \
           remains eligible"
          keeper_name
          attempt_runtime_id
          attempt
          Agent_core.Error.(category error |> category_label);
      allowed)
    ~runtime_id:
      (match deferred_runtime_lane with
       | Some hint -> hint.assignment_id
       | None -> runtime_id)
    ~runtime_id_of:(function
      | Resolved_runtime runtime -> runtime.Runtime.id
      | Missing_runtime runtime_id -> runtime_id)
    ~quota_scope_of:(function
      | Resolved_runtime runtime -> Some (Runtime.quota_scope_of_runtime runtime)
      | Missing_runtime _ -> None)
    ~candidate_dispatchable:(function
      (* A materialized snapshot stays dispatchable even if a runtime.toml
         reload removed its id from the current table; only a candidate that
         never resolved is a dead head. *)
      | Resolved_runtime _ -> true
      | Missing_runtime _ -> false)
    ~emit_runtime_manifest
    ~run_attempt:(fun ~idx ~runtime_id:attempt_runtime_id candidate ->
      match candidate with
      | Missing_runtime runtime_id ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        ( Error (runtime_candidate_missing_error runtime_id)
        , None
        , Keeper_provider_attempt_effect.No_effect_observed )
      | Resolved_runtime runtime ->
      Option.iter
        (fun observe ->
           observe
             { runtime_id = attempt_runtime_id
             ; lane_attempt_index = idx
             ; checkpoint_owner =
                 Runtime_execution.checkpoint_owner runtime.Runtime.execution
             })
        on_runtime_attempt;
      let error_runtime_id = attempt_runtime_id in
      let inference_policy =
        attempt_inference_policy
          ~runtime_id:attempt_runtime_id
          ~fallback_enable_thinking:enable_thinking
          ()
      in
      match runtime.Runtime.execution with
      | Runtime_execution.Codex_app_server config ->
        let run_codex ~initial_messages () =
          Keeper_codex_runtime.run
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection
            (* Codex assembles the wire itself, so the shape masc can report
               is the list it handed over. Same reading the Agent Core path
               publishes; without it the turn record has no window. *)
            ?on_model_input_window_observation:
              (Option.map
                 (fun observe observation ->
                    observe ~measurement:Turn_record.Durable_shape observation)
                 on_model_input_window_observation)
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ~on_official_client_result_handoff:
              (fun ~invocation ~content ->
                 Option.iter
                   (fun observe ->
                      observe ~runtime_id:attempt_runtime_id ~invocation ~content)
                   on_official_client_result_handoff)
            ~on_native_action:
              (fun ~official_turn ~identity ~tool_name ->
                 Option.iter
                   (fun observe -> observe ~runtime_id:attempt_runtime_id ~official_turn ~identity ~tool_name)
                   on_official_client_native_action)
            ~event_bus
            ~raw_trace
            ~on_event
            ~config
            ()
        in
        let codex_attempt =
          match provider_config_transform, agent_core_checkpoint with
          | Some _, _ ->
            { Keeper_codex_runtime.result =
                Error
                  (Agent_core.Error.Config
                     (Agent_core.Error.InvalidConfig
                        { field = "provider_config_transform"
                        ; detail =
                            "provider config transforms cannot target a \
                             codex-app-server runtime"
                        }))
            ; effect_disposition =
                Keeper_provider_attempt_effect.No_effect_observed
            ; successful_tool_completion =
                Keeper_codex_runtime.No_successful_tool_completion
            }
          | None, checkpoint ->
            (* The official-client session store is the start-or-resume
               authority ([Keeper_codex_runtime] reads the durable
               [previous_settlement]); the AGENT_CORE checkpoint payload is never
               replayed on this lane, but the representable canonical history
               is preserved instead of being erased with it (masc#27812). *)
            (match checkpoint with
             | Some _ ->
               Log.Keeper.info
                 "%s: official-client runtime %s resolves start-or-resume from \
                  its durable session store; the AGENT_CORE checkpoint payload is not \
                  replayed"
                 keeper_name attempt_runtime_id;
               emit_runtime_manifest
                 ~status:"checkpoint_not_replayed"
                 ~decision:
                   (`Assoc
                     [ ( "routing_action"
                       , `String "official_client_checkpoint_not_replayed" )
                     ; ( "routing_reason"
                       , `String "official_client_session_store_owns_resume" )
                     ])
                 Keeper_runtime_manifest.Runtime_routed
             | None -> ());
            run_codex ~initial_messages ()
        in
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        let codex_result =
          Result.bind codex_attempt.result (fun run_result ->
            match codex_attempt.successful_tool_completion with
            | Keeper_codex_runtime.Successful_tool_completion ->
              (match
                 run_result.Runtime_agent.stop_reason,
                 run_result.response.content
               with
               | Runtime_agent.Completed, [ Agent_core.Types.Text text ]
                 when String.trim text = "" ->
                 Ok run_result
               | _ ->
                 apply_official_client_accept
                   ~runtime_id:attempt_runtime_id
                   ~accept
                   ~terminal_effect_state
                   run_result)
            | Keeper_codex_runtime.No_successful_tool_completion ->
              apply_official_client_accept
                ~runtime_id:attempt_runtime_id
                ~accept
                ~terminal_effect_state
                run_result)
        in
        (match codex_result with
         | Ok run_result ->
           Option.iter
             (fun observe -> Option.iter observe run_result.Runtime_agent.runtime_observation)
             on_runtime_observation
         | Error _ -> ());
        ( selected_runtime_result runtime ~lane_attempt_index:idx codex_result
        , None
        , codex_attempt.effect_disposition )
      | Runtime_execution.Antigravity_cli config ->
        let run_antigravity ~initial_messages () =
          Keeper_antigravity_runtime.run
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            (* Antigravity's CLI assembles the wire, so the shape masc can
               report is the list it handed over. *)
            ?on_model_input_window_observation:
              (Option.map
                 (fun observe observation ->
                    observe ~measurement:Turn_record.Durable_shape observation)
                 on_model_input_window_observation)
            ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ~on_official_client_result_handoff:
              (fun ~invocation ~content ->
                 Option.iter
                   (fun observe ->
                      observe ~runtime_id:attempt_runtime_id ~invocation ~content)
                   on_official_client_result_handoff)
            ~on_native_action:
              (fun ~official_turn ~identity ~tool_name ->
                 Option.iter
                   (fun observe -> observe ~runtime_id:attempt_runtime_id ~official_turn ~identity ~tool_name)
                   on_official_client_native_action)
            ~event_bus
            ~raw_trace
            ~on_event
            ~config
            ()
        in
        let run_antigravity_with_history () =
          run_antigravity ~initial_messages ()
        in
        let antigravity_attempt =
          match provider_config_transform, agent_core_checkpoint with
          | Some _, _ ->
            { Keeper_antigravity_runtime.result =
                Error
                  (Agent_core.Error.Config
                     (Agent_core.Error.InvalidConfig
                        { field = "provider_config_transform"
                        ; detail =
                            "provider config transforms cannot target an antigravity-cli runtime"
                        }))
            ; effect_disposition =
                Keeper_provider_attempt_effect.No_effect_observed
            }
          | None, Some _ ->
            Log.Keeper.info
              "%s: official-client runtime %s resolves start-or-resume from \
               its durable session store; the Agent Core checkpoint payload is not \
               replayed"
              keeper_name
              attempt_runtime_id;
            emit_runtime_manifest
              ~status:"checkpoint_not_replayed"
              ~decision:
                (`Assoc
                  [ ( "routing_action"
                    , `String "official_client_checkpoint_not_replayed" )
                  ; ( "routing_reason"
                    , `String "official_client_session_store_owns_resume" )
                  ])
              Keeper_runtime_manifest.Runtime_routed;
            run_antigravity_with_history ()
          | None, None -> run_antigravity_with_history ()
        in
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        let antigravity_result =
          Result.bind antigravity_attempt.result (fun run_result ->
            apply_official_client_accept
              ~runtime_id:attempt_runtime_id
              ~accept
              ~terminal_effect_state
              run_result)
        in
        (match antigravity_result with
         | Ok run_result ->
           Option.iter
             (fun observe ->
               Option.iter observe run_result.Runtime_agent.runtime_observation)
             on_runtime_observation
         | Error _ -> ());
        ( selected_runtime_result runtime ~lane_attempt_index:idx antigravity_result
        , None
        , antigravity_attempt.effect_disposition )
      | Runtime_execution.Claude_code config ->
        let run_claude ~initial_messages () =
          let tools = if runtime.model.tools_support then tools else [] in
          Keeper_claude_code_runtime.run
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection
            (* [Durable_shape] because that is what was measured: the official
               client assembles the wire itself, so masc can only report the
               list it handed over. The Agent Core path reports [Wire_shape]
               when its own serializer produced the bytes and falls back to
               this same shape when it could not. *)
            ?on_model_input_window_observation:
              (Option.map
                 (fun observe observation ->
                    observe ~measurement:Turn_record.Durable_shape observation)
                 on_model_input_window_observation)
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ~on_official_client_result_handoff:
              (fun ~invocation ~content ->
                 Option.iter
                   (fun observe ->
                      observe ~runtime_id:attempt_runtime_id ~invocation ~content)
                   on_official_client_result_handoff)
            ~on_native_action:
              (fun ~official_turn ~identity ~tool_name ->
                 Option.iter
                   (fun observe -> observe ~runtime_id:attempt_runtime_id ~official_turn ~identity ~tool_name)
                   on_official_client_native_action)
            ~event_bus
            ~raw_trace
            ~on_event
            ~config
            ()
        in
        let claude_attempt =
          match provider_config_transform, agent_core_checkpoint with
          | Some _, _ ->
            { Keeper_claude_code_runtime.result =
                Error
                  (Agent_core.Error.Config
                     (Agent_core.Error.InvalidConfig
                        { field = "provider_config_transform"
                        ; detail =
                            "provider config transforms cannot target a claude-code runtime"
                        }))
            ; effect_disposition =
                Keeper_provider_attempt_effect.No_effect_observed
            }
          | None, Some _ ->
            (* The durable official-client session store owns start-or-resume
               (Keeper_claude_code_runtime reads [previous_settlement]), so a
               present Agent Core checkpoint only means its payload is not
               replayed — it does not make the turn a fresh session. Same
               vocabulary as the codex-app-server arm (#27938, masc#27812). *)
            Log.Keeper.info
              "%s: official-client runtime %s resolves start-or-resume from \
               its durable session store; the Agent Core checkpoint payload is not \
               replayed"
              keeper_name
              attempt_runtime_id;
            emit_runtime_manifest
              ~status:"checkpoint_not_replayed"
              ~decision:
                (`Assoc
                  [ ( "routing_action"
                    , `String "official_client_checkpoint_not_replayed" )
                  ; ( "routing_reason"
                    , `String "official_client_session_store_owns_resume" )
                  ])
              Keeper_runtime_manifest.Runtime_routed;
            run_claude ~initial_messages ()
          | None, None -> run_claude ~initial_messages ()
        in
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        let claude_result =
          Result.bind claude_attempt.result (fun run_result ->
            apply_official_client_accept
              ~runtime_id:attempt_runtime_id
              ~accept
              ~terminal_effect_state
              run_result)
        in
        (match claude_result with
         | Ok run_result ->
           Option.iter
             (fun observe ->
               Option.iter observe run_result.Runtime_agent.runtime_observation)
             on_runtime_observation
         | Error _ -> ());
        ( selected_runtime_result runtime ~lane_attempt_index:idx claude_result
        , None
        , claude_attempt.effect_disposition )
      | Runtime_execution.Agent_core runtime_provider_config ->
       (match
          match provider_config_transform with
          | None -> Ok runtime_provider_config
          | Some transform -> transform runtime_provider_config
        with
      | Error err ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        Error err, None, Keeper_provider_attempt_effect.No_effect_observed
      | Ok provider_config ->
        (match
           validate_provider_request_cap
             ~runtime_id:attempt_runtime_id
             provider_config
         with
         | Error err ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
           Error err, None, Keeper_provider_attempt_effect.No_effect_observed
         | Ok max_request_body_bytes ->
          let candidate = Runtime_candidate.of_provider_config provider_config in
          (* Cached provider health is observation only. Every eligible runtime
             reaches the real provider boundary; only the resulting typed error
             may drive fallback. *)
          let name = Printf.sprintf "agent_core-%s" attempt_runtime_id in
          let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx =
            { runtime_id = attempt_runtime_id
            ; error_runtime_id
            ; max_request_body_bytes
            ; (* #27320: the first attempt's windowing budget starts at the
                 full declared cap; [run_try_provider_with_context_overflow_shrink]
                 is the one that consults #27320's remembered starting point
                 and shrinks it on a typed overflow. A direct (non-shrink)
                 caller of [run_try_provider] gets the un-shrunk cap, same as
                 before this change. *)
              model_input_capacity_bytes = max_request_body_bytes
            ; base_path
            ; keeper_name
            ; name
            ; goal
            ; goal_blocks
            ; session_id
            ; system_prompt
            ; tools
            ; deferred_tool_surface
            ; initial_messages
            ; model_input_projection
            ; stream_idle_timeout_s
            ; first_event_timeout_s =
                (* Keeper policy knob, injected from the resolved layer like
                   [provider_call_deadline_sec] below instead of threading
                   one more optional through run_named (RFC-AC-037). *)
                Keeper_runtime_resolved.first_event_timeout_sec ()
            ; body_timeout_s
            ; provider_call_deadline_sec =
                Keeper_runtime_resolved.provider_call_deadline_sec ()
            ; (* #28417: the deadline is measured against the keeper's live
                 progress signal, and this closure is the only thing that
                 reads it. Injected here rather than imported inside
                 [Keeper_turn_driver_try_provider] so the stall decision over
                 there stays pure and unit-testable.

                 Contract: never raises. A failed registry read yields [None],
                 which degrades the deadline to its pre-#28417 elapsed
                 ceiling instead of cancelling the attempt being watched. *)
              provider_progress_probe =
                Some
                  (fun () ->
                    try
                      match Keeper_registry.get ~base_path keeper_name with
                      | Some { current_turn_observation = Some obs; _ } ->
                        Some
                          { Keeper_turn_driver_try_provider.last_progress_at =
                              obs.last_progress_at
                          ; active_tool_count = obs.active_tool_count
                            (* Read here rather than carried on the turn
                               observation: the approval registry already owns
                               this fact, and a second copy on the observation
                               would be one more thing to keep in step with
                               it. Both reads happen in the same probe call,
                               so they describe the same instant. *)
                          ; awaiting_approval =
                              List.exists
                                (fun (p : Keeper_tool_approval_registry.pending) ->
                                   String.equal p.keeper_name keeper_name)
                                (Keeper_tool_approval_registry.pending
                                   (Keeper_tool_approval_registry.shared ()))
                          }
                      | Some _ | None -> None
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                      Log.Keeper.warn
                        "progress probe read failed for %s: %s (deadline \
                         falls back to elapsed)"
                        keeper_name
                        (Printexc.to_string exn);
                      None)
            ; temperature
            ; accept
            ; hooks
            ; approval_gate
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
            ; agent_core_checkpoint
            ; trace_link
            ; sw
            ; net
            ; on_event
            ; on_yield
            ; on_resume
            ; agent_ref
            ; on_runtime_observation
            ; on_request_wire_observation
            ; on_model_input_window_observation
            ; event_bus
            ; runtime_manifest_context
            ; runtime_manifest_append
            ; turn_start
            ; seq_ref
            }
          in
          Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
          let provider_result, checkpoint_after, _success_sample =
            Keeper_turn_driver_try_provider.run_try_provider_with_context_overflow_shrink
              try_provider_ctx candidate
          in
          let outcomes =
            project_provider_attempt_result
              ~replay_prefix_projection
              provider_result
          in
          ( selected_runtime_result runtime ~lane_attempt_index:idx outcomes.turn_result
          , checkpoint_after
          , Keeper_provider_attempt_effect.No_effect_observed )))
       )
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

  let selected_runtime_result = selected_runtime_result
  let apply_official_client_accept = apply_official_client_accept

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
