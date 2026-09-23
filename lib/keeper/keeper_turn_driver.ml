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

type output_contract = Provider_default | Tool_verdict


type provider_run_result =
  (Runtime_agent.run_result, Agent_core.Error.t) result

type provider_attempt_outcomes =
  { provider_result : provider_run_result
  ; turn_result : provider_run_result
  ; checkpoint_after : Agent_core.Checkpoint.t option
  }

type named_run_result =
  { run_result : Runtime_agent.run_result
  ; official_client_settlement : Keeper_official_client_session_store.t option
  ; selected_runtime_id : string
  ; selected_max_context : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  ; lane_attempt_index : int
  }

type runtime_attempt =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  }

type runtime_attempt_candidate =
  | Resolved_runtime of Runtime.t
  | Missing_runtime of string

let selected_runtime_result ?official_client_settlement (runtime : Runtime.t) ~lane_attempt_index result =
  Result.map
    (fun run_result ->
       { run_result
       ; official_client_settlement
       ; selected_runtime_id = runtime.id
       ; selected_max_context = Runtime.max_context_of_runtime runtime
       ; checkpoint_owner = Runtime_execution.checkpoint_owner runtime.execution
       ; lane_attempt_index
       })
    result
;;

(* Whether the candidate answered at all. An attempt that stopped before any
   provider turn completed did not, so it is no evidence the candidate is
   back. *)
let run_result_answered (run_result : Runtime_agent.run_result) =
  match run_result.Runtime_agent.stop_reason with
  | Runtime_agent.Completed -> true
  | Runtime_agent.Yielded_to_operation_queued { turns_used }
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used }
  | Runtime_agent.Yielded_after_repeated_tool_call { turns_used; tool_name = _; repeated_count = _ }
  | Runtime_agent.Yielded_after_repeated_assistant_text { turns_used; repeated_count = _ }
  | Runtime_agent.InputRequired { turns_used; request = _ } -> turns_used > 0
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

type failure_continuation =
  | Resume_operation_checkpoint of { operation_id : Keeper_operation_id.t }
  | Restart_cycle

type runtime_retry_deferral =
  { continuation : failure_continuation
  ; on_deferred : deferred_runtime_lane -> unit
  }

(* The candidate error a runtime walk returns as the lane's error, together
   with the candidate that produced it. The walk may return an error observed
   on an earlier candidate than the one it ended on (a typed context overflow
   outranks a later recoverable error on an exhausted lane), so the candidate
   the walk ended on and the candidate whose error it returned are two
   facts. *)
type lane_terminal_error =
  { origin_runtime_id : string
  ; origin_attempt : int
  ; lane_error : Agent_core.Error.t
  ; checkpoint_after : Agent_core.Checkpoint.t option
  }

(* Quota demotion must never promote a candidate the runtime table cannot
   resolve (for example one removed by a runtime.toml reload while a deferred
   suffix was frozen): a missing id at the head fails the attempt with a
   non-rotating error before resolvable alternatives are tried. Order is
   therefore resolvable-active, then resolvable-exhausted, then unresolvable —
   declared relative order preserved within each class (PR #28219 review). *)
type demotion =
  | Not_demoted
  | Failed_without_rest
  | Told_to_rest

(* Three places, declared order kept within each. A path told to rest -- an
   exhausted quota or a rate limit -- goes behind a path that only failed
   without answering: the failed one can be dispatched now, and behind a resting
   head it would make the next dispatch wait for that head's release
   (RFC-0458 §3.4). It is also what keeps a released rate limit promoting its
   path past the ones still resting, even while a failed attempt keeps it
   behind the ones that answered. *)
let demote_unavailable_candidates ~now ~quota_scope_of ~candidate_backpressure_of candidates =
  let demotion candidate =
    let quota_exhausted =
      Option.fold ~none:false
        ~some:(fun scope -> Runtime_quota_window.is_exhausted ~scope ~now)
        (quota_scope_of candidate)
    in
    let observed =
      Option.bind (candidate_backpressure_of candidate) (fun candidate ->
        Runtime_candidate_backpressure.candidate_backpressure ~now ~candidate)
    in
    match quota_exhausted, observed with
    | true, (Some _ | None)
    | false, Some { Runtime_candidate_backpressure.rate_limit = Some _; failed_attempt = _ } ->
      Told_to_rest
    | false, Some { Runtime_candidate_backpressure.rate_limit = None; failed_attempt = Some _ } ->
      Failed_without_rest
    | false, Some { Runtime_candidate_backpressure.rate_limit = None; failed_attempt = None }
    | false, None ->
      Not_demoted
  in
  let placed = List.map (fun candidate -> demotion candidate, candidate) candidates in
  let in_place wanted =
    List.filter_map
      (fun (demotion, candidate) ->
         match wanted, demotion with
         | Not_demoted, Not_demoted
         | Failed_without_rest, Failed_without_rest
         | Told_to_rest, Told_to_rest -> Some candidate
         | Not_demoted, (Failed_without_rest | Told_to_rest)
         | Failed_without_rest, (Not_demoted | Told_to_rest)
         | Told_to_rest, (Not_demoted | Failed_without_rest) -> None)
      placed
  in
  in_place Not_demoted @ in_place Failed_without_rest @ in_place Told_to_rest
;;

let quota_ordered_runtime_ids ~now runtime_ids =
  (* Resolve once so both kinds of ordering evidence use the same catalog row. *)
  let resolved = List.map (fun id -> id, Runtime.get_runtime_by_id id) runtime_ids in
  let resolvable, unresolvable = List.partition (fun (_, rt) -> Option.is_some rt) resolved in
  let ordered = demote_unavailable_candidates ~now
    ~quota_scope_of:(fun (_, rt) -> Option.map Runtime.quota_scope_of_runtime rt)
    ~candidate_backpressure_of:(fun (_, rt) ->
      Option.map (fun (rt : Runtime.t) -> rt.candidate_backpressure) rt)
    resolvable in
  List.map fst (ordered @ unresolvable)
;;

let quota_ordered_deferred_runtime_lane ~now hint =
  match quota_ordered_runtime_ids ~now (deferred_runtime_ids hint) with
  | next_runtime_id :: later_runtime_ids ->
    { hint with next_runtime_id; later_runtime_ids }
  | [] -> hint
;;

type path_rest =
  | Path_serving
  | Path_resting of
      { release_at : float
      ; walk_promotes_at_release : bool
      }

type walk_rest =
  | Walk_head_serving of { runtime_id : string }
  | Walk_waits_until of
      { release_at : float
      ; resting_runtime_id : string
      }

type next_dispatch =
  | Dispatch_now of { runtime_id : string }
  | Wait_until of
      { release_at : float
      ; waiting_on : string
      }

(* When one runtime path is released, read from the same two stores the walk
   order reads (RFC-provider-path-rest §3.3). The order holds a stated rest back
   until the provider's own time, so at that release the walk promotes the path
   again. It holds an unstated rest back until a success, so that release ends
   only the wait, not the demotion; a stated time beyond the cap is the same,
   because the cap ends the wait before the provider's time ends the demotion.
   A quota observation carries no noted time and rests from [now]. A failed
   attempt is not a rest: it demotes the path until the candidate answers and
   never makes a dispatch wait (RFC-0458 §3.4). An id the table cannot resolve
   is no evidence of a rest. *)
let path_rest ~now runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Path_serving
  | Some (runtime : Runtime.t) ->
    let cap_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
    let rest_sec retry_class retry_after_hint =
      Keeper_runtime_failure_route.path_rest_sec ~cap_sec ~retry_class ~retry_after_hint
    in
    let rate_limit_rest =
      match
        Runtime_candidate_backpressure.candidate_backpressure
          ~now
          ~candidate:runtime.candidate_backpressure
      with
      | None | Some { Runtime_candidate_backpressure.rate_limit = None; failed_attempt = _ } -> None
      | Some
          { Runtime_candidate_backpressure.rate_limit =
              Some (Runtime_candidate_backpressure.Unknown_scope_rate_limit { noted_at; retry_after })
          ; failed_attempt = _
          } ->
        let promotes =
          match retry_after with
          | Some seconds when (not (Float.is_nan seconds)) && seconds > 0.0 ->
            Float.compare seconds cap_sec <= 0
          | Some _ | None -> false
        in
        Some
          ( noted_at +. rest_sec Keeper_runtime_failure_route.Rate_limited retry_after
          , promotes )
    in
    let quota_rest =
      let scope = Runtime.quota_scope_of_runtime runtime in
      match Runtime_quota_window.active_until ~scope ~now with
      | Some resets_at ->
        let cap_at = now +. cap_sec in
        Some (Float.min resets_at cap_at, Float.compare resets_at cap_at <= 0)
      | None ->
        if Runtime_quota_window.is_exhausted ~scope ~now
        then Some (now +. rest_sec Keeper_runtime_failure_route.Hard_quota None, false)
        else None
    in
    let rest =
      match rate_limit_rest, quota_rest with
      | None, None -> None
      | Some rest, None | None, Some rest -> Some rest
      | Some (rate_limit_at, rate_limit_promotes), Some (quota_at, quota_promotes) ->
        Some (Float.max rate_limit_at quota_at, rate_limit_promotes && quota_promotes)
    in
    (match rest with
     | Some (release_at, walk_promotes_at_release) when Float.compare now release_at < 0 ->
       Path_resting { release_at; walk_promotes_at_release }
     | Some _ | None -> Path_serving)
;;

(* A walk dispatches its head first, so the head decides: a serving head takes
   the input now. A resting head waits for the first moment the walk's head can
   serve: the head's own release, or an earlier release of a later path that
   the walk order promotes at that moment. A later path whose release the order
   does not follow stays behind the head and cannot shorten the wait. *)
let walk_rest ~now ~head ~later =
  match path_rest ~now head with
  | Path_serving -> Walk_head_serving { runtime_id = head }
  | Path_resting { release_at = head_release_at; walk_promotes_at_release = _ } ->
    let release_at, resting_runtime_id =
      List.fold_left
        (fun ((earliest, _) as found) runtime_id ->
           match path_rest ~now runtime_id with
           | Path_resting { release_at; walk_promotes_at_release = true }
             when Float.compare release_at earliest < 0 ->
             release_at, runtime_id
           | Path_resting { release_at = _; walk_promotes_at_release = _ } | Path_serving ->
             found)
        (head_release_at, head)
        later
    in
    Walk_waits_until { release_at; resting_runtime_id }
;;

(* The deferred suffix in the order the next turn walks it
   ([quota_ordered_deferred_runtime_lane]). *)
let deferred_lane_rest ~now hint =
  let ordered = quota_ordered_deferred_runtime_lane ~now hint in
  walk_rest ~now ~head:ordered.next_runtime_id ~later:ordered.later_runtime_ids
;;

(* A fresh walk of an assignment, ordered as [run_named] orders a turn without
   a deferred suffix: the lane as declared, then quota and backpressure
   demotion. *)
type walk_order =
  { lane_id : string
  ; declared : string list
  ; order : string list
  }

type assignment_refusal =
  | Assignment_missing
  | Catalog_unavailable of Runtime.missing_catalog_model

let assignment_refusal_to_string = function
  | Assignment_missing -> "the assignment names no configured lane or runtime"
  | Catalog_unavailable missing ->
    "capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing
;;

let assignment_walk_order ~now assignment_id =
  match Runtime.resolve_assignment assignment_id with
  | `Lane lane ->
    let lane_id = Runtime_lane.id lane in
    let declared = Runtime_lane.ordered_candidates lane in
    Ok { lane_id; declared; order = quota_ordered_runtime_ids ~now declared }
  | `Unavailable missing -> Error (Catalog_unavailable missing)
  | `Missing -> Error Assignment_missing
;;

(* An assignment the walk would refuse still names a path whose rest the
   failure wait reads; it rests as its own single candidate. *)
let assignment_walk_rest ~now assignment_id =
  match assignment_walk_order ~now assignment_id with
  | Ok { order = head :: later; _ } -> walk_rest ~now ~head ~later
  | Ok { order = []; _ } | Error (Assignment_missing | Catalog_unavailable _) ->
    Walk_head_serving { runtime_id = assignment_id }
;;

(* The next dispatch after a failed turn, shared by the heartbeat cycle and
   the chat lane's deferred retry so both answer one failure the same way
   (RFC-provider-path-rest §3.1).

   A deferred suffix names where the input goes next, and its walk decides.
   Without a suffix the turn used every path the input may take: a rate limit
   or quota waits for the failed path's rest, and no less than the moment a
   fresh walk of the assignment can start on a serving path, so the wait never
   ends on a head that still rests. Every other failure without a suffix has
   no provider wait. *)
let next_dispatch_after_failure ~now ~route ~assignment_id deferred =
  let module Route = Keeper_runtime_failure_route in
  let cap_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
  let route_release retry_class retry_after =
    now +. Route.path_rest_sec ~cap_sec ~retry_class ~retry_after_hint:retry_after
  in
  match route, deferred with
  | ( ( Route.Retry_after_observed
          { retry_class =
              ( Route.Rate_limited | Route.Hard_quota | Route.Provider_capacity
              | Route.Server_error | Route.Empty_completion _
              | Route.Network_transient | Route.Provider_timeout )
          ; _
          }
      | Route.Rotate_now _ | Route.Exhausted_visible_alive _ )
    , Some hint ) ->
    Some
      (match deferred_lane_rest ~now hint with
       | Walk_head_serving { runtime_id } -> Dispatch_now { runtime_id }
       | Walk_waits_until { release_at; resting_runtime_id } ->
         Wait_until { release_at; waiting_on = resting_runtime_id })
  | ( Route.Retry_after_observed
        { retry_class = (Route.Rate_limited | Route.Hard_quota) as retry_class; retry_after }
    , None ) ->
    let failed_release_at = route_release retry_class retry_after in
    let release_at, waiting_on =
      match assignment_walk_rest ~now assignment_id with
      | Walk_waits_until { release_at; resting_runtime_id }
        when Float.compare release_at failed_release_at > 0 ->
        release_at, resting_runtime_id
      | Walk_waits_until { release_at = _; resting_runtime_id = _ } | Walk_head_serving _ ->
        failed_release_at, assignment_id
    in
    Some (Wait_until { release_at; waiting_on })
  | ( ( Route.Retry_after_observed
          { retry_class =
              Route.Provider_capacity | Route.Empty_completion _ | Route.Server_error
              | Route.Network_transient | Route.Provider_timeout
          ; _
          }
      | Route.Rotate_now _ | Route.Exhausted_visible_alive _ )
    , None ) ->
    None
;;

let equal_deferred_runtime_lane left right =
  String.equal left.assignment_id right.assignment_id
  && String.equal left.failed_runtime_id right.failed_runtime_id
  && String.equal left.next_runtime_id right.next_runtime_id
  && left.later_runtime_ids = right.later_runtime_ids

let restore_deferred_runtime_lane ~assignment_id ~failed_runtime_id
      ~next_runtime_id ~later_runtime_ids ~failure =
  { assignment_id
  ; failed_runtime_id
  ; next_runtime_id
  ; later_runtime_ids
  ; failure
  }
;;

let canonical_checkpoint_sink ~replay_prefix_projection sink
    (snapshot : Agent_core.Agent.checkpoint_snapshot) =
  match Keeper_replay_prefix.restore_checkpoint replay_prefix_projection snapshot.checkpoint with
  | Error error -> Error (Keeper_replay_prefix.restore_error_to_string error)
  | Ok checkpoint -> sink { snapshot with checkpoint }
;;

let project_provider_attempt_result ?checkpoint_after ~replay_prefix_projection provider_result =
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
  let turn_result, checkpoint_after = match checkpoint_after with
    | None -> turn_result, None
    | Some checkpoint ->
      (match Keeper_replay_prefix.restore_checkpoint replay_prefix_projection checkpoint with
       | Ok checkpoint -> turn_result, Some checkpoint
       | Error error -> Error (Agent_core.Error.Internal
           (Keeper_replay_prefix.restore_error_to_string error)), None) in
  { provider_result; turn_result; checkpoint_after }
;;

let runtime_attempt_decision ~idx ~runtime_id =
  `Assoc [ ("idx", `Int idx); ("runtime_id", `String runtime_id) ]

let runtime_failed_decision ~idx ~runtime_id error =
  `Assoc
    [
      ("idx", `Int idx);
      ("runtime_id", `String runtime_id);
      ("attempt_total_usage", `Null);
      ("attempt_usage_status", `String "unresolved");
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
  else if Keeper_required_tools.should_try_next error then
    true
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
  else if Keeper_recovery_transmission.should_try_next error then true
  else if Keeper_turn_driver_try_runtime.candidate_access_should_try_next error
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
    ?retry_deferral
    ?(tool_results_saved = fun () -> false)
    ?(on_attempt_error = fun ~runtime_id:_ ~attempt:_ ~dispatch:_ _error -> ())
    ?(on_lane_terminal_error = fun (_ : lane_terminal_error) -> ())
    ?(provider_answered = fun _ -> true)
    ?quota_scope_of
    ?model_of
    ?candidate_backpressure_of
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
  let candidate_backpressure_of =
    match candidate_backpressure_of with
    | Some candidate_backpressure_of -> candidate_backpressure_of
    | None -> fun candidate ->
        Runtime.get_runtime_by_id (runtime_id_of candidate)
        |> Option.map (fun (runtime : Runtime.t) -> runtime.candidate_backpressure)
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
  (* The model behind a candidate, for the one failure that belongs to the
     model rather than to its provider: a generation that repeated itself.
     The same model reached through another provider repeats the same way,
     so once a candidate has repeated, every later candidate on that model is
     refused before dispatch and the walk moves to a different model.

     The identity is the name the provider serves ([model.api_name]), not the
     runtime.toml model id: operators declare one [models.*] row per provider
     for the same model, each under its own id, so ids never meet across
     providers and a skip keyed on them would fire nowhere. A provider that
     serves the same model under a prefixed name is not recognised as the
     same model by this rule; that gap is named (RFC-0419 §9), not guessed
     at. The id-table default reads the registry; richer callers inject it. *)
  let model_of =
    match model_of with
    | Some model_of -> model_of
    | None ->
      fun candidate ->
        Runtime.get_runtime_by_id (runtime_id_of candidate)
        |> Option.map (fun (runtime : Runtime.t) -> runtime.model.api_name)
  in
  (* The refusal a candidate earns from the models that repeated so far: its
     served name and the terminal record that observed the repeat. One pure
     lookup, read once per candidate. *)
  let refusal_for ~(repeated_models : (string * lane_terminal_error) list) candidate =
    match model_of candidate with
    | None -> None
    | Some model ->
      Option.map (fun observed -> model, observed) (List.assoc_opt model repeated_models)
  in
  let repeated_generation (error : Agent_core.Error.t) =
    match error with
    | Agent_core.Error.Provider (Llm_provider.Error.RepeatingGeneration _) -> true
    | Agent_core.Error.Provider _
    | Agent_core.Error.Api _
    | Agent_core.Error.Agent _
    | Agent_core.Error.Mcp _
    | Agent_core.Error.Config _
    | Agent_core.Error.Serialization _
    | Agent_core.Error.Io _
    | Agent_core.Error.Orchestration _
    | Agent_core.Error.Internal _
    | Agent_core.Error.Internal_carried _ -> false
  in
  let demote_rest rest =
    let dispatchable, undispatchable =
      List.partition candidate_dispatchable rest
    in
    demote_unavailable_candidates
      ~now:(Unix.gettimeofday ())
      ~quota_scope_of ~candidate_backpressure_of
      dispatchable
    @ undispatchable
  in
  (* Every error the walk returns from a candidate passes through here, so
     the caller learns which candidate produced the lane's error. *)
  let lane_terminal (terminal : lane_terminal_error) =
    on_lane_terminal_error terminal;
    Error terminal.lane_error
  in
  let rec loop
      ~(observed_overflow : lane_terminal_error option)
      ~(repeated_models : (string * lane_terminal_error) list)
      idx
    = function
    | [] ->
      (match observed_overflow with
       | Some overflow -> lane_terminal overflow
       | None ->
         Error
           (Agent_core.Error.Internal
              (Printf.sprintf
                 "runtime lane %S exhausted all candidates"
                 runtime_id)))
    | candidate :: rest ->
      (match refusal_for ~repeated_models candidate with
       | Some refusal -> refuse ~observed_overflow ~repeated_models idx candidate rest refusal
       | None -> attempt ~observed_overflow ~repeated_models idx candidate rest)
  (* The candidate's model already repeated itself earlier in the walk.
     Refusing it is the walk's own policy, so it is recorded as a rejection
     before dispatch, like the reasoning-effort ladder's. If it was the last
     candidate, the lane's error is what the walk observed: an overflow seen
     anywhere in the rotation still outranks it, then the repeat itself,
     never this refusal. *)
  and refuse ~observed_overflow ~repeated_models idx candidate rest
      (model, (observed : lane_terminal_error)) =
    let attempt_runtime_id = runtime_id_of candidate in
    let error =
      Agent_core.Error.Api
        (Llm_provider.Retry.InvalidRequest
           { reason = Llm_provider.Retry.Attempt_rejected
           ; message =
               Printf.sprintf
                 "candidate %s refused before dispatch: model %s repeated itself on %s \
                  in this walk"
                 attempt_runtime_id
                 model
                 observed.origin_runtime_id
           })
    in
    emit_runtime_manifest
      ~status:"attempt"
      ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
      Keeper_runtime_manifest.Runtime_routed;
    emit_runtime_manifest
      ~status:"failed"
      ~decision:(runtime_failed_decision ~idx ~runtime_id:attempt_runtime_id error)
      Keeper_runtime_manifest.Runtime_failed;
    on_attempt_error
      ~runtime_id:attempt_runtime_id
      ~attempt:idx
      ~dispatch:Keeper_attempt_dispatch.Rejected_before_dispatch
      error;
    if rest = []
    then (
      match observed_overflow with
      | Some overflow -> lane_terminal overflow
      | None -> lane_terminal observed)
    else loop ~observed_overflow ~repeated_models (idx + 1) rest
  and attempt ~observed_overflow ~repeated_models idx candidate rest =
    let is_last = rest = [] in
    let attempt_runtime_id = runtime_id_of candidate in
    (* Bind quota ownership to the exact candidate that will be dispatched.
       [run_attempt] may span a runtime.toml reload; resolving the id after
       the provider returns could then attribute the old credential's
       response to the replacement catalog row. *)
    let attempt_quota_scope = quota_scope_of candidate in
    let attempt_candidate_backpressure = candidate_backpressure_of candidate in
    let clear_answered_candidate_evidence () =
      Option.iter
        (fun candidate ->
           Runtime_candidate_backpressure.note_candidate_success ~candidate)
        attempt_candidate_backpressure;
      (* A call getting through is the only evidence a quota came back that
         a provider stating no reset time leaves available, so it is what
         clears the observation. A stated window is left alone: it names a
         time, and one answer inside it does not make that untrue. *)
      match attempt_quota_scope with
      | Some scope -> Runtime_quota_window.note_succeeded ~scope
      | None -> ()
    in
    emit_runtime_manifest
      ~status:"attempt"
      ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
      Keeper_runtime_manifest.Runtime_routed;
    (match
       run_attempt ~idx ~runtime_id:attempt_runtime_id candidate
     with
     | Ok value, _checkpoint_after, _effect_disposition, _dispatch ->
       emit_runtime_manifest
         ~status:"completed"
         ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
         Keeper_runtime_manifest.Runtime_completed;
       (* An attempt that ended before the candidate answered -- a yield to a
          queued person before the first token -- says nothing about the
          candidate, so it clears no evidence (RFC-0458 §3.4). *)
       if provider_answered value
       then clear_answered_candidate_evidence ();
       Ok value
     | Error error, checkpoint_after, effect_disposition, dispatch ->
       emit_runtime_manifest
         ~status:"failed"
         ~decision:(runtime_failed_decision ~idx ~runtime_id:attempt_runtime_id error)
         Keeper_runtime_manifest.Runtime_failed;
       on_attempt_error
         ~runtime_id:attempt_runtime_id
         ~attempt:idx
         ~dispatch
         error;
       (* HTTP 429 and coarse Provider.RateLimit do not identify the
          exhausted resource. Keep that unknown scope and the optional
          provider hint as candidate-only ordering evidence. A shared
          credential quota requires the distinct HardQuota/402 contract. *)
       let note_quota retry_after =
         (* A hint the provider did not really state -- zero, negative, NaN --
            named no reset. Planting it as a window would date the quota to a
            moment already past, and that window replaces an observation the
            scope already carried ([Runtime_quota_window]), leaving the scope
            looking available. The rule for reading a hint is the one
            [path_rest_sec] and [route_resumes_on_same_path] read. *)
         match attempt_quota_scope, Keeper_runtime_failure_route.usable_retry_after retry_after with
         | None, _ -> ()
         | Some scope, Some retry_after_s ->
           Runtime_quota_window.note_exhausted
             ~scope
             (* NDT-OK: convert the provider's relative reset at ingress. *)
             ~resets_at:(Unix.gettimeofday () +. retry_after_s)
         | Some scope, None ->
           Runtime_quota_window.note_observed_exhausted ~scope
       in
       let note_rate_limit retry_after =
         Option.iter
           (fun candidate -> Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after)
           attempt_candidate_backpressure
       in
       (* The route calls every timeout a provider timeout, including one that
          expired in MASC's own admission -- a permit queue or local capacity
          -- before anything was sent. That says nothing about the candidate.
          The typed phase is read here because the route does not carry it. *)
       let expired_in_admission =
         let admission = function
           | Some (Llm_provider.Http_client.Queue | Llm_provider.Http_client.Capacity_backpressure) ->
             true
           | Some
               ( Llm_provider.Http_client.First_token | Llm_provider.Http_client.Wall_clock
               | Llm_provider.Http_client.Http_operation
               | Llm_provider.Http_client.Non_streaming_body
               | Llm_provider.Http_client.Stream_body | Llm_provider.Http_client.Stream_idle _
               | Llm_provider.Http_client.Provider_step
               | Llm_provider.Http_client.Cli_stdout_idle
               | Llm_provider.Http_client.Unknown_timeout )
           | None -> false
         in
         match error with
         | Agent_core.Error.Api (Llm_provider.Retry.Timeout { phase; message = _ }) -> admission phase
         | Agent_core.Error.Provider
             (Llm_provider.Error.Timeout { timeout_phase; provider = _; detail = _ }) ->
           admission timeout_phase
         | Agent_core.Error.Api _ | Agent_core.Error.Provider _ | Agent_core.Error.Agent _
         | Agent_core.Error.Mcp _ | Agent_core.Error.Config _
         | Agent_core.Error.Serialization _ | Agent_core.Error.Io _
         | Agent_core.Error.Orchestration _ | Agent_core.Error.Internal _
         | Agent_core.Error.Internal_carried _ -> false
       in
       let note_failed_attempt failure =
         Option.iter
           (fun candidate -> Runtime_candidate_backpressure.note_failed_attempt ~candidate ~failure)
           attempt_candidate_backpressure
       in
       (* The evidence follows the failure route, the one classification of
          this error that the keeper's failure handling reads, rather than a
          second reading of the error. That second reading recorded 429, 402
          and HardQuota and dropped everything else, including a closed runtime
          connection the route calls a server error (RFC-0458 §3.4). *)
       let route =
         Keeper_runtime_failure_route.route_of_error
           ~boundary:Keeper_runtime_failure_route.Agent_core_execution
           error
       in
       (match route with
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Rate_limited; retry_after } ->
          note_rate_limit retry_after
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Hard_quota; retry_after } ->
          note_quota retry_after
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Server_error; retry_after = _ } ->
          note_failed_attempt Runtime_candidate_backpressure.Server_error
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Empty_completion _
            ; retry_after = _
            } ->
          (* The provider answered. It disproves an earlier "failed without
             answering" observation and an undated quota, even though this
             turn still fails for having no usable completion. *)
          clear_answered_candidate_evidence ()
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Network_transient; retry_after = _ } ->
          note_failed_attempt Runtime_candidate_backpressure.Network_transient
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Provider_timeout; retry_after = _ } ->
          if not expired_in_admission
          then note_failed_attempt Runtime_candidate_backpressure.Provider_timeout
        (* A 529 or a provider capacity pool refused this candidate without
           an answer. The next candidate is a different pool. *)
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Provider_capacity; retry_after = _ } ->
          note_failed_attempt Runtime_candidate_backpressure.Provider_capacity
        (* These candidates answered, or the failure says nothing durable
           about their ability to answer a later turn (RFC-0458 §3.4, §6).
           A credential denial rotates to the next candidate within this
           turn only. Held as evidence it would stay until the head itself
           answered, which it never gets to do while a sibling answers, so
           every new turn starts again from the head. *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate =
                ( Keeper_runtime_failure_route.Auth_failed
                | Keeper_runtime_failure_route.Model_unavailable
                | Keeper_runtime_failure_route.Resumable_cli_session
                | Keeper_runtime_failure_route.Candidates_filtered
                | Keeper_runtime_failure_route.Runtime_exhausted
                | Keeper_runtime_failure_route.No_progress_empty
                | Keeper_runtime_failure_route.No_progress_thinking_only
                | Keeper_runtime_failure_route.No_progress_truncated
                | Keeper_runtime_failure_route.Refusal_body_not_received
                | Keeper_runtime_failure_route.Generation_repeated
                | Keeper_runtime_failure_route.Attempt_rejected
                | Keeper_runtime_failure_route.Provider_reported_failure
                | Keeper_runtime_failure_route.Request_refused
                | Keeper_runtime_failure_route.Provider_wire_defect )
            } ->
          ()
        (* A 5xx the provider called permanent failed this candidate without
           an answer, the same fact a transient 5xx records. *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate = Keeper_runtime_failure_route.Server_error_not_transient } ->
          note_failed_attempt Runtime_candidate_backpressure.Server_error
        (* The turn's input or MASC itself failed; another candidate would not
           do better, so this is no evidence about this one. *)
        | Keeper_runtime_failure_route.Exhausted_visible_alive _ -> ());
       (* Stable demotion retains every declared candidate, including when
          all are observed unavailable. Neither hint causes a wait or gate. *)
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
           (* RFC-0454 D1: the fenced attempt's cause is the value that failed
              it. A MASC error arrives on the carrier and is kept whole;
              anything else is agent-core's typed projection. Rendering the
              error here put its own prefixed JSON inside this envelope's
              JSON, one layer of escaping per wrap. *)
           let cause =
             match classify_masc_internal_error error with
             | Some masc -> Fenced_masc masc
             | None ->
               Fenced_core (Keeper_request_failure_core.of_core_error error)
           in
           (match !pre_tool_rejects with
            | [] ->
              core_error_of_masc_internal_error
                (Provider_attempt_effect_fenced
                   { runtime_id = attempt_runtime_id
                   ; effect_disposition
                   ; cause
                   })
            | rejects ->
              core_error_of_masc_internal_error
                (Tool_correction_lost
                   { runtime_id = attempt_runtime_id
                   ; effect_disposition
                   ; reject_count = List.length rejects
                   ; cause
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
           then
             Some
               { origin_runtime_id = attempt_runtime_id
               ; origin_attempt = idx
               ; lane_error = error
               ; checkpoint_after
               }
           else None
       in
       let this_candidate lane_error =
         { origin_runtime_id = attempt_runtime_id
         ; origin_attempt = idx
         ; lane_error
         ; checkpoint_after
         }
       in
       let repeated_models =
         match repeated_generation error, model_of candidate with
         | true, Some model -> (model, this_candidate error) :: repeated_models
         | true, None | false, _ -> repeated_models
       in
       if not effect_retry_admitted
       then lane_terminal (this_candidate terminal_error)
       else if retry_admitted && error_is_retryable
       then loop ~observed_overflow ~repeated_models (idx + 1) rest
       else if Keeper_internal_error.is_preempted_before_first_token error
       then
         (* A person queued behind this turn (#38094). An overflow an earlier
            candidate saw must not replace it: the turn yields, it does not
            fail for capacity. *)
         lane_terminal (this_candidate error)
       else if is_last
       then (
         (* Lane fully exhausted: an overflow seen anywhere in the rotation
            outranks the last candidate's error so the failure route and
            blocker report the deterministic capacity bound. Cascade
            telemetry already published each candidate's own error. *)
         match observed_overflow with
         | Some overflow -> lane_terminal overflow
         | None ->
           (* RFC last-path-resumes-after-progress §3.1: a chat operation whose
              last candidate saved tool results before a failure that passes
              with time continues on that candidate from its latest
              checkpoint. Each such resume needs tool results saved after the
              previous one, so resumes cannot outnumber the tool rounds the
              operation ran. A cycle-restarting lane starts a new turn that
              regains progress with its first tool, so it never resumes here. *)
           (match retry_deferral with
            | Some
                { continuation = Resume_operation_checkpoint { operation_id }
                ; on_deferred
                }
              when tool_results_saved ()
                   && Keeper_runtime_failure_route.route_resumes_on_same_path route ->
              Log.Keeper.info
                "deferred operation %s to the path it failed on \
                 (runtime_id=%s assignment=%s route=%s:%s)"
                (Keeper_operation_id.to_string operation_id)
                attempt_runtime_id
                runtime_id
                (Keeper_runtime_failure_route.route_kind_label route)
                (Keeper_runtime_failure_route.route_class_label route);
              (* The row a reader counts this decision by. Only a lane that
                 named an operation reaches it, so a lane that must not resume
                 is the lane whose walks never carry this status. *)
              emit_runtime_manifest
                ~status:"deferred_same_path"
                ~decision:
                  (`Assoc
                    [ "idx", `Int idx
                    ; "runtime_id", `String attempt_runtime_id
                    ; "operation_id", `String (Keeper_operation_id.to_string operation_id)
                    ; ( "route"
                      , `String
                          (Keeper_runtime_failure_route.route_kind_label route
                           ^ ":"
                           ^ Keeper_runtime_failure_route.route_class_label route) )
                    ])
                Keeper_runtime_manifest.Runtime_routed;
              on_deferred
                { assignment_id = runtime_id
                ; failed_runtime_id = attempt_runtime_id
                ; next_runtime_id = attempt_runtime_id
                ; later_runtime_ids = []
                ; failure = error
                }
            | Some
                { continuation = Resume_operation_checkpoint _ | Restart_cycle
                ; on_deferred = _
                }
            | None -> ());
           lane_terminal (this_candidate error))
       else (
         (* The next cycle starts from this hint with an empty memory of
            repeats, so a candidate whose model repeated in this walk must
            not be named in it: the hint is the only thing that carries the
            refusal across the cycle boundary. *)
         let rest_for_next_cycle =
           List.filter
             (fun candidate -> Option.is_none (refusal_for ~repeated_models candidate))
             rest
         in
         (match error_is_retryable, effect_retry_admitted, rest_for_next_cycle with
          | true, true, next :: later ->
            Option.iter
              (fun { continuation = _; on_deferred } ->
                 on_deferred
                   { assignment_id = runtime_id
                   ; failed_runtime_id = attempt_runtime_id
                   ; next_runtime_id = runtime_id_of next
                   ; later_runtime_ids = List.map runtime_id_of later
                   ; failure = error
                   })
              retry_deferral
          | false, _, _ | true, false, _ | true, true, [] -> ());
         lane_terminal (this_candidate terminal_error)))
  in
  loop ~observed_overflow:None ~repeated_models:[] 0 candidates

let runtime_candidate_missing_error id =
  Agent_core.Error.Internal
    (Printf.sprintf
       "keeper_turn_driver: lane candidate %S disappeared from runtimes"
       id)

let resolve_runtime_candidate id =
  match Runtime.get_runtime_by_id id with
  | Some runtime -> Ok runtime
  | None ->
    (match Runtime.resolve_assignment id with
     | `Unavailable missing ->
       Error (Runtime_agent_core_runner.runtime_catalog_error_to_core_error
         ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing))
     | `Missing | `Lane _ -> Error (runtime_candidate_missing_error id))

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

(* A live lane reroutes an image turn over its own candidates only. The lane is
   the whole list of runtimes this keeper may call; [runtime.media_failover] is
   the vision tool's fleet and never a turn's dispatch target. When no lane
   candidate takes the image, the decision is [No_capable_runtime] and the
   per-attempt projection turns the image into a reading for the runtime that
   runs the turn. The set is held in the same quota and backpressure order the
   lane itself uses ([demote_unavailable_candidates]): a candidate whose
   account answered a hard quota rejection earlier moves behind the live ones,
   so the reroute picks a live candidate instead of the first declared one. A
   deferred lane offers no candidates: its walk dispatches the frozen suffix
   ([lane_candidate_ids] in [run_agent_turn]), so a decision that moved the
   head would be recorded as a reroute the walk never performs. *)
let modality_reroute_candidates ~now ~deferred_runtime_lane ~first_candidate
    ~remaining_runtimes =
  match deferred_runtime_lane with
  | Some _ -> []
  | None ->
    dedupe_runtimes_preserve_order (first_candidate :: remaining_runtimes)
    |> demote_unavailable_candidates
         ~now
         ~quota_scope_of:(fun (runtime : Runtime.t) ->
           Some (Runtime.quota_scope_of_runtime runtime))
         ~candidate_backpressure_of:(fun (runtime : Runtime.t) ->
           Some runtime.Runtime.candidate_backpressure)

(* The media walk (every lane candidate that takes the media, live ones first),
   then the rest of the lane in its declared order as the degrade tail, where
   per-attempt projection turns the image into a reading. A text turn has an
   empty media walk and walks the lane as declared.

   The walk leads, not the lane head. When the head takes the media itself,
   [decide_modality_reroute_for_runtime_candidates] answers [No_reroute_needed]
   on capability alone and never looks at the account, so a head exhausted by a
   402/429 would stay in front of a live capable candidate. A reroute target is
   the walk's head for the same reason. *)
let attempt_runtimes_for_turn ~media_walk ~lane =
  dedupe_runtimes_preserve_order (media_walk @ lane)

let lane_modality_reroute_decision ~checkpoint_messages ~initial_messages
    ~goal_blocks ~first_candidate ~candidates =
  Runtime_agent.decide_modality_reroute_for_runtime_candidates
    ~assigned:first_candidate
    ~candidates
    ~checkpoint_messages
    ~initial_messages
    goal_blocks

(* The WARN names the lane head the image turn does not start from and the lane
   candidate it starts from, then the assignment. *)
let log_modality_reroute ~keeper_name ~assignment_id ~first_candidate_id = function
  | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ -> ()
  | Runtime_agent.Reroute { target; reason } ->
    Log.Keeper.warn
      "%s: RFC-0265 modality reroute %s -> %s (assignment %s: %s)"
      keeper_name
      first_candidate_id
      target.Runtime.id
      assignment_id
      reason

(* The dispatch view of one candidate's input. RFC-0265 media degrade projects
   the goal, the pre-turn history and the resumed checkpoint against the input
   capabilities of the runtime being dispatched; the caller's canonical history
   is never rewritten, and [attempt_replay_prefix_projection] is what restores
   a checkpoint taken on the projected prefix back onto it. *)
type attempt_input =
  { attempt_goal_blocks : Agent_core.Types.content_block list option
  ; attempt_initial_messages : Agent_core.Types.message list
  ; attempt_agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; attempt_replay_prefix_projection : Keeper_replay_prefix.projection
  }

(* Project against the candidate being dispatched, preserving the canonical
   input for subsequent candidates. Inline images that this candidate cannot
   see are delegated through the turn-scoped projector before the generic
   media strip. A failed vision head must not make a text fallback forget the
   picture. Other unsupported media retain the explicit degrade contract. *)
let project_input_for_attempt
    ~project_images
    ~keeper_name
    ~(emit_runtime_manifest :
       ?status:string ->
       ?decision:Yojson.Safe.t ->
       Keeper_runtime_manifest.event_kind ->
       unit)
    ~goal_blocks
    ~initial_messages
    ~agent_core_checkpoint
    ~runtime_id
    (runtime : Runtime.t) =
  let current_goal_blocks =
    match goal_blocks with
    | Some blocks -> blocks
    | None -> []
  in
  let checkpoint_messages =
    match agent_core_checkpoint with
    | None -> []
    | Some (checkpoint : Agent_core.Checkpoint.t) -> checkpoint.messages
  in
  let unchanged =
    { attempt_goal_blocks = goal_blocks
    ; attempt_initial_messages = initial_messages
    ; attempt_agent_core_checkpoint = agent_core_checkpoint
    ; attempt_replay_prefix_projection = Keeper_replay_prefix.unchanged
    }
  in
  match
    Runtime_agent.decide_modality_reroute_for_runtime_candidates
      ~assigned:runtime
      ~candidates:[]
      ~checkpoint_messages
      ~initial_messages
      current_goal_blocks
  with
  | Runtime_agent.No_reroute_needed | Runtime_agent.Reroute _ -> unchanged
  | Runtime_agent.No_capable_runtime { required } ->
    let caps = Runtime_agent.input_capabilities_of_runtime runtime in
    let project ~mode blocks =
      if caps.supports_image_input
      then { Keeper_vision_ingest.blocks; delegated_images = 0 }
      else project_images ~mode blocks
    in
    let projected_goal = project ~mode:Keeper_vision_ingest.Eager current_goal_blocks in
    let project_messages messages =
      let projected =
        List.map
          (fun (message : Agent_core.Types.message) ->
            let projection =
              project ~mode:Keeper_vision_ingest.Store_only message.content
            in
            { message with content = projection.blocks }, projection.delegated_images)
          messages
      in
      List.map fst projected,
      List.fold_left (fun count (_, images) -> count + images) 0 projected
    in
    let projected_initial, initial_images = project_messages initial_messages in
    let projected_checkpoint, checkpoint_images =
      match agent_core_checkpoint with
      | None -> None, 0
      | Some (checkpoint : Agent_core.Checkpoint.t) ->
        let messages, count = project_messages checkpoint.messages in
        Some { checkpoint with messages }, count
    in
    let delegated_images =
      projected_goal.delegated_images + initial_images + checkpoint_images
    in
    if delegated_images > 0 then (
      Log.Keeper.info
        "%s: image fallback on %s -- projected %d image occurrences to readings or references"
        keeper_name runtime_id delegated_images;
      emit_runtime_manifest
        ~status:"delegated"
        ~decision:
          (Keeper_runtime_manifest.with_payload_role
             ~payload_role:Keeper_runtime_manifest.Operator_evidence
             (`Assoc
               [ "routing_action", `String "images_delegated_for_candidate"
               ; "runtime_id", `String runtime_id
               ; "image_occurrences", `Int delegated_images
               ]))
        Keeper_runtime_manifest.Runtime_routed);
    let stripped_goal, goal_dropped =
      Runtime_agent.strip_unsupported_modality_blocks caps projected_goal.blocks
    in
    let stripped_initial, initial_dropped =
      Runtime_agent.strip_unsupported_modality_messages caps projected_initial
    in
    let stripped_checkpoint, checkpoint_dropped =
      match projected_checkpoint with
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
    (match Runtime_agent.media_degrade_note ~runtime_id dropped with
     | None when delegated_images = 0 ->
       (* [required] is non-empty -- that is why the decision was
          [No_capable_runtime] -- yet nothing was strippable, so there is no
          text-only turn to offer and the provider capability floor will reject
          this attempt. Say so here. Falling through in silence is what left the
          operator with a bare provider capability error and no record that
          RFC-0265 had run and given up. While the scan, the image projection
          and the strip cover the same blocks, this arm is not reached: a
          runtime that takes two modalities one at a time also takes them
          together in [Runtime_agent.caps_admit_required_modalities], because
          document admission reads [supports_multimodal_inputs], the flag
          that also grants the bundle. So a refused turn holds a block of a
          refused modality, and either the projection counts it or the strip
          removes it. Admitting documents on [supports_document_input] instead
          would make an image plus document turn on a non-multimodal runtime
          land here. Today this row is what the operator reads when one of the
          three stops covering a block the scan reported. *)
       Log.Keeper.warn
         "%s: RFC-0265 media degrade unavailable on %s -- required %s, nothing \
          strippable; the capability floor rejects this attempt"
         keeper_name
         runtime_id
         (String.concat "," required);
       emit_runtime_manifest
         ~status:"degrade_unavailable"
         ~decision:
           (Keeper_runtime_manifest.with_payload_role
              ~payload_role:Keeper_runtime_manifest.Operator_evidence
              (`Assoc
                [ ("routing_action", `String "media_degrade_unavailable")
                ; ("routing_reason", `String "required_media_not_strippable")
                ; ("degraded_runtime_id", `String runtime_id)
                ; ( "required_modalities"
                  , `String (String.concat "," required) )
                ]))
         Keeper_runtime_manifest.Runtime_routed;
       unchanged
     | note ->
       Option.iter
         (fun _ ->
           Log.Keeper.warn
             "%s: RFC-0265 media degrade on %s -- dropped %s, continuing text-only"
             keeper_name runtime_id (modality_counts_summary dropped);
           emit_runtime_manifest
             ~status:"degraded"
             ~decision:(media_degrade_manifest_decision ~runtime_id dropped)
             Keeper_runtime_manifest.Runtime_routed)
         note;
       let goal_with_note =
         stripped_goal
         @ (match note with
            | None -> []
            | Some text -> [ Agent_core.Types.text_block text ])
       in
       let dispatch_prefix =
         match stripped_checkpoint with
         | Some (checkpoint : Agent_core.Checkpoint.t) -> checkpoint.messages
         | None -> stripped_initial
       in
       let replay_projection =
         match goal_blocks with
         | Some canonical_blocks when canonical_blocks <> goal_with_note ->
           (* Agent_input.append_user_input appends this exact sanitized User
              message after the seed history. Record the boundary now, before
              the provider can append answers, tools or injected context. *)
           let input_message blocks =
             Agent_core.Types.user_msg_blocks
               (List.map
                  (function
                    | Agent_core.Types.Text text ->
                      Agent_core.Types.Text (Llm_provider.Utf8_sanitize.sanitize text)
                    | block -> block)
                  blocks)
           in
           Keeper_replay_prefix.media_degraded_with_current_input
             ~canonical_prefix:initial_messages ~dispatch_prefix
             ~canonical_input:(input_message canonical_blocks)
             ~dispatch_input:(input_message goal_with_note)
         | Some _ | None ->
           Keeper_replay_prefix.media_degraded
             ~canonical_prefix:initial_messages ~dispatch_prefix
       in
       { attempt_goal_blocks =
           (match goal_blocks, goal_with_note with
            | None, [] -> None
            | _ -> Some goal_with_note)
       ; attempt_initial_messages = stripped_initial
       ; attempt_agent_core_checkpoint = stripped_checkpoint
       ; attempt_replay_prefix_projection = replay_projection
       })

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

(* An official-client lane cannot apply a provider config transform, so a
   transform on such a lane is refused before the client is invoked. *)
let official_client_dispatch ~provider_config_transform =
  match provider_config_transform with
  | Some _ -> Keeper_attempt_dispatch.Rejected_before_dispatch
  | None -> Keeper_attempt_dispatch.Dispatched

let run_named
    ?(input_policy = Keeper_input_policy.default)
    ~runtime_id
    ?(keeper_name = "")
    ?pre_tool_rejects
    ~base_path
    ~goal
    ?goal_blocks
    ?session_id
    (* Required, not defaulted to "". Three of the runtimes this dispatches to
       -- Codex, Claude Code, Antigravity -- refuse a blank composition in
       [Keeper_official_client_host.prepare_turn], because a blank one runs the
       turn under the vendor's built-in instructions with masc's tool surface
       still attached (#33165). A default that part of the domain rejects is not
       a default: it left 34 cases red across the three official-client suites
       and #33165 fixed one of the five call sites, because an optional
       argument asks nobody. Callers that mean "no system prompt" now say so
       (#33862). *)
    ~system_prompt
    ?(tools = [])
    ~agent_core_tools
    ?(tool_requirement = Keeper_required_tools.Optional)
    ?required_native_posture
    ?(initial_messages = [])
    ?model_input_projection
    ?recovery_view
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
    ?person_queued_probe
    ?agent_core_checkpoint
    ?(continue_from_checkpoint = false)
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?on_request_wire_observation
    ?on_request_attribution
    ?official_client_continuation
    ?official_client_original_turn
    ?official_task_reference
    ?on_official_client_tool_boundary
    ?on_official_client_result_handoff
    ?on_official_client_native_action
    ?on_model_input_window_observation
    ?on_response_observed_model_input
    ?carried_front_seed
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?deferred_runtime_lane
    ?on_runtime_attempt
    ?runtime_retry_deferral
    ?checkpoint_progress
    ?on_runtime_attempt_error
    ?on_runtime_lane_terminal_error
    ?on_deferred_runtime_consumed
    ?(output_contract = Provider_default)
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (named_run_result, Agent_core.Error.t) result =
  let tool_requirement = match output_contract with
    | Tool_verdict -> Keeper_required_tools.Required
    | Provider_default -> tool_requirement in
  if output_contract = Tool_verdict
     && (Option.is_none (Runtime.get_runtime_by_id runtime_id)
         || Option.is_some deferred_runtime_lane) then
    Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig
      { field = "verifier.runtime"; detail = "A verifier slot requires a direct runtime binding without a deferred lane" }))
  else
  if continue_from_checkpoint && Option.is_none agent_core_checkpoint then
    Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig
            { field = "continuation_checkpoint"
            ; detail = "An admitted-input continuation requires its persisted checkpoint"
            }))
  else
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_core_error e)
  | Ok (sw, net) ->
	  (* Lane-aware dispatch: resolve a runtime id or ordered failover lane, then
	     attempt candidates sequentially with manifest evidence per attempt. *)
	  let runtime_id = String.trim runtime_id in
	  (* A front moved after a refusal is a position in this history, so it
	     holds for every Agent Core candidate of this turn. Kept here, at the
	     turn, because the lane walks candidates one by one: held inside a
	     candidate's own run it was lost at the walk's next step, and the
	     next candidate composed the whole history again (2026-09-18:
	     pr-updater shrank 16 MB to 3.7 MB on one candidate and sent 16 MB
	     to the next). *)
      (* Freeze the pair for the whole dispatch, including provider failover.
         The checkpoint remains the source of every atom index. *)
      (* The end of the last completed turn on this history: where a request
         with no absorbed point starts (RFC keeper-context-window-in-tokens
         §13.4) and, under the small input policy, the boundary before which
         completed turns' tool bodies demote. Read once per turn for every
         input policy and lane. A turn resuming an operation composes from
         its recovery view and names no boundary here, as before. *)
      let turn_boundary = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        match session_id, recovery_view with
        | Some trace_id, None ->
          Domain_pool_ref.submit_io_or_inline (fun () ->
            Keeper_turn_driver_try_provider.turn_start
              ~config:(Workspace.default_config base_path) ~keeper_name ~trace_id
              ~messages:initial_messages)
        | None, _ | Some _, Some _ -> Keeper_carried_front.Turn_boundary { end_atom = 0 }) in
      let continuity = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        match session_id, recovery_view with
        | None, _ | _, Some _ -> None
        | Some trace_id, None ->
          Domain_pool_ref.submit_io_or_inline (fun () ->
            let continuity, notes =
              Keeper_turn_driver_try_provider.read_keeper_continuity
                ~config:(Workspace.default_config base_path)
                ~keeper_name ~trace_id ~messages:initial_messages
            in
            List.iter
              (Keeper_turn_driver_try_provider.log_continuity_note ~keeper_name)
              notes;
            Some continuity))
      in
	  let refused_carried_front = ref None in
	  (* The same front the Agent Core branch reads, for the official-client
	     branches: they cut their start seed from this very history
	     ([Keeper_carried_front.Hands_over_its_own_list]), so a range the last
	     completed turn measured names the same atoms there. A front a refusal
	     moved is the turn's, not one candidate's, so it stands for these
	     candidates too. Those lanes hold no ledger of their own — it is
	     written from the usage of a request this process composed — so this
	     is their whole answer. *)
	  let official_client_carried_front_seed () : Keeper_carried_front.seed_read =
	    match !refused_carried_front with
	    | Some seed ->
	      { Keeper_carried_front.seed = Some seed
	      ; unreadable = None
	      ; boundary_error = None
	      }
	    | None ->
	      (match carried_front_seed with
	       | Some read -> read ()
	       | None -> Keeper_carried_front.no_seed_read)
	  in
	  (* The official-client branches take the continuity the Agent Core branch
	     takes ([continuity] above): one choice per turn for every lane, so a
	     fitting working state, else the Librarian's read position, is the same
	     absorbed point on both. What each lane weighs it against differs: the
	     Agent Core branch composes from the absorbed point whenever there is
	     one ([compose_carried_model_input]), while these lanes cut their start
	     seed themselves and keep a seed or a lane cut that sits past it
	     ([Keeper_official_client_host.carried_start_range]). The choice is
	     handed over as a position in the exact list each composition cuts,
	     and checked against that list on every call, because a lane composes
	     more than once in a turn and the list grows between compositions. A
	     list that no longer holds what the choice covered refuses the request,
	     as the same check refuses an Agent Core request
	     ([validate_continuity]): one rule on both lanes for a history that
	     moved under the turn.
	
	     [attempt_messages] is the list this candidate starts from, which is
	     the turn's history as this candidate sees it: a runtime that cannot
	     see an image is handed a reading of it in the image's place
	     ([project_input_for_attempt]). The check is held to that rendering
	     ([continuity_for_attempt]), so it answers whether the list moved in
	     flight rather than whether this candidate renders the history the
	     way the checkpoint stores it (#37812). *)
	  let official_client_librarian_front ~attempt_messages messages =
	    match Eio.Lazy.force continuity with
	    | None -> Ok Keeper_turn_driver_try_provider.No_position
	    | Some chosen ->
	      Domain_pool_ref.submit_cpu_or_inline (fun () ->
	        Keeper_turn_driver_try_provider.librarian_position
	          ~messages
	          (Keeper_turn_driver_try_provider.continuity_for_attempt
	             ~messages:attempt_messages
	             chosen))
	  in
	  (* The same record the Agent Core branch writes before each request
	     ([pre_dispatch_serialization_observer] in
	     [Keeper_turn_driver_try_provider]), so the Memory screen shows what an
	     official-client request started from too. The bytes are the carried
	     range in the canonical encoding, which is what these lanes measure;
	     the Agent Core record holds its serialized body. *)
	  let record_official_client_continuity ~runtime_id front ~transmitted_bytes =
	    match session_id with
	    | None -> ()
	    | Some trace_id ->
	      Keeper_continuity_observation.record
	        ~config:(Workspace.default_config base_path) ~keeper_name
	        { Keeper_continuity_observation.prepared_at = Time_compat.now ()
	        ; runtime_id
	        ; input =
	            Keeper_official_client_host.continuity_observation_input
	              ~trace_id ~continuity:(Eio.Lazy.force continuity) front
	        ; request_bytes = transmitted_bytes
	        }
	  in
	  (* Audit F8: removed dead routing knobs from the signature so callers cannot
	     pass values that would be silently ignored. *)
  let routing_run_id = Random_id.hex ~bytes:16 in
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  (* What this dispatch's checkpoints recorded. The caller passes the value it
     marks from its own sink: only that sink knows whether a write reached the
     canonical checkpoint or was skipped as stale, and its [Ok ()] does not say
     which ([Keeper_agent_run], [Keeper_checkpoint_store.Stale_noop]). A caller
     that marks nothing gets a value that never reaches [Tool_results_saved],
     so its lane ends a failed last candidate instead of resuming on it. *)
  let checkpoint_progress =
    match checkpoint_progress with
    | Some progress -> progress
    | None -> Atomic.make Keeper_turn_driver_try_provider.No_checkpoint_stage
  in
  let emit_runtime_manifest ?status ?decision event =
    match runtime_manifest_context, runtime_manifest_append with
    | Some manifest_ctx, Some append ->
      let decision =
        match decision with
        | None -> Some (`Assoc [ "routing_run_id", `String routing_run_id ])
        | Some (`Assoc fields) ->
          Some (`Assoc (("routing_run_id", `String routing_run_id) :: fields))
        | Some other ->
          Some (`Assoc [ ("routing_run_id", `String routing_run_id); ("decision", other) ])
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
     operators can route through explicit failover groups. The order is the
     declaration's; a resting or exhausted candidate is demoted behind its
     siblings, never remembered as a preference. *)
  (* Quota/backpressure demotion is ordering only — a demoted candidate is still
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
         wall clock; the ordering read receives one explicit [now]. *)
      ~now:(Unix.gettimeofday ())
      candidates
  in
  let* lane_candidate_ids =
    match output_contract, deferred_runtime_lane with
    | Tool_verdict, _ -> Ok [runtime_id]
    | Provider_default, Some hint -> Ok (deferred_runtime_ids hint)
    | Provider_default, None ->
      (match Runtime.resolve_assignment runtime_id with
       | `Missing -> Ok []
       | `Unavailable missing ->
         Error (Runtime_agent_core_runner.runtime_catalog_error_to_core_error
           ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing))
       | `Lane lane -> Ok (Runtime_lane.ordered_candidates lane |> demote_quota_exhausted))
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
  (* This decision is reported, not applied: the image walk already leads with
     the capable candidate a [Reroute] names. On a deferred lane the suffix order
     was frozen before pre-dispatch shaping, so [modality_reroute_candidates]
     is [[]] and the decision can only be [No_reroute_needed] or
     [No_capable_runtime], and the image walk is empty. The media degrade
     itself is not decided here for any lane: every attempt projects the input
     against the runtime it dispatches to ([project_input_for_attempt] inside
     [run_attempt] below), because the walk crosses runtimes with different
     input capabilities and one strip bound here was right for the head only
     (#33034 fixed the deferred head; the tail still received the head's view). *)
  let reroute_candidates =
    match output_contract with
    | Tool_verdict -> []
    | Provider_default -> modality_reroute_candidates
      (* NDT-OK: quota windows compare a stored expiry with wall clock; the
         ordering read receives one explicit [now], as the lane's does above. *)
      ~now:(Unix.gettimeofday ())
      ~deferred_runtime_lane
      ~first_candidate
      ~remaining_runtimes
  in
  let reroute_decision =
    lane_modality_reroute_decision
      ~checkpoint_messages
      ~initial_messages
      ~goal_blocks:current_goal_blocks
      ~first_candidate
      ~candidates:reroute_candidates
  in
  log_modality_reroute ~keeper_name ~assignment_id:runtime_id ~first_candidate_id
    reroute_decision;
  let attempt_runtimes =
    attempt_runtimes_for_turn
      ~media_walk:
        (Runtime_agent.media_walk
           ~candidates:reroute_candidates
           ~checkpoint_messages
           ~initial_messages
           current_goal_blocks)
      ~lane:(first_candidate :: remaining_runtimes)
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
  let transport_resolved =
    match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  (* The vision delegation must not spend this turn's candidates twice. Its own
     candidate set is the global media list, and the quota window moves an
     account that answered a hard rejection behind the live ones without
     removing it -- so a walk that just collected 402s would ask those same
     accounts once more through the projector before the text fallback starts
     (#34829).
     The excluded set is the walk's declared candidates rather than the prefix
     it has reached: every one of them has either been dispatched to already or
     is about to be by this same walk, so a delegation to either is work the
     walk is doing anyway. Fixing it here keeps the walk's [run_attempt]
     signature and its mutable state out of the delegation. *)
  let project_images =
    let project = Keeper_vision_ingest.fallback_projector
      ~base_path
      ~exclude_runtime_ids:lane_candidate_ids
      ~keeper_name
      () in
    fun ~mode blocks ->
      (* Exact-lane admission also owns provider selection for image evidence:
         retain unread artifacts, but never dispatch an out-of-lane vision call. *)
      let mode = match output_contract with
        | Provider_default -> mode
        | Tool_verdict -> Keeper_vision_ingest.Store_only in
      project ~mode blocks
  in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return. *)
  attempt_runtime_candidates
    ~pre_tool_rejects
    ?retry_deferral:runtime_retry_deferral
    ~tool_results_saved:(fun () ->
      Keeper_turn_driver_try_provider.tool_results_saved checkpoint_progress)
    ?on_attempt_error:on_runtime_attempt_error
    ?on_lane_terminal_error:on_runtime_lane_terminal_error
    ~allow_retry:(fun ~runtime_id:attempt_runtime_id ~attempt error ->
      let allowed =
        Keeper_turn_driver_try_provider.same_run_retry_allowed
          checkpoint_progress
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
    ~candidate_backpressure_of:(function
      | Resolved_runtime runtime -> Some runtime.Runtime.candidate_backpressure
      | Missing_runtime _ -> None)
    ~model_of:(function
      (* The served name comes from the same frozen snapshot as the quota
         scope and backpressure above: a runtime.toml reload mid-walk must not
         turn the same-model refusal off by dropping the id from the table. *)
      | Resolved_runtime runtime -> Some runtime.Runtime.model.api_name
      | Missing_runtime _ -> None)
    ~candidate_dispatchable:(function
      (* A materialized snapshot stays dispatchable even if a runtime.toml
         reload removed its id from the current table; only a candidate that
         never resolved is a dead head. *)
      | Resolved_runtime _ -> true
      | Missing_runtime _ -> false)
    ~provider_answered:(fun (named : named_run_result) -> run_result_answered named.run_result)
    ~emit_runtime_manifest
    ~run_attempt:(fun ~idx ~runtime_id:attempt_runtime_id candidate ->
      match candidate with
      | Missing_runtime runtime_id ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        ( Error (runtime_candidate_missing_error runtime_id)
        , None
        , Keeper_provider_attempt_effect.No_effect_observed
        , Keeper_attempt_dispatch.Rejected_before_dispatch )
      | Resolved_runtime runtime ->
      let agent_core_tools = match runtime.Runtime.execution, agent_ref with
        | Runtime_execution.Agent_core _, Some agent_cell -> Keeper_agent_tool_surface.on_the_wire
            ~agent_cell ~built:agent_core_tools
        | _ -> agent_core_tools in
      let source_reader_ready =
        if required_native_posture = Some Runtime_native_tools.Native_none
           && not (Runtime_execution.supports_native_none runtime.Runtime.execution) then
          Error (Keeper_required_tools.to_core_error
            {runtime_id=attempt_runtime_id;reason=Native_tools_cannot_be_disabled})
        else match official_client_continuation with
        | Some checkpoint when attempt_runtime_id <> checkpoint.Keeper_semantic_execution.runtime_id
            || Runtime_execution.checkpoint_owner runtime.Runtime.execution <> Runtime_execution.Official_client ->
          Error (Agent_core.Error.Internal "Gate continuation must resume its original official-client runtime")
        | Some _ | None -> match recovery_view, runtime.Runtime.execution with
        | Some _, Runtime_execution.Agent_core _ ->
          Keeper_recovery_transmission.require_reader agent_core_tools
          |> Result.map_error Keeper_recovery_transmission.to_core_error
        | _ -> Ok () in
      let has_tools, surface_enabled = match runtime.Runtime.execution with
        | Runtime_execution.Agent_core _ -> agent_core_tools <> [], true
        | Runtime_execution.Codex_app_server _
        | Runtime_execution.Antigravity_cli _ -> tools <> [], true
        | Runtime_execution.Claude_code _ -> tools <> [], runtime.model.tools_support in
      let verifier_ready = match output_contract with
        | Provider_default -> Ok ()
        | Tool_verdict ->
          let admission = Result.bind (Runtime.verifier_runtime_admission runtime) (fun () ->
            match Runtime_agent.decide_modality_reroute_for_runtime_candidates
              ~assigned:runtime ~candidates:[] ~checkpoint_messages ~initial_messages
              current_goal_blocks with
            | Runtime_agent.No_reroute_needed -> Ok ()
            | Runtime_agent.Reroute _ | Runtime_agent.No_capable_runtime _ ->
              Error "The admitted verifier slot cannot consume the submitted media; use another admitted slot") in
          admission |> Result.map_error (fun detail -> Agent_core.Error.Config
            (Agent_core.Error.InvalidConfig { field = "verifier.runtime"; detail })) in
      (match Result.bind verifier_ready (fun () -> Result.bind source_reader_ready (fun () ->
          Keeper_required_tools.check_surface tool_requirement
            ~runtime_id:attempt_runtime_id ~surface_enabled ~has_tools
          |> Result.map_error Keeper_required_tools.to_core_error)) with
       | Error failure ->
         Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
         Error failure, None,
         Keeper_provider_attempt_effect.No_effect_observed,
         Keeper_attempt_dispatch.Rejected_before_dispatch
       | Ok () ->
      (* Native continuation already owns its input in the checkpoint. Official
         clients still need the explicit goal, including any media blocks. *)
      let goal_blocks =
        match continue_from_checkpoint, runtime.Runtime.execution with
        | true, Runtime_execution.Agent_core _ -> None
        | _ -> goal_blocks
      in
      (* Shadows the caller's inputs with this candidate's dispatch view; the
         originals stay bound above for the next candidate's own projection. *)
      let { attempt_goal_blocks = goal_blocks
          ; attempt_initial_messages = initial_messages
          ; attempt_agent_core_checkpoint = agent_core_checkpoint
          ; attempt_replay_prefix_projection = replay_prefix_projection
          } =
        match recovery_view with
        | Some _ ->
          {attempt_goal_blocks=goal_blocks;attempt_initial_messages=initial_messages;
           attempt_agent_core_checkpoint=agent_core_checkpoint;
           attempt_replay_prefix_projection=Keeper_replay_prefix.unchanged}
        | None -> project_input_for_attempt
          ~project_images
          ~keeper_name
          ~emit_runtime_manifest
          ~goal_blocks
          ~initial_messages
          ~agent_core_checkpoint
          ~runtime_id:attempt_runtime_id
          runtime
      in
      Option.iter
        (fun observe ->
           observe
             { routing_run_id
             ; runtime_id = attempt_runtime_id
             ; lane_attempt_index = idx
             ; checkpoint_owner =
                 Runtime_execution.checkpoint_owner runtime.Runtime.execution
             })
        on_runtime_attempt;
      let error_runtime_id = attempt_runtime_id in
      let official_model_input_observation hooks =
        let attempted = ref None in
        let transmitted_observation = ref None in
        let on_observation =
          match
            on_model_input_window_observation,
            on_response_observed_model_input
          with
          | None, None -> None
          | _ ->
            Some
              (fun observation ->
                 attempted := Some observation;
                 Option.iter
                   (fun observe ->
                      observe
                        ~measurement:Turn_record.Durable_shape
                        observation)
                   on_model_input_window_observation)
        in
        let on_transmitted_model_input = function
          | Keeper_official_client_host.Whole_input_transmitted _ ->
            transmitted_observation := !attempted
          | Keeper_official_client_host.Held_by_client_session ->
            transmitted_observation := None
        in
        let hooks =
          match on_response_observed_model_input with
          | None -> hooks
          | Some observe ->
            let response_observation_hook =
              { Agent_core.Hooks.empty with
                after_turn =
                  Some
                    (function
                      | Agent_core.Hooks.AfterTurn _ ->
                        let observed = !transmitted_observation in
                        transmitted_observation := None;
                        Option.iter
                          (fun
                            (window :
                              Runtime_model_input_tail_window.window_observation) ->
                             observe
                               { Turn_record.runtime_profile =
                                   attempt_runtime_id
                               ; window =
                                   { Turn_record.transmitted_atoms =
                                       window.transmitted_atoms
                                   ; total_atoms = window.total_atoms
                                   ; measurement = Turn_record.Durable_shape
                                   ; front_atom_digest = window.front_atom_digest
                                   }
                               })
                          observed;
                        Agent_core.Hooks.Continue
                      | Agent_core.Hooks.BeforeTurn _
                      | Agent_core.Hooks.BeforeTurnParams _
                      | Agent_core.Hooks.PreToolUse _
                      | Agent_core.Hooks.PostToolUse _
                      | Agent_core.Hooks.PostToolUseFailure _
                      | Agent_core.Hooks.OnStop _
                      | Agent_core.Hooks.OnError _
                      | Agent_core.Hooks.OnToolError _ ->
                        Agent_core.Hooks.Continue)
              }
            in
            Some
              (match hooks with
               | None -> response_observation_hook
               | Some hooks ->
                 Agent_core.Hooks.compose
                   ~outer:response_observation_hook
                   ~inner:hooks)
        in
        ( (fun () ->
            attempted := None;
            transmitted_observation := None)
        , on_observation
        , on_transmitted_model_input
        , hooks )
      in
      let inference_policy =
        attempt_inference_policy
          ~runtime_id:attempt_runtime_id
          ~fallback_enable_thinking:enable_thinking
          ()
      in
      (match runtime.Runtime.execution with
       | Runtime_execution.Agent_core _ -> ()
       | Codex_app_server _ | Claude_code _ | Antigravity_cli _ ->
         Log.Keeper.info ~keeper_name
           "input policy runtime=%s selected=%s context_owner=official_client applied=false"
           attempt_runtime_id (Keeper_input_policy.to_string input_policy));
      match runtime.Runtime.execution with
      | (Runtime_execution.Codex_app_server _
        | Runtime_execution.Claude_code _
        | Runtime_execution.Antigravity_cli _) when Option.is_some recovery_view ->
        (Error (Keeper_recovery_transmission.to_core_error
          (Keeper_recovery_transmission.Client_projection_not_integrated
            {runtime_id=attempt_runtime_id})), None,
         Keeper_provider_attempt_effect.No_effect_observed,
         Keeper_attempt_dispatch.Rejected_before_dispatch)
      | Runtime_execution.Codex_app_server config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_codex ~initial_messages () =
          reset_model_input_observation ();
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_codex_runtime.run
            ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input ~runtime)
            ?required_native_posture
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
            ~on_transmitted_model_input
            (* Codex assembles the wire itself, so the shape masc can report
               is the list it handed over. Same reading the Agent Core path
               publishes; without it the turn record has no window. *)
            ?on_model_input_window_observation:
              on_model_input_window_observation
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ?official_client_continuation
            ?official_task_reference
            ?official_client_original_turn
            ?on_official_client_tool_boundary
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
            ; settled_session = None
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
        ( selected_runtime_result ?official_client_settlement:codex_attempt.settled_session runtime ~lane_attempt_index:idx codex_result
        , None
        , codex_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Antigravity_cli config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_antigravity ~initial_messages () =
          reset_model_input_observation ();
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_antigravity_runtime.run
            ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input ~runtime)
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force turn_boundary)
            (* Antigravity's CLI assembles the wire, so the shape masc can
               report is the list it handed over. *)
            ?on_model_input_window_observation:
              on_model_input_window_observation
            ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection
            ~on_transmitted_model_input
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ?official_client_continuation
            ?official_task_reference
            ?on_official_client_tool_boundary
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
            ; settled_session = None
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
        ( selected_runtime_result ?official_client_settlement:antigravity_attempt.settled_session runtime ~lane_attempt_index:idx antigravity_result
        , None
        , antigravity_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Claude_code config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_claude ~initial_messages () =
          reset_model_input_observation ();
          let tools = if runtime.model.tools_support then tools else [] in
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_claude_code_runtime.run
            ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input ~runtime)
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force turn_boundary)
            ~pre_tool_rejects
            ~base_path
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~initial_messages
            ~model_input_projection
            ~on_transmitted_model_input
            (* [Durable_shape] because that is what was measured: the official
               client assembles the wire itself, so masc can only report the
               list it handed over. The Agent Core path reports [Wire_shape]
               when its own serializer produced the bytes and falls back to
               this same shape when it could not. *)
            ?on_model_input_window_observation:
              on_model_input_window_observation
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
            ?official_client_continuation
            ?official_task_reference
            ?on_official_client_tool_boundary
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
            ; settled_session = None
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
        ( selected_runtime_result ?official_client_settlement:claude_attempt.settled_session runtime ~lane_attempt_index:idx claude_result
        , None
        , claude_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Agent_core runtime_provider_config ->
       (* Held to this candidate's own rendering of the history, for the
          reason [official_client_librarian_front] states. *)
       let continuity =
         Option.map
           (Keeper_turn_driver_try_provider.continuity_for_attempt
              ~messages:initial_messages)
           (Eio.Lazy.force continuity)
       in
       (match
          match provider_config_transform with
          | None -> Ok runtime_provider_config
          | Some transform -> transform runtime_provider_config
        with
      | Error err ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        Error err, None, Keeper_provider_attempt_effect.No_effect_observed,
        Keeper_attempt_dispatch.Rejected_before_dispatch
      | Ok provider_config ->
        let provider_config =
          match output_contract with
          | Provider_default -> provider_config
          | Tool_verdict ->
            Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config
              provider_config
        in
        (match Keeper_required_tools.check_provider
            (match recovery_view with Some _ -> Keeper_required_tools.Required | None -> tool_requirement)
            ~runtime_id:attempt_runtime_id provider_config with
         | Error failure ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
           Error (Keeper_required_tools.to_core_error failure), None,
           Keeper_provider_attempt_effect.No_effect_observed,
           Keeper_attempt_dispatch.Rejected_before_dispatch
         | Ok () ->
        (match
           Runtime.validate_dispatch_credential ~provider_config runtime
         with
         | Error credential_error ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
           ( Error
               (Runtime.dispatch_credential_error_to_core_error credential_error)
           , None
           , Keeper_provider_attempt_effect.No_effect_observed
           , Keeper_attempt_dispatch.Rejected_before_dispatch )
         | Ok () ->
          (* The marks the carried range is judged against, as the binding
             declares them (RFC keeper-context-window-in-tokens §10.2); a binding
             that declares none leaves eviction to a refusal. Their agreement
             with the model's max-context was checked at load
             ([Runtime.validate_runtime_context_marks]). *)
          (let context_marks =
             Runtime.context_marks_of_runtime_id attempt_runtime_id
           in
            let candidate = Runtime_candidate.of_provider_config provider_config in
            (* Cached provider health is observation only. Every eligible runtime
               reaches the real provider boundary; only the resulting typed error
               may drive fallback. *)
            let name = Printf.sprintf "agent_core-%s" attempt_runtime_id in
          let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx =
            { runtime_id = attempt_runtime_id
            ; error_runtime_id
            ; context_marks
            ; input_policy
            ; turn_boundary = Eio.Lazy.force turn_boundary
            ; continuity
            ; (* Read only when the process holds no ledger for this pair:
                 the range the newest completed Agent Core turn record on
                 this history measured, whichever runtime ran it, so a
                 restart or a lane's next candidate resumes the range the
                 last turn carried rather than this turn's own boundary. A
                 caller that reads no records leaves the first request to
                 that boundary. *)
              carried_front_seed =
                (fun () ->
                   match carried_front_seed with
                   | Some read -> read ()
                   | None -> Keeper_carried_front.no_seed_read)
            ; carried_front_after_refusal = (fun () -> !refused_carried_front)
            ; hold_carried_front = (fun seed -> refused_carried_front := Some seed)
            ; base_path
            ; keeper_name
            ; name
            ; goal
            ; goal_blocks
            ; session_id
            ; system_prompt
            ; (* Only this lane can widen a running turn, so only this lane
                 is handed the listing. The official-client branches above
                 take [tools] whole. A caller that named no lane view is not
                 deferring anything, so this lane sends every tool too --
                 which is what every caller did before the listing existed. *)
              tools = agent_core_tools
            ; initial_messages
            ; model_input_projection
            ; recovery_view
            ; (* Keeper policy knobs, injected from the resolved layer like
                 [provider_call_deadline_sec] below rather than threaded through
                 run_named as optionals: every entry point that reaches this
                 closure -- the turn runner, the recovery worker, the metric
                 hooks, the test drivers -- gets the operator's value, or the
                 floor where one exists. [Keeper_turn_driver_try_provider]
                 builds the options AGENT_CORE reads. *)
              stream_idle_timeout_s =
                Keeper_runtime_resolved.stream_idle_timeout_sec ()
            ; first_event_timeout_s =
                Keeper_runtime_resolved.first_event_timeout_sec ()
            ; (* The operator's override, or none: the non-streaming body read
                 has no floor, the attempt watchdog bounds it. *)
              body_timeout_s = Keeper_runtime_resolved.body_timeout_override_sec ()
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
            ; person_queued_probe
            ; temperature
            ; accept
            ; hooks
            ; approval_gate
            ; raw_trace
            ; transport_resolved
            ; checkpoint_sidecar
            ; cache_system_prompt
            ; yield_on_tool
            ; checkpoint_sink =
                Option.map
                  (canonical_checkpoint_sink ~replay_prefix_projection)
                  checkpoint_sink
            ; checkpoint_progress
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
            ; on_response_observed_model_input
            ; event_bus
            ; runtime_manifest_context
            ; runtime_manifest_append
            ; turn_start
            ; seq_ref
            }
          in
          Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
          let provider_result, checkpoint_after, _success_sample =
            Keeper_turn_driver_try_provider.run_try_provider_with_truncation_recovery
              ?continuation_checkpoint:
                (if continue_from_checkpoint then agent_core_checkpoint else None)
              try_provider_ctx candidate
          in
          let outcomes =
            project_provider_attempt_result ?checkpoint_after
              ~replay_prefix_projection provider_result in
          ( selected_runtime_result runtime ~lane_attempt_index:idx outcomes.turn_result
          , outcomes.checkpoint_after
          , Keeper_provider_attempt_effect.No_effect_observed
          , Keeper_attempt_dispatch.Dispatched ))))
       )))
    attempt_candidates


module For_testing = struct
  type nonrec provider_attempt_outcomes = provider_attempt_outcomes

  let run_result_answered = run_result_answered

  let make_deferred_runtime_lane ~assignment_id ~failed_runtime_id
        ~next_runtime_id ~later_runtime_ids ~failure =
    restore_deferred_runtime_lane ~assignment_id ~failed_runtime_id
      ~next_runtime_id ~later_runtime_ids ~failure
  ;;

  let produced_checkpoint (outcomes : provider_attempt_outcomes) = outcomes.checkpoint_after
  let project_provider_attempt_result = project_provider_attempt_result
  let canonical_checkpoint_sink = canonical_checkpoint_sink
  let provider_result outcomes = outcomes.provider_result
  let turn_result outcomes = outcomes.turn_result
  let checkpoint_after_attempt = checkpoint_after_attempt
  let success_selected_model_raw = success_selected_model_raw
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let log_modality_reroute = log_modality_reroute

  let modality_reroute_candidates = modality_reroute_candidates
  let attempt_runtimes_for_turn = attempt_runtimes_for_turn
  let lane_modality_reroute_decision = lane_modality_reroute_decision
  let dedupe_runtimes_preserve_order = dedupe_runtimes_preserve_order
  let resolve_runtime_candidates = resolve_runtime_candidates
  let resolve_runtime_candidate_for_attempt =
    resolve_runtime_candidate_for_attempt

  let selected_runtime_result = selected_runtime_result
  let apply_official_client_accept = apply_official_client_accept

	  let media_degrade_manifest_decision = media_degrade_manifest_decision
  let project_input_for_attempt = project_input_for_attempt
	  let attempt_inference_policy = attempt_inference_policy
  let attempt_runtime_candidates = attempt_runtime_candidates

  let observe_checkpoint_stage =
    Keeper_turn_driver_try_provider.observe_checkpoint_stage

  let observing_checkpoint_sink =
    Keeper_turn_driver_try_provider.observing_checkpoint_sink

  let observe_checkpoint_saved =
    Keeper_turn_driver_try_provider.observe_checkpoint_saved

  let tool_results_saved =
    Keeper_turn_driver_try_provider.tool_results_saved

  let same_run_retry_allowed =
    Keeper_turn_driver_try_provider.same_run_retry_allowed

  let accept_no_progress_should_try_next =
    Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next

end
