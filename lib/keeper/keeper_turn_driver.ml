(** Keeper_turn_driver — MASC named-runtime execution entry points.

    Public API for running AGENT_CORE agents through MASC-managed named runtime
    profiles ([run_named]), with optional MASC tool bridging variants.

    Owns one Keeper turn over the MASC runtime boundary. *)

open Result.Syntax

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Runtime_agent_core_runner
include Keeper_internal_error
include Keeper_turn_driver_helpers

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

(* H5: audio/document that the candidate cannot take were not dropped but
   projected to attachment readings or unavailable markers. Same routing action
   and reason as a drop (the turn still reaches the runtime as text), with the
   projected counts named separately so an operator can tell the two apart. *)
let media_projection_manifest_decision ~(runtime_id : string)
    (projected : (string * int) list) =
  Keeper_runtime_manifest.with_payload_role
    ~payload_role:Keeper_runtime_manifest.Operator_evidence
    (`Assoc
      [
        ("routing_action", `String "media_degraded_to_text");
        ( "routing_reason",
          `String "no_configured_runtime_accepts_required_media" );
        ("degraded_runtime_id", `String runtime_id);
        ("media_dropped_total", `Int 0);
        ("media_projected_total", `Int (modality_counts_total projected));
        ("media_projected_counts", `String (modality_counts_summary projected));
      ])

(* One wall-clock deadline for every attachment a lane walk reads, built from
   the operator's existing [turn.provider_call_deadline_sec]. That setting is
   the per-attempt no-progress ceiling of a provider call; here it only caps
   the pre-provider reading step, once per walk. It is not a turn-wide
   deadline and reserves nothing for the fallback provider call. Attachments
   and candidates share it, so the total wait does not grow with their
   number. *)
let media_reading_deadline () =
  Monotonic_deadline.after ~seconds:(Keeper_runtime_resolved.provider_call_deadline_sec ())

type output_contract = Provider_default | Tool_verdict


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
  ; tool_result_inline_ceiling_bytes : int
  ; tool_surface_enabled : bool
  ; usage_report : Runtime_execution.usage_report
  }

type runtime_attempt_candidate =
  | Resolved_runtime of Runtime_instance.t
  | Missing_runtime of string

let selected_runtime_result ?official_client_settlement (runtime : Runtime_instance.t) ~lane_attempt_index result =
  Result.map
    (fun run_result ->
       { run_result
       ; official_client_settlement
       ; selected_runtime_id = runtime.id
       ; selected_max_context = Runtime_instance.max_context_of_runtime runtime
       ; checkpoint_owner = Runtime_execution.checkpoint_owner runtime.execution
       ; lane_attempt_index
       })
    result
;;

(* Only the returned provider-turn witness establishes that this candidate
   answered. A client count or a restored counter is not that observation. *)
let run_result_answered (run_result : Runtime_agent.run_result) =
  match run_result.Runtime_agent.stop_reason with
  | Runtime_agent.Completed _
  | Runtime_agent.Yielded_to_durable_stimulus _ -> true
  | Runtime_agent.InputRequired _ -> false
;;

(* The prompt-sent callback is the invocation boundary, including resumed
   conversations. Configuration/admission errors before that boundary must not
   invent a provider attempt. An Error carries no run_result capture; retain
   that missing evidence explicitly even if an inner host-stop producer had
   already recorded an execution before a later session commit failed. *)
let official_client_observation ~keeper_name ?turn_id ~runtime_id
    ~prompt_sent_at ~execution_result result =
  match execution_result with
  | Ok (execution : Runtime_agent.run_result) ->
    Option.map (fun observation ->
      let acceptance = match result with
        | Ok _ -> Runtime_observation.Accepted
        | Error error -> Runtime_observation.Rejected (Agent_core.Error.to_string error) in
      Runtime_observation.record_host_acceptance ~keeper_name ?turn_id
        observation acceptance) execution.runtime_observation
  | Error error ->
    Option.map (fun _ -> Runtime_observation.observe_uncaptured_failure
      ~runtime_id ~keeper_name ?turn_id ~error:(Agent_core.Error.to_string error) ())
      prompt_sent_at
;;

let apply_official_client_accept ~runtime_id ~accept ~terminal_effect_state
    (run_result : Runtime_agent.run_result) =
  match run_result.stop_reason, terminal_effect_state () with
  | ( Runtime_agent.Completed _
    , Keeper_tools_agent_core.Terminal_effect_completed _ ) ->
    Ok run_result
  | (Runtime_agent.Completed _, (Keeper_tools_agent_core.Terminal_effect_open | (Keeper_tools_agent_core.Deferred_tool_result | (Keeper_tools_agent_core.External_effect_deferred | Keeper_tools_agent_core.Terminal_effect_failed _))))
  | ((Runtime_agent_context.Yielded_to_durable_stimulus _ | Runtime_agent_context.InputRequired _), _) -> Keeper_turn_driver_try_provider.apply_accept
      ~runtime_id
      ~accept
      run_result
;;

let settle_accepted_official_client_results ~pending_result_receipts result =
  Result.bind result (fun (accepted : Runtime_agent.run_result) ->
    let settled = match pending_result_receipts with
      | None -> Ok ()
      | Some consumption -> Keeper_client_tool_outbox.settle_consumption consumption
          ~stop_reason:accepted.stop_reason
          |> Result.map_error Keeper_official_client_host.internal_error in
    Result.map (fun () -> accepted) settled)
;;

(* The order [resumed_runtime_lane] fixed for the walk that resumes a hint,
   read before pre-dispatch shaping so the request is shaped for the runtime
   the walk dispatches first. A hint a walk recorded, or one restored from
   disk, is [Not_resumed]. *)
type resumed_order =
  | Not_resumed
  | Resumed of
      { head : string
      ; rest : string list
      }

type deferred_runtime_lane =
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Agent_core.Error.t
  ; resumed : resumed_order
  }

let deferred_runtime_ids hint =
  hint.next_runtime_id :: hint.later_runtime_ids

(* What a candidate of the walk that resumes a hint is to the chain of turns
   that hint belongs to. [Untried]: the hint names it, so no turn of the chain
   has attempted it (for a chat operation resumed on the path it failed on,
   the hint names that path). [Retry_of_tried]: a candidate of the lane the
   hint does not name. [Failed_last]: the runtime whose failure recorded the
   hint. A walk that did not resume a hint has only [Untried] candidates. *)
type resumed_member =
  | Untried
  | Retry_of_tried
  | Failed_last

let resumed_member hint runtime_id =
  if List.exists (String.equal runtime_id) (deferred_runtime_ids hint)
  then Untried
  else if String.equal runtime_id hint.failed_runtime_id
  then Failed_last
  else Retry_of_tried

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
(* Who a walk runs for. A fleet Keeper's turn comes back every cycle, so the
   failures it sees name the Keeper as their recorder. A one-shot walk (a
   completion review) never walks again: a mark naming it would have no one to
   retry it, so it records no failed-attempt mark (timeout, 5xx, 529, network).
   Its 429 and 402 evidence is recorded as any walk's, and an answer it
   receives clears the candidate's evidence (RFC-0458 §3.4 rule 5). An
   official CLI starts for a fleet turn as a turn of that operator Keeper,
   and for a one-shot walk as an operator call (plan D2-5). *)
type fleet_turn = { keeper_name : string }

type walk_owner =
  | Fleet_keeper_turn of fleet_turn
  | One_shot_walk

(* Whose walk is ordering the lane. A failed attempt holds until its candidate
   answers, and while a sibling answers the candidate is never dispatched to
   answer; the lane stayed on its fallback until restart (#38174). So in the
   fresh walk of the Keeper that recorded a failure, its own marks keep their
   declared place: its next cycle dispatches the first of them again (normally
   the head), which renews or clears the mark. In every other walk -- another
   Keeper's, a one-shot walk, the retry of the failed turn, a rotation inside
   a walk -- every mark sends its candidate back (RFC-0458 §3.4, 2026-09-23). *)
type walk_start = Runtime_candidate_standing.walk_start =
  | Fresh_walk_by of Runtime_candidate_backpressure.recorder
  | Every_mark_demotes

let fresh_walk_of = function
  | Fleet_keeper_turn { keeper_name } ->
    Fresh_walk_by (Runtime_candidate_backpressure.keeper_recorder ~keeper_name)
  | One_shot_walk -> Every_mark_demotes

let account_request walk_owner ~runtime_id =
  match walk_owner with
  | Fleet_keeper_turn { keeper_name } ->
    (* A lane runs the Keepers that the TOMLs of the installation name: the
       operator's, not a person's of the authorization log. *)
    Runtime_account_access.Operator_keeper_turn { keeper_name; runtime_id }
  | One_shot_walk -> Runtime_account_access.Operator_call

(* HIGH-RISK-UNREVIEWED: an attempt starts an official CLI, Claude Code (plan
   D2-5), Codex (plan D2-6) or Muse (plan D3), only on an account the access
   authorized for this walk, and Antigravity only where the process shares
   its host account (plan D3b). The refusal is masc's own,
   made before anything is sent, so it is the non-rotating local refusal of a
   provider_config_transform: no provider evidence names the candidate. *)
let account_refused refusal =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "account"; detail = Runtime_account_access.refusal_to_string refusal })
;;

let authorize_account walk_owner ~runtime_id account =
  Runtime_account_access.authorize (account_request walk_owner ~runtime_id) account
  |> Result.map_error account_refused
;;

let authorize_muse_account walk_owner ~runtime_id home =
  Runtime_account_access.authorize_muse
    (account_request walk_owner ~runtime_id)
    (Runtime_account_access.Declared_home home)
  |> Result.map_error account_refused
;;

let authorize_host_account client =
  Runtime_account_access.authorize_host client |> Result.map_error account_refused
;;

(* HIGH-RISK-UNREVIEWED: an Agent_core candidate sends with the key its
   operator declared, which only a single-user process shares (plan D4). *)
let authorize_api_provider sealed =
  Runtime_account_access.authorize_api sealed |> Result.map_error account_refused
;;

(* How long a rate observation holds its path back: the provider's usable
   wait, or the throttle floor (RFC-provider-path-rest §3.3). The walk order
   and the path's release read this one rule, so a path rejoins its declared
   place at the moment its rest ends, whether or not it answered since. *)
let rate_limit_rest_sec ~retry_after =
  Keeper_runtime_failure_route.path_rest_sec
    ~cap_sec:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec
    ~retry_class:Keeper_runtime_failure_route.Rate_limited
    ~retry_after_hint:retry_after

let keeper_walk start =
  Runtime_candidate_standing.Keeper_walk { start; rest_sec = rate_limit_rest_sec }

let quota_ordered_runtime_ids ~now ~walk runtime_ids =
  (* Resolve once so both kinds of ordering evidence use the same catalog row. *)
  let resolved = List.map (fun id -> id, Runtime.get_runtime_by_id id) runtime_ids in
  let resolvable, unresolvable = List.partition (fun (_, rt) -> Option.is_some rt) resolved in
  let ordered = Runtime_candidate_standing.order ~now
    ~policy:(keeper_walk walk)
    ~quota_scope_of:(fun (_, rt) -> Option.map Runtime_instance.quota_scope_of_runtime rt)
    ~candidate_backpressure_of:(fun (_, rt) ->
      Option.map (fun (rt : Runtime_instance.t) -> rt.candidate_backpressure) rt)
    resolvable in
  List.map fst (ordered @ unresolvable)
;;

(* The candidates a turn resuming [hint] walks, before ordering. The hint only
   says where the walk starts, so its [Untried] candidates come first, in the
   hint's order. The other candidates the assignment's current lane declares
   follow in declared order, and the runtime that failed goes after all of
   them: the input is not handed straight back to it, and the walk still
   reaches it. An assignment that resolves to no lane adds nothing to the
   hint. *)
let resumed_walk_order hint =
  let lane =
    match Runtime.resolve_assignment hint.assignment_id with
    | `Lane lane -> Runtime_lane.ordered_candidates lane
    | `Missing | `Unavailable _ -> []
  in
  let named =
    List.fold_left
      (fun named id -> if List.exists (String.equal id) named then named else id :: named)
      []
      (deferred_runtime_ids hint @ lane)
    |> List.rev
  in
  let placed wanted =
    List.filter
      (fun id ->
         match wanted, resumed_member hint id with
         | Untried, Untried | Retry_of_tried, Retry_of_tried | Failed_last, Failed_last -> true
         | Untried, (Retry_of_tried | Failed_last)
         | Retry_of_tried, (Untried | Failed_last)
         | Failed_last, (Untried | Retry_of_tried) -> false)
      named
  in
  placed Untried @ placed Retry_of_tried @ placed Failed_last
;;

(* The resumed walk in the order the next turn dispatches it:
   [resumed_walk_order] under the quota and backpressure demotion that orders
   the rest of every walk. The hint itself is kept, so a lane already resumed
   is resumed again from its hint. *)
let resumed_runtime_lane ~now hint =
  match quota_ordered_runtime_ids ~now ~walk:Every_mark_demotes (resumed_walk_order hint) with
  | head :: rest -> { hint with resumed = Resumed { head; rest } }
  | [] -> hint
;;

let resumed_walk_ids lane =
  match lane.resumed with
  | Resumed { head; rest } -> head :: rest
  | Not_resumed -> resumed_walk_order lane
;;

let resumed_head lane =
  match lane.resumed with
  | Resumed { head; rest = _ } -> head
  | Not_resumed -> lane.next_runtime_id
;;

type release_basis =
  | Stated_by_provider
  | Bounded_by_masc

let release_bases = [ Stated_by_provider; Bounded_by_masc ]

let release_basis_to_wire = function
  | Stated_by_provider -> "stated_by_provider"
  | Bounded_by_masc -> "bounded_by_masc"
;;

(* Read back through the spellings [release_basis_to_wire] writes, so the
   two cannot disagree on one. *)
let release_basis_of_wire wire =
  List.find_opt (fun basis -> String.equal (release_basis_to_wire basis) wire) release_bases
;;

let walk_rest_serving_wire = "serving"
let walk_rest_resting_wire = "resting"

type path_rest =
  | Path_serving
  | Path_resting of
      { release_at : float
      ; release_basis : release_basis
      }

type walk_rest =
  | Walk_head_serving of { runtime_id : string }
  | Walk_waits_until of
      { release_at : float
      ; release_basis : release_basis
      ; resting_runtime_id : string
      }

type wait_basis = Failure_response | Observed_path_rest

type next_dispatch =
  | Dispatch_now of { runtime_id : string }
  | Wait_until of
      { release_at : float
      ; waiting_on : string
      ; basis : wait_basis
      }

(* One store's rest on a runtime path, and who set the time it ends. A rate
   limit ends at the provider's stated wait, or at the throttle floor after it
   was noted. A quota window the provider or its usage read dated ends at that
   reset. A quota observation ends at the fallback cap after it was noted. The
   walk order holds the path back until exactly that time
   (RFC-provider-path-rest §3.3). *)
type path_rest_part =
  { ends_at : float
  ; set_by : release_basis
  }

let path_rest_parts ~now (runtime : Runtime_instance.t) =
  let rate_limit_rest =
    match
      Runtime_candidate_backpressure.candidate_backpressure
        ~now
        ~candidate:runtime.candidate_backpressure
    with
    | None | Some { Runtime_candidate_backpressure.rate_limit = None; failed_attempt = _ } -> []
    | Some
        { Runtime_candidate_backpressure.rate_limit =
            Some (Runtime_candidate_backpressure.Unknown_scope_rate_limit { noted_at; retry_after })
        ; failed_attempt = _
        } ->
      let set_by =
        match Keeper_runtime_failure_route.usable_retry_after retry_after with
        | Some _ -> Stated_by_provider
        | None -> Bounded_by_masc
      in
      [ { ends_at = noted_at +. rate_limit_rest_sec ~retry_after; set_by } ]
  in
  let quota_rest =
    match
      Runtime_quota_window.rest ~scope:(Runtime_instance.quota_scope_of_runtime runtime) ~now
    with
    | None -> []
    | Some (Runtime_quota_window.Reset_stated resets_at) ->
      [ { ends_at = resets_at; set_by = Stated_by_provider } ]
    | Some (Runtime_quota_window.Observed_until rests_until) ->
      [ { ends_at = rests_until; set_by = Bounded_by_masc } ]
  in
  rate_limit_rest @ quota_rest
;;

(* When one runtime path is released, read from the same two stores the walk
   order reads (RFC-provider-path-rest §3.3). The order holds every rest back
   until exactly the time [path_rest_parts] gives it, so at the release the
   walk promotes the path again, and the wait and the ordering evidence end at
   the same moment. The latest rest gives the release and who set it. A failed
   attempt is not a rest: it demotes the path until the candidate answers and
   never makes a dispatch wait (RFC-0458 §3.4). *)
let runtime_path_rest ~now (runtime : Runtime_instance.t) =
  let latest =
    List.fold_left
      (fun held part ->
         match held with
         | Some held when Float.compare held.ends_at part.ends_at >= 0 -> Some held
         | Some _ | None -> Some part)
      None
      (path_rest_parts ~now runtime)
  in
  match latest with
  | Some { ends_at; set_by } when Float.compare now ends_at < 0 ->
    Path_resting { release_at = ends_at; release_basis = set_by }
  | Some _ | None -> Path_serving
;;

(* [runtime_path_rest] of the runtime the table resolves [runtime_id] to. An
   id the table cannot resolve is no evidence of a rest. *)
let path_rest ~now runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Path_serving
  | Some runtime -> runtime_path_rest ~now runtime
;;

(* A walk dispatches its head first, so the head decides: a serving head takes
   the input now. A resting head waits for the first moment the walk's head can
   serve: the head's own release, or an earlier release of a later path, which
   the walk order promotes at that moment. *)
let walk_rest ~now ~head ~later =
  match path_rest ~now head with
  | Path_serving -> Walk_head_serving { runtime_id = head }
  | Path_resting { release_at = head_release_at; release_basis = head_basis } ->
    let release_at, release_basis, resting_runtime_id =
      List.fold_left
        (fun ((earliest, _, _) as found) runtime_id ->
           match path_rest ~now runtime_id with
           | Path_resting { release_at; release_basis }
             when Float.compare release_at earliest < 0 ->
             release_at, release_basis, runtime_id
           | Path_resting { release_at = _; release_basis = _ } | Path_serving -> found)
        (head_release_at, head_basis, head)
        later
    in
    Walk_waits_until { release_at; release_basis; resting_runtime_id }
;;

(* The walk a turn resuming the deferred suffix dispatches
   ([resumed_runtime_lane]), so a resting suffix path does not hold the turn
   while a lane candidate that was not told to rest can take it. *)
let deferred_lane_rest ~now hint =
  match resumed_walk_ids (resumed_runtime_lane ~now hint) with
  | head :: later -> walk_rest ~now ~head ~later
  | [] -> walk_rest ~now ~head:hint.next_runtime_id ~later:hint.later_runtime_ids
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

let assignment_walk_order ~now ~walk assignment_id =
  match Runtime.resolve_assignment assignment_id with
  | `Lane lane ->
    let lane_id = Runtime_lane.id lane in
    let declared = Runtime_lane.ordered_candidates lane in
    Ok { lane_id; declared; order = quota_ordered_runtime_ids ~now ~walk declared }
  | `Unavailable missing -> Error (Catalog_unavailable missing)
  | `Missing -> Error Assignment_missing
;;

(* An assignment the walk would refuse still names a path whose rest the
   failure wait reads; it rests as its own single candidate. *)
let assignment_walk_rest ~now assignment_id =
  (* Whose walk it is only moves a failed attempt, and a failed attempt never
     rests (RFC-0458 §3.4), so every walker reaches the same rest. *)
  match assignment_walk_order ~now ~walk:Every_mark_demotes assignment_id with
  | Ok { order = head :: later; _ } -> walk_rest ~now ~head ~later
  | Ok { order = []; _ } | Error (Assignment_missing | Catalog_unavailable _) ->
    Walk_head_serving { runtime_id = assignment_id }
;;

(* The earliest moment after [now] at which a rest on this assignment's walk
   ends. The walk's shown rest can move at that moment without any write. *)
let assignment_next_dated_release ~now assignment_id =
  match assignment_walk_order ~now ~walk:Every_mark_demotes assignment_id with
  | Error (Assignment_missing | Catalog_unavailable _) -> None
  | Ok { order; _ } ->
    List.concat_map
      (fun runtime_id ->
         match Runtime.get_runtime_by_id runtime_id with
         | None -> []
         | Some runtime -> path_rest_parts ~now runtime)
      order
    |> List.fold_left
         (fun earliest { ends_at; set_by = _ } ->
            if Float.compare ends_at now > 0
            then Some (Option.fold earliest ~none:ends_at ~some:(Float.min ends_at))
            else earliest)
         None
;;

(* The next dispatch after a failed turn, shared by the heartbeat cycle and
   the chat lane's deferred retry so both answer one failure the same way
   (RFC-provider-path-rest §3.1).

   A deferred suffix names where the resumed walk starts, and that walk
   ([deferred_lane_rest]) decides. Without a suffix a multi-candidate
   assignment follows its fresh walk's rest. A final candidate's quota does
   not rest siblings that failed for unrelated reasons; a serving head returns
   to ordinary cadence, not an immediate replay. A single/unresolved
   assignment also retains the failed response's rest. Every other failure
   without a suffix follows the fresh walk's observed rest the same way: the
   turn's route need not name what its attempts were told. An effect fence
   ends a turn as [Exhausted_visible_alive] even when the fenced attempt was a
   provider-stated quota, and that attempt has already rested its path. *)
let next_dispatch_after_failure ~now ~route ~assignment_id deferred =
  let module Route = Keeper_runtime_failure_route in
  let cap_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
  let route_release retry_class retry_after =
    now +. Route.path_rest_sec ~cap_sec ~retry_class ~retry_after_hint:retry_after
  in
  let observed_walk_rest () =
    match assignment_walk_rest ~now assignment_id with
    | Walk_head_serving _ -> None
    | Walk_waits_until { release_at; release_basis = _; resting_runtime_id } ->
      Some (Wait_until { release_at; waiting_on = resting_runtime_id; basis = Observed_path_rest })
  in
  match route, deferred with
  | ( ( Route.Retry_after_observed
          { retry_class =
              ( Route.Rate_limited | Route.Hard_quota | Route.Provider_capacity
              | Route.Server_error | Route.Empty_completion _
              | Route.Network_transient | Route.Provider_timeout
              | Route.Local_admission_timeout )
          ; _
          }
      | Route.Rotate_now _ | Route.Exhausted_visible_alive _ )
    , Some hint ) ->
    Some
      (match deferred_lane_rest ~now hint with
       | Walk_head_serving { runtime_id } -> Dispatch_now { runtime_id }
       | Walk_waits_until { release_at; release_basis = _; resting_runtime_id } ->
         Wait_until { release_at; waiting_on = resting_runtime_id; basis = Observed_path_rest })
  | ( Route.Retry_after_observed
        { retry_class = (Route.Rate_limited | Route.Hard_quota) as retry_class; retry_after }
    , None ) ->
    (match assignment_walk_order ~now ~walk:Every_mark_demotes assignment_id with
     | Ok { order = _ :: _ :: _; _ } ->
       (* The refusal names the last failed candidate, not every path in the
          lane. Other candidates may already serve again after a transient
          failure. Keep normal cadence when a fresh walk can start; only the
          walk's own observed rest can delay all of its pending inputs. *)
       observed_walk_rest ()
     | Ok { order = [] | [ _ ]; _ }
     | Error (Assignment_missing | Catalog_unavailable _) ->
       let failed_release_at = route_release retry_class retry_after in
       let release_at, waiting_on, basis =
         match assignment_walk_rest ~now assignment_id with
         | Walk_waits_until { release_at; release_basis = _; resting_runtime_id }
           when Float.compare release_at failed_release_at > 0 ->
           release_at, resting_runtime_id, Observed_path_rest
         | Walk_waits_until { release_at = _; release_basis = _; resting_runtime_id = _ } ->
           failed_release_at, assignment_id, Observed_path_rest
         | Walk_head_serving _ ->
           failed_release_at, assignment_id, Failure_response
       in
       Some (Wait_until { release_at; waiting_on; basis }))
  | ( ( Route.Retry_after_observed
          { retry_class =
              Route.Provider_capacity | Route.Empty_completion _ | Route.Server_error
              | Route.Network_transient | Route.Provider_timeout
              | Route.Local_admission_timeout
          ; _
          }
      | Route.Rotate_now _ | Route.Exhausted_visible_alive _ )
    , None ) ->
    observed_walk_rest ()
;;

type provider_rest =
  { release_at : float
  ; waiting_on : string
  ; basis : wait_basis
  }

(* The route carries every fact the rest needs. [Hard_quota] comes only from
   the typed [PaymentRequired] and [HardQuota] constructors. An attempt whose
   tool effect was attempted, or could not be observed, is fenced, and a
   fenced attempt routes as [Exhausted_visible_alive] at either boundary. A
   usable [retry_after] is the time the provider stated. The wait is the one
   [next_dispatch_after_failure] gives, so the rest names the time the
   heartbeat sleeps until. *)
let provider_rest_of_failure ~now ~route ~assignment_id deferred =
  let module Route = Keeper_runtime_failure_route in
  let rest_of_wait () =
    match next_dispatch_after_failure ~now ~route ~assignment_id deferred with
    | Some (Wait_until { release_at; waiting_on; basis }) ->
      Some { release_at; waiting_on; basis }
    | Some (Dispatch_now _) | None -> None
  in
  match route with
  | Route.Retry_after_observed { retry_class = Route.Hard_quota; retry_after } ->
    (match Route.usable_retry_after retry_after with
     | Some _ -> rest_of_wait ()
     | None -> None)
  | Route.Retry_after_observed
      { retry_class =
          ( Route.Rate_limited | Route.Provider_capacity | Route.Empty_completion _
          | Route.Server_error | Route.Network_transient | Route.Provider_timeout
          | Route.Local_admission_timeout )
      ; retry_after = _
      }
  | Route.Rotate_now
      { rotate =
          ( Route.Auth_failed | Route.Authorization_refused | Route.Model_unavailable
          | Route.Resumable_cli_session | Route.Candidates_filtered
          | Route.Runtime_exhausted | Route.No_progress_empty
          | Route.No_progress_thinking_only | Route.No_progress_truncated
          | Route.Refusal_body_not_received | Route.Admission
          | Route.Provider_reported_failure | Route.Request_refused
          | Route.Provider_wire_defect | Route.Server_error_not_transient
          | Route.Context_window_exceeded )
      }
  | Route.Exhausted_visible_alive
      { terminal =
          ( Route.Deterministic_request | Route.Session_claim_refused
          | Route.Transcript_refused | Route.Contract_violation | Route.Protocol_error
          | Route.Config_mismatch | Route.Provider_integration
          | Route.Unmodeled_empty_completion
          | Route.Terminal_effect_dependency_unavailable
          | Route.Terminal_effect_policy_rejection
          | Route.Terminal_effect_runtime_failure
          | Route.Terminal_effect_workflow_rejection
          | Route.Terminal_effect_operator_cancelled
          | Route.Provider_attempt_effect_fenced
              (Route.Fenced_effect_attempted | Route.Fenced_observation_unavailable)
          | Route.Tool_correction_lost
              (Route.Fenced_effect_attempted | Route.Fenced_observation_unavailable)
          | Route.Internal_opaque )
      } -> None
;;

(* Two lanes name the same hint. The order a resumed lane fixed is not part of
   the hint. *)
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
  ; resumed = Not_resumed
  }
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
  else if Keeper_turn_driver_try_runtime.candidate_access_should_try_next error
  then
    true
  else
    match Keeper_turn_driver_try_runtime.core_error_to_http_error error with
    | Some http_err -> Runtime_attempt_fsm.should_try_next http_err
    | None -> false

(* Whether a walk has attempted a candidate its hint left untried. A walk
   that resumes no hint has: every candidate of it is [Untried]. *)
type untried_progress =
  | No_untried_attempted
  | Untried_attempted

(* The usage read after an account refusal, for a runtime whose provider
   declares one; a provider that declares none has nothing to ask. The outcome
   is logged where it is read; the walk reads only the quota window it may
   have written. *)
let read_runtime_usage_after_account_refusal runtime =
  match Runtime_provider_usage_read.http_read_of_runtime runtime with
  | None -> ()
  | Some http ->
    let (_ : Runtime_provider_usage_read.account_refusal_outcome) =
      Runtime_provider_usage_read.read_runtime_after_account_refusal runtime http
    in
    ()
;;

let attempt_runtime_candidates
    ?(pre_tool_rejects = ref [])
    ?(allow_retry = fun ~runtime_id:_ ~attempt:_ _error -> true)
    ?(allow_accept_no_progress_retry = fun ~runtime_id:_ ~attempt:_ _error ->
      true)
    ?retry_deferral
    ?(tool_results_saved = fun () -> false)
    ?(attempt_continuation = fun ~dispatch:_ _ -> Runtime_attempt_dispatch.Next_may_dispatch)
    ?(on_attempt_error = fun ~runtime_id:_ ~attempt:_ ~dispatch:_ _error -> ())
    ?(on_lane_terminal_error = fun (_ : lane_terminal_error) -> ())
    ?(provider_answered = fun _ -> true)
    ?quota_scope_of
    ?candidate_backpressure_of
    ?candidate_dispatchable
    ?read_usage_after_account_refusal
    ?(member_of = fun _ -> Untried)
    ~walk_owner
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
  let read_usage_after_account_refusal =
    match read_usage_after_account_refusal with
    | Some read -> read
    | None ->
      fun candidate ->
        Option.iter
          read_runtime_usage_after_account_refusal
          (Runtime.get_runtime_by_id (runtime_id_of candidate))
  in
  let candidate_backpressure_of =
    match candidate_backpressure_of with
    | Some candidate_backpressure_of -> candidate_backpressure_of
    | None -> fun candidate ->
        Runtime.get_runtime_by_id (runtime_id_of candidate)
        |> Option.map (fun (runtime : Runtime_instance.t) -> runtime.candidate_backpressure)
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
    Runtime_candidate_standing.order
      ~now:(Unix.gettimeofday ())
      ~policy:(keeper_walk Every_mark_demotes)
      ~quota_scope_of ~candidate_backpressure_of
      dispatchable
    @ undispatchable
  in
  (* Every error the walk returns from a candidate passes through here, so
     the caller learns which candidate produced the lane's error. *)
  let dispatched_seen = ref false in
  let lane_terminal (terminal : lane_terminal_error) =
    let terminal = if !dispatched_seen then
      {terminal with lane_error=Keeper_internal_error.without_guidance_preparation_authority terminal.lane_error}
      else terminal in
    on_lane_terminal_error terminal;
    Error terminal.lane_error
  in
  let rec loop
      ~(observed_overflow : lane_terminal_error option)
      ~(untried : untried_progress)
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
    | candidate :: rest -> attempt ~observed_overflow ~untried idx candidate rest
  and attempt ~observed_overflow ~untried idx candidate rest =
    let is_last = rest = [] in
    let untried =
      match untried, member_of candidate with
      | Untried_attempted, (Untried | Retry_of_tried | Failed_last)
      | No_untried_attempted, Untried -> Untried_attempted
      | No_untried_attempted, (Retry_of_tried | Failed_last) -> No_untried_attempted
    in
    let attempt_runtime_id = runtime_id_of candidate in
    (* Bind quota ownership to the exact candidate that will be dispatched.
       [run_attempt] may span a runtime.toml reload; resolving the id after
       the provider returns could then attribute the old credential's
       response to the replacement catalog row. *)
    let attempt_quota_scope = quota_scope_of candidate in
    let attempt_candidate_backpressure = candidate_backpressure_of candidate in
    let observe_standing observation =
      Runtime_candidate_standing.observe ~candidate:attempt_candidate_backpressure
        ~quota_scope:attempt_quota_scope observation in
    let clear_answered_candidate_evidence () =
      observe_standing Runtime_candidate_standing.Answered
    in
    emit_runtime_manifest
      ~status:"attempt"
      ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
      Keeper_runtime_manifest.Runtime_routed;
    let attempt = run_attempt ~idx ~runtime_id:attempt_runtime_id candidate in
    let _, _, _, dispatch = attempt in
    (match dispatch with
     | Keeper_attempt_dispatch.Dispatched -> dispatched_seen := true
     | Rejected_before_dispatch -> ());
    (match attempt with
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
       (* HTTP 429 and coarse Provider.RateLimit do not identify the
          exhausted resource. Keep that unknown scope and the optional
          provider hint as candidate-only ordering evidence. A shared
          credential quota rests on the distinct HardQuota/402 contract, or
          on the provider's usage read after a 429 that states no wait. *)
       let note_quota retry_after =
         (* A hint the provider did not really state -- zero, negative, NaN --
            named no reset. Planting it as a window would date the quota to a
            moment already past, and that window replaces an observation the
            scope already carried ([Runtime_quota_window]), leaving the scope
            looking available. The rule for reading a hint is the one
            [path_rest_sec] and [route_resumes_on_same_path] read. *)
         let resets_at = Option.map
           (fun retry_after_s -> Unix.gettimeofday () +. retry_after_s)
           (Keeper_runtime_failure_route.usable_retry_after retry_after) in
         observe_standing (Runtime_candidate_standing.Hard_quota {resets_at})
       in
       let note_rate_limit retry_after =
         observe_standing (Runtime_candidate_standing.Rate_limited {retry_after})
       in
       let note_failed_attempt failure =
         match walk_owner with
         | Fleet_keeper_turn { keeper_name } ->
           Option.iter
             (fun candidate ->
                Runtime_candidate_backpressure.note_failed_attempt
                  ~candidate ~failure
                  ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name))
             attempt_candidate_backpressure
         | One_shot_walk -> ()
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
       let record_route_evidence () =
        match route with
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Rate_limited; retry_after } ->
          note_rate_limit retry_after;
          (* A 429 that states no wait does not say whether a throttle or a
             spent usage window refused the account, and alone it rests the
             path only the throttle floor. Ollama Cloud answers a spent
             session window this way (2026-10-05 and 10-06: 2,185 refusals,
             each keeper on the lane calling again about once a minute for
             62 and then 105 minutes). The declared [usage-read] answers it
             as it answers a 403, below. A 429 that states its wait has
             already said how long the path rests. *)
          (match Keeper_runtime_failure_route.usable_retry_after retry_after with
           | Some _ -> ()
           | None -> read_usage_after_account_refusal candidate)
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Hard_quota; retry_after } ->
          (* A spent quota that states no reset rests the scope only to the
             fallback cap, a time MASC set: the path comes back then and is
             refused again while the window stays spent. GLM's 1308 states
             its reset only in prose. The provider's declared [usage-read]
             dates the rest, as after a 429 without a wait. The refusal is
             recorded first, so a turn cancelled during the read, and a walk
             that runs meanwhile, still see the path rest; a dated window
             the read finds replaces that observation. A
             failed read leaves the observation, and the next refusal reads
             again. A payment refusal (402) names no usage window and is not
             read. *)
          note_quota retry_after;
          (match
             ( Keeper_runtime_failure_route.usable_retry_after retry_after
             , Keeper_runtime_failure_route.hard_quota_source error )
           with
           | None, Some Keeper_runtime_failure_route.Provider_quota_refused ->
             read_usage_after_account_refusal candidate
           | ( Some _
             , ( Some
                   ( Keeper_runtime_failure_route.Payment_refused
                   | Keeper_runtime_failure_route.Provider_quota_refused )
               | None ) )
           | None, (Some Keeper_runtime_failure_route.Payment_refused | None) -> ())
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
          note_failed_attempt Runtime_candidate_backpressure.Provider_timeout
        (* The wait expired in MASC's own admission before anything was sent,
           which says nothing about the candidate. *)
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Local_admission_timeout
            ; retry_after = _
            } -> ()
        (* A 529 or a provider capacity pool refused this candidate without
           an answer. The next candidate is a different pool. *)
        | Keeper_runtime_failure_route.Retry_after_observed
            { retry_class = Keeper_runtime_failure_route.Provider_capacity; retry_after = _ } ->
          note_failed_attempt Runtime_candidate_backpressure.Provider_capacity
        (* A 403 refused the account and does not say why. A provider may
           answer a spent usage window this way and answer a client its plan
           does not admit with the same body (2026-09-25: 17 of 17 cycles
           after a restart walked such a candidate first, the one on its
           lanes with no mark). The status rests nothing. A provider that declares
           [usage-read] is asked once, here, before the walk moves on: a
           spent window rests the scope until its stated reset, so this walk
           and every later one sees it; a window with headroom, a failed
           read, or no [usage-read] leaves no evidence, as for a 401. *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate = Keeper_runtime_failure_route.Authorization_refused } ->
          read_usage_after_account_refusal candidate
        (* A credential denial rotates to the next candidate within this
           turn only. Held as ordering evidence it would stay until the head
           itself answered, which it never gets to do while a sibling
           answers, so every new turn starts again from the head. The moment
           is kept for the runtime list only, where it stays until a call on
           the same credential is answered. *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate = Keeper_runtime_failure_route.Auth_failed } ->
          observe_standing
            (Runtime_candidate_standing.Credential_refused
               { noted_at = Unix.gettimeofday () })
        (* These candidates answered, or the failure says nothing durable
           about their ability to answer a later turn (RFC-0458 §3.4, §6). *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate =
                ( Keeper_runtime_failure_route.Model_unavailable
                | Keeper_runtime_failure_route.Resumable_cli_session
                | Keeper_runtime_failure_route.Candidates_filtered
                | Keeper_runtime_failure_route.Runtime_exhausted
                | Keeper_runtime_failure_route.No_progress_empty
                | Keeper_runtime_failure_route.No_progress_thinking_only
                | Keeper_runtime_failure_route.No_progress_truncated
                | Keeper_runtime_failure_route.Refusal_body_not_received
                | Keeper_runtime_failure_route.Admission
                | Keeper_runtime_failure_route.Provider_reported_failure
                | Keeper_runtime_failure_route.Request_refused
                | Keeper_runtime_failure_route.Provider_wire_defect
                (* the input outgrew this window; it says nothing about
                   the candidate answering a smaller turn (#38984). *)
                | Keeper_runtime_failure_route.Context_window_exceeded )
            } ->
          ()
        (* A 5xx the provider called permanent failed this candidate without
           an answer, the same fact a transient 5xx records. *)
        | Keeper_runtime_failure_route.Rotate_now
            { rotate = Keeper_runtime_failure_route.Server_error_not_transient } ->
          note_failed_attempt Runtime_candidate_backpressure.Server_error
        (* The turn's input or MASC itself failed; another candidate would not
           do better, so this is no evidence about this one. *)
        | Keeper_runtime_failure_route.Exhausted_visible_alive _ -> ()
       in
       let report_attempt_error () =
         on_attempt_error
           ~runtime_id:attempt_runtime_id
           ~attempt:idx
           ~dispatch
           error
       in
       (* Let observers retain this failure's stated rest before a later
          candidate outlives it. The quota/usage read above owns that evidence;
          a callback before it cannot observe the refusal's newly stated end.
          A turn cancelled during that read still reports the failure, with
          the rest recorded before the read, and then ends as cancelled. In
          a fiber the report runs shielded from that cancellation, so a report
          that suspends cannot raise a new [Cancelled] over the original. *)
       (match record_route_evidence () with
        | () -> report_attempt_error ()
        | exception (Eio.Cancel.Cancelled _ as cancelled) ->
          let backtrace = Printexc.get_raw_backtrace () in
          (match Fs_compat.execution_context () with
           | Fs_compat.Eio_fiber -> Eio.Cancel.protect report_attempt_error
           | Fs_compat.Non_eio -> report_attempt_error ());
          Printexc.raise_with_backtrace cancelled backtrace);
       (* Stable demotion retains every declared candidate, including when
          all are observed unavailable. Neither hint causes a wait or gate. *)
       let rest = demote_rest rest in
       let continuation = attempt_continuation ~dispatch error in
       let request_retry_admitted = match continuation with
         | Runtime_attempt_dispatch.Next_may_dispatch -> true
         | Original_must_resolve -> false in
       let retry_admitted =
         allow_retry ~runtime_id:attempt_runtime_id ~attempt:idx error
         && request_retry_admitted
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
       (* RFC last-path-resumes-after-progress §3.1: a chat operation that
          saved tool results before a failure that passes with time, and has
          no untried candidate left to hand its input to, continues on the
          candidate it failed on from its latest checkpoint. Each such resume
          needs tool results saved after the previous one, so resumes cannot
          outnumber the tool rounds the operation ran. A cycle-restarting lane
          starts a new turn that regains progress with its first tool, so it
          never resumes here. *)
       let defer_to_the_failed_path () =
         match retry_deferral with
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
             ; resumed = Not_resumed
             }
         | Some
             { continuation = Resume_operation_checkpoint _ | Restart_cycle
             ; on_deferred = _
             }
         | None -> ()
       in
       if not request_retry_admitted
       then lane_terminal (this_candidate error)
       else if not effect_retry_admitted
       then lane_terminal (this_candidate terminal_error)
       else if retry_admitted && error_is_retryable
       then loop ~observed_overflow ~untried (idx + 1) rest
       else if is_last
       then (
         (* Lane fully exhausted: an overflow seen anywhere in the rotation
            outranks the last candidate's error so the failure route and
            blocker report the deterministic capacity bound. Cascade
            telemetry already published each candidate's own error. *)
         match observed_overflow with
         | Some overflow -> lane_terminal overflow
         | None ->
           defer_to_the_failed_path ();
           lane_terminal (this_candidate error))
       else (
         (* The walk stops before the end of its lane. It hands the input to
            the candidates its hint left untried that it has not reached, in
            walk order. Candidates the chain already tried are not handed the
            input again: a resumed walk covers the whole lane, and a hint that
            named them would never shrink, so turns that each stop after a
            checkpoint would follow one another without end. A walk that
            reached none of its untried candidates hands no suffix on, because
            it would name the same untried candidates again. Each suffix of a
            chain therefore names fewer candidates than the one before, and
            the chain ends when none is left. With no suffix to hand on, a chat
            operation may still continue on the path it failed on, above. *)
         let untried_rest =
           List.filter
             (fun candidate ->
                match member_of candidate with
                | Untried -> true
                | Retry_of_tried | Failed_last -> false)
             rest
         in
         (match error_is_retryable, untried, untried_rest with
          | true, Untried_attempted, next :: later ->
            Option.iter
              (fun { continuation = _; on_deferred } ->
                 on_deferred
                   { assignment_id = runtime_id
                   ; failed_runtime_id = attempt_runtime_id
                   ; next_runtime_id = runtime_id_of next
                   ; later_runtime_ids = List.map runtime_id_of later
                   ; failure = error
                   ; resumed = Not_resumed
                   })
              retry_deferral
          | true, Untried_attempted, [] | true, No_untried_attempted, _ ->
            defer_to_the_failed_path ()
          | false, (Untried_attempted | No_untried_attempted), _ -> ());
         lane_terminal (this_candidate terminal_error)))
  in
  loop ~observed_overflow:None ~untried:No_untried_attempted 0 candidates

(* A candidate a reload removed is a binding that cannot serve, not an
   internal defect: typed as the provider's own NotFound, the lane walk
   rotates past it ([candidate_access_should_try_next]) and the failure
   route reads it as a rotation ([Model_unavailable]). As [Internal] the
   same error stopped the walk at the missing candidate with live
   candidates still untried. *)
let runtime_candidate_missing_error id =
  Agent_core.Error.Provider
    (Llm_provider.Error.NotFound
       { provider = id
       ; detail =
           Printf.sprintf
             "keeper_turn_driver: lane candidate %S disappeared from runtimes"
             id
       })

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
      let runtime_id = runtime.Runtime_instance.id in
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
   lane itself uses ([Runtime_candidate_standing.order]), and a candidate whose
   path rests until a known time ([path_rest_parts]: a rate limit, or a quota
   window its provider or usage read dated) is left out until that time: the
   reroute and the image walk lead with a serving candidate, and when no
   serving candidate takes the image the decision is [No_capable_runtime], so
   the turn degrades on the serving lane head instead of dispatching to a path
   that cannot answer yet. The resting candidate keeps its place in the lane,
   behind the serving ones, so a walk whose serving candidates all fail still
   reaches it, and at its release it leads image turns again. A quota
   observation rests until the fallback cap after it was noted, the same way.
   A deferred lane offers no candidates: it dispatches the resumed walk
   ordered before pre-dispatch ([lane_candidate_ids] in [run_agent_turn]), so a
   decision that moved the head would be recorded as a reroute the walk never
   performs. *)
let modality_reroute_candidates ~now ~walk ~deferred_runtime_lane ~first_candidate
    ~remaining_runtimes =
  match deferred_runtime_lane with
  | Some _ -> []
  | None ->
    dedupe_runtimes_preserve_order (first_candidate :: remaining_runtimes)
    |> Runtime_candidate_standing.order
         ~now
         ~policy:(keeper_walk walk)
         ~quota_scope_of:(fun (runtime : Runtime_instance.t) ->
           Some (Runtime_instance.quota_scope_of_runtime runtime))
         ~candidate_backpressure_of:(fun (runtime : Runtime_instance.t) ->
           Some runtime.Runtime_instance.candidate_backpressure)
    |> List.filter (fun runtime ->
      not
        (List.exists
           (fun { ends_at; set_by = _ } -> Float.compare now ends_at < 0)
           (path_rest_parts ~now runtime)))

(* The media walk (every serving lane candidate that takes the media, live ones
   first), then the rest of the lane in its given order as the degrade tail,
   where per-attempt projection turns the image into a reading. A text turn has
   an empty media walk and walks the lane as given.

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
      target.Runtime_instance.id
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
    ?project_media
    ~media_store
    ~project_images
    ~keeper_name
    ~(emit_runtime_manifest :
       ?status:string ->
       ?decision:Yojson.Safe.t ->
       Keeper_runtime_manifest.event_kind ->
       unit)
    ~goal_blocks
    ~goal_metadata
    ~initial_messages
    ~agent_core_checkpoint
    ~runtime_id
    (runtime : Runtime_instance.t) =
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
    (* H5: audio and documents this candidate cannot take become
       attachment-bound readings (or an explicit unavailable marker) before the
       generic strip, so a text fallback keeps the fact and its provenance. *)
    let needs_media_projection = function
      | Keeper_media_reading.Audio -> not caps.supports_audio_input
      | Keeper_media_reading.Document -> not caps.supports_multimodal_inputs
    in
    let project_media =
      match project_media with
      | Some project -> project
      | None ->
        (* No reader is wired for a caller that supplied none: attachments are
           marked unavailable rather than read. The production walk in
           [run_named] passes one projector with the real readers for the
           whole walk. *)
        let projector =
          Keeper_media_reading.projector
            ~media_store
            ~keeper_name
            ~start_deadline:media_reading_deadline
            ~read:(fun ~deadline:_ ~kind:_ ~media_type:_ ~bytes:_ -> Error "no_reader")
            ()
        in
        Keeper_media_reading.project projector
    in
    let media_projected = ref [] in
    let project_media_blocks blocks =
      let projected, counts =
        project_media ~needs_projection:needs_media_projection blocks
      in
      media_projected := Runtime_agent.merge_modality_counts !media_projected counts;
      projected
    in
    let projected_goal =
      { projected_goal with blocks = project_media_blocks projected_goal.blocks }
    in
    let projected_initial =
      List.map
        (fun (message : Agent_core.Types.message) ->
          { message with content = project_media_blocks message.content })
        projected_initial
    in
    let projected_checkpoint =
      match projected_checkpoint with
      | None -> None
      | Some (checkpoint : Agent_core.Checkpoint.t) ->
        Some
          { checkpoint with
            messages =
              List.map
                (fun (message : Agent_core.Types.message) ->
                  { message with content = project_media_blocks message.content })
                checkpoint.messages
          }
    in
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
     | None when delegated_images = 0 && !media_projected = [] ->
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
       (match note, !media_projected with
        | None, (_ :: _ as projected) ->
          Log.Keeper.info
            "%s: media projected on %s -- %s become attachment readings or \
             unavailable markers, continuing text-only"
            keeper_name runtime_id (modality_counts_summary projected);
          emit_runtime_manifest
            ~status:"degraded"
            ~decision:(media_projection_manifest_decision ~runtime_id projected)
            Keeper_runtime_manifest.Runtime_routed
        | _ -> ());
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
             Agent_core.Types.make_message
               ~metadata:goal_metadata
               ~role:Agent_core.Types.User
               (List.map
                  (function
                    | Agent_core.Types.Text text ->
                      Agent_core.Types.Text (Llm_provider.Utf8_sanitize.sanitize text)
                    | (Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _ | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _) as block -> block)
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

let muse_native_workspace ~base_path ~keeper_name ~required_native_posture ~account_home =
  let config_error detail = Keeper_official_client_host.config_error
      ~field:"muse.native_workspace" detail in
  let* profile = match required_native_posture with
    | Some _ -> Ok None
    | None ->
      let* defaults = Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
          ~base_path keeper_name
        |> Result.map_error (fun error -> config_error
          (Keeper_types_profile.keeper_toml_load_error_to_string error)) in
      (match defaults.sandbox_profile with
       | Some profile -> Ok (Some profile)
       | None -> Error (config_error "Muse requires an explicit Keeper sandbox profile")) in
  let private_workspace () =
    let* root = Runtime_muse_home.prepare_native_workspace
        ~runtime_root:(Common.masc_dir_from_base_path ~base_path) ~keeper_name ~account_home
      |> Result.map_error (fun error -> config_error (Runtime_muse_home.error_to_string error)) in
    (* The Keeper's session claim admits one turn at a time, so no other
       session of this Keeper writes the directory between this read and the
       host's start. *)
    let* origin =
      Eio_guard.run_in_systhread ~label:"muse-native-workspace-read" (fun () ->
        Runtime_muse_serve.origin_of_masc_directory root)
      |> Result.map_error config_error in
    (match origin with
     | Runtime_muse_serve.Masc_private -> ()
     | Runtime_muse_serve.Other_tree ->
       Log.Keeper.warn ~keeper_name
         "Muse private workspace %s holds files, so the host starts without \
          workspace trust and does not connect the MASC tools"
         root);
    Ok (root, origin,
      "Muse native tools use a separate private host workspace. They cannot access the Keeper's endpoint-owned tree. Use MASC tools for that tree; native commands run in the official client's host sandbox.") in
  let shared_workspace profile =
    try
      (* See the SSOT root resolution below; only directory creation is needed here. *)
      ignore (Keeper_alerting_path.ensure_sandbox_bundle_for_profile
        ~config:(Workspace.default_config base_path) ~name:keeper_name
        ~sandbox_profile:profile : string list);
      let selected = Filename.concat base_path
          (Keeper_sandbox.host_root_rel_of_profile profile keeper_name)
        |> Env_config_core.strip_trailing_slashes in
      let canonical = Unix.realpath selected in
      if not (String.equal selected canonical)
      then Error (config_error "native workspace must not traverse symbolic links")
      else Ok (canonical, Runtime_muse_serve.other_tree, Printf.sprintf
        "Muse native tools use host workspace %s, sharing files with MASC tools at %s. Native commands run in the official client's host sandbox, not the Keeper container."
        canonical (Keeper_sandbox.container_root keeper_name))
    with
    | Sys_error detail -> Error (config_error detail)
    | Unix.Unix_error (error, _, _) -> Error (config_error (Unix.error_message error)) in
  match profile with
  | None -> private_workspace ()
  | Some profile ->
    (match Keeper_types_profile_sandbox.tree_location_of_profile profile with
     | Shared_mount -> shared_workspace profile
     | Endpoint_owned -> private_workspace ())
;;

(* The client and its bounds as the runtime declares them. Keeper_muse_runtime
   replaces [native] with the keeper's resolved posture, [timeout_s] with a
   per-model [turn-timeout-s] on every turn, and passes the model's reasoning effort to the turn
   itself, so the values set here are the ones a turn keeps when nothing is
   declared. *)
let muse_serve_client_config (execution : Runtime_execution.muse_serve)
  : Runtime_muse_serve.config
  =
  { (Runtime_muse_serve.default_config ()) with
    cli_path = execution.cli_path
  ; model = Some execution.model
  ; native = Runtime_native_tools.muse_default
  ; admission_timeout_s = execution.timeout_s
  ; timeout_s = Some execution.timeout_s
  }
;;

(* Whether an official client's attempt error says the binding sent nothing.
   [Attempt_rejected] is itself that witness: the binding refused the
   prepared request before sending it ([Retry.invalid_request_reason]). An
   official client returns it from its own pre-turn admission, such as a
   Claude Code auth probe that failed (#47787). Every other error keeps the
   conservative [Dispatched]. Constructors are listed so a new one has to be
   judged here. *)
let official_client_error_dispatch (error : Agent_core.Error.t) =
  match error with
  | Agent_core.Error.Api
      (Llm_provider.Retry.InvalidRequest { reason = Llm_provider.Retry.Attempt_rejected; _ }) ->
    Keeper_attempt_dispatch.Rejected_before_dispatch
  | Agent_core.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { reason =
             ( Llm_provider.Retry.Json_parse_error
             | Llm_provider.Retry.Request_body_refused_by_provider _
             | Llm_provider.Retry.Refusal_body_not_received
             | Llm_provider.Retry.Unknown_invalid_request )
         ; _
         })
  | Agent_core.Error.Api
      ( Llm_provider.Retry.RateLimited _
      | Llm_provider.Retry.Overloaded _
      | Llm_provider.Retry.ServerError _
      | Llm_provider.Retry.AuthError _
      | Llm_provider.Retry.AuthorizationError _
      | Llm_provider.Retry.PaymentRequired _
      | Llm_provider.Retry.NotFound _
      | Llm_provider.Retry.ContextOverflow _
      | Llm_provider.Retry.InputCapacity _
      | Llm_provider.Retry.NetworkError _
      | Llm_provider.Retry.Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Media _
  | Agent_core.Error.Internal _
  | Agent_core.Error.Internal_carried _ -> Keeper_attempt_dispatch.Dispatched

(* An official-client lane cannot apply a provider config transform, so a
   transform on such a lane is refused before the client is invoked. *)
let official_client_dispatch ~provider_config_transform result =
  match provider_config_transform, result with
  | Some _, _ -> Keeper_attempt_dispatch.Rejected_before_dispatch
  | None, Ok _ -> Keeper_attempt_dispatch.Dispatched
  | None, Error error ->
    if Option.is_some (Keeper_internal_error.guidance_preparation_failure error)
    then Keeper_attempt_dispatch.Rejected_before_dispatch
    else official_client_error_dispatch error

(* Whether any request of this attempt reached a provider. The pre-dispatch
   serialization observer fires just before a request leaves, after the
   pipeline's own checks, so when it never fired no provider saw the attempt.
   The shape then only says who refused it: the pipeline's route stage refuses
   a request it will not send with [Attempt_rejected] (no output ceiling, an
   invalid prepared request), [InputCapacity] (a serving constraint it can
   judge locally), [ContextOverflow] (a window it counted locally) or
   [InvalidConfig] (no or an invalid declared context limit), and the media
   store refuses one whose history media it cannot read or keep ([Media]: a
   local store, so no provider saw it). A provider gives
   the same capacity shapes only after a request went out, so they pair with a
   fired observer. Any other error with no request out, such as a failed
   token-count round trip, may have reached the provider and stays dispatched.
   One attempt can send several requests, so a refusal after an earlier one
   went out is dispatched too. *)
let provider_attempt_dispatch ~request_serialized result =
  match request_serialized, result with
  | ( false
    , Error
        ( Agent_core.Error.Api
            ( Llm_provider.Retry.InvalidRequest
                { reason = Llm_provider.Retry.Attempt_rejected; _ }
            | Llm_provider.Retry.InputCapacity _
            | Llm_provider.Retry.ContextOverflow _ )
        | Agent_core.Error.Config (Agent_core.Error.InvalidConfig _)
        | Agent_core.Error.Media _ ) ) ->
    Keeper_attempt_dispatch.Rejected_before_dispatch
  | ( (true | false)
    , ( Ok _
      | Error
          (Agent_core.Error.Api
             ( Llm_provider.Retry.RateLimited _
             | Llm_provider.Retry.Overloaded _
             | Llm_provider.Retry.ServerError _
             | Llm_provider.Retry.AuthError _
             | Llm_provider.Retry.AuthorizationError _
             | Llm_provider.Retry.PaymentRequired _
             | Llm_provider.Retry.NotFound _
             | Llm_provider.Retry.NetworkError _
             | Llm_provider.Retry.Timeout _ )) ) )
  | ( true
    , Error
        (Agent_core.Error.Api
           ( Llm_provider.Retry.InvalidRequest _
           | Llm_provider.Retry.InputCapacity _
           | Llm_provider.Retry.ContextOverflow _ )) )
  | ( false
    , Error
        (Agent_core.Error.Api
           (Llm_provider.Retry.InvalidRequest
              { reason =
                  ( Llm_provider.Retry.Json_parse_error
                  | Llm_provider.Retry.Request_body_refused_by_provider _
                  | Llm_provider.Retry.Refusal_body_not_received
                  | Llm_provider.Retry.Unknown_invalid_request )
              ; _
              })) )
  | ((true | false), Error (Agent_core.Error.Provider _))
  | ((true | false), Error (Agent_core.Error.Agent _))
  | ((true | false), Error (Agent_core.Error.Mcp _))
  | ( (true | false)
    , Error
        (Agent_core.Error.Config
           ( Agent_core.Error.MissingEnvVar _
           | Agent_core.Error.UnsupportedProvider _
           | Agent_core.Error.CredentialUnavailable _
           | Agent_core.Error.SensitiveValueInConfig _ )) )
  | (true, Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig _)))
  | ((true | false), Error (Agent_core.Error.Serialization _))
  | ((true | false), Error (Agent_core.Error.Io _))
  | ((true | false), Error (Agent_core.Error.Orchestration _))
  | (true, Error (Agent_core.Error.Media _))
  | ((true | false), Error (Agent_core.Error.Internal _))
  | ((true | false), Error (Agent_core.Error.Internal_carried _)) -> Keeper_attempt_dispatch.Dispatched

(* Where an official client's carried range begins when no seed or
   Librarian position is later (RFC keeper-context-window-in-tokens §13.4).
   Only a session trace names the last completed turn on this history, so a
   turn without one does not know where it began, and the carried-front
   model sends the newest atom alone for that
   ([Keeper_carried_front.Turn_boundary_unknown]) rather than everything: a
   short range costs one turn of context, the whole history costs the turn.
   [Turn_boundary { end_atom = 0 }] means a history with no completed turn,
   which is not what these turns know. *)
let official_client_turn_start ~session_id ~read_boundary =
  match session_id with
  | Some _ -> read_boundary ()
  | None ->
    Keeper_carried_front.Turn_boundary_unknown
      { reason = "no session trace names the last completed turn" }
;;

(* Native recovery evidence can close the retry boundary, but cannot erase an
   effect already observed by the selected runtime adapter. *)
let observe_native_attempt ?on_request_observation binding run ~idx ~runtime_id candidate =
  let observed = ref false in
  let on_request_evidence = Option.map (fun observe evidence ->
    observed := true;
    observe {Request_observation.runtime_profile=runtime_id;attempt=idx;evidence})
    on_request_observation in
  let result, checkpoint, effect_disposition, dispatch = run ?on_request_evidence ~idx ~runtime_id candidate in
  if not !observed then Option.iter (fun observe ->
    let checkpoint_owner = match candidate with
      | Resolved_runtime runtime ->
        Some (Runtime_execution.checkpoint_owner runtime.Runtime_instance.execution)
      | Missing_runtime _ -> None in
    observe (Keeper_direct_native_continuation.unreported_request_evidence
      ~binding ~dispatch ~checkpoint_owner)) on_request_evidence;
  let effect_disposition = match binding, effect_disposition with
    | Some binding, Keeper_provider_attempt_effect.No_effect_observed ->
      Keeper_direct_native_continuation.binding_effect_observation ~binding
    | None, _
    | Some _, (Keeper_provider_attempt_effect.Effect_attempted
              | Keeper_provider_attempt_effect.Observation_unavailable) -> effect_disposition in
  result, checkpoint, effect_disposition, dispatch
;;

let run_named
    ~runtime_id
    ?(keeper_name = "")
    ~walk_owner
    ?pre_tool_rejects
    ~base_path
    ~media_store
    ~goal
    ?goal_blocks
    ?(goal_metadata = [])
    ~input_source
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
    ?(loading_plan = Keeper_official_client_host.All_on_demand)
    ~agent_core_tools
    ?project_for_runtime
    ?(tool_requirement = Keeper_required_tools.Optional)
    ?required_native_posture
    ?(initial_messages = [])
    ?argument_demotion_seed
    ?(history_at_start = Keeper_turn_boundaries.Continued_history)
    ?model_input_projection
    ?temperature
    ?(accept = fun (_ : Agent_core.Types.api_response) -> true)
    ?hooks
    ?approval_gate
    ~raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?transport
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?checkpoint_sink
    ?context_injector
    ?context
    ?(terminal_effect_state = fun () -> Keeper_tools_agent_core.Terminal_effect_open)
    ?enable_thinking
    ?cooperative_yield_probe
    ?agent_core_checkpoint
    ?native_binding
    ?(continue_from_checkpoint = false)
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?on_request_wire_observation
    ?on_request_attribution
    ?official_client_continuation
    ?on_checkpoint_prepared
    ?official_task_reference
    ?direct_scope
    ?official_client_composed_context
    ?on_official_client_tool_boundary
    ?on_child_content_observation
    ?on_native_task_observation
    ?on_provider_retry
    ?on_native_tool_progress
    ?on_native_tool_completion
    ?on_tool_execution
    ?on_official_client_result_handoff
    ?on_official_client_native_action
    ?on_official_client_usage_report
    ?on_model_input_window_observation
    ?on_response_observed_model_input
    ?on_refused_model_input
    ?carried_front_seed
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?deferred_runtime_lane
    ?on_memory_capacity_refusal
    ?on_runtime_attempt
    ?on_request_observation
    ?on_request_execution_ready
    ?runtime_retry_deferral
    ?checkpoint_progress
    ?attempt_continuation
    ?on_runtime_attempt_error
    ?on_runtime_lane_terminal_error
    ?on_deferred_runtime_consumed
    ?(output_contract = Provider_default)
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (named_run_result, Agent_core.Error.t) result =
  Runtime_response_identity_scope.without_identity (fun () ->
  let session_id = Keeper_request_source.trace_id input_source in
  (* A run that serves no chat execution has no owner among the receipts. *)
  let outbox_viewer = match direct_scope with
    | None -> Keeper_client_tool_outbox.Unowned_only
    | Some scope -> Keeper_client_tool_outbox.Owner_and_unowned scope in
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
         §13.4) and the boundary before which completed arguments bind. Read
         once per turn for every lane. *)
      let turn_boundary = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        match session_id with
        | Some trace_id ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Keeper_turn_driver_try_provider.turn_start
              ~config:(Workspace.default_config base_path) ~keeper_name ~trace_id
              ~messages:initial_messages)
        | None -> Keeper_carried_front.Turn_boundary { end_atom = 0 }) in
      let official_client_turn_boundary = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        official_client_turn_start ~session_id
          ~read_boundary:(fun () -> Eio.Lazy.force turn_boundary)) in
      let continuity = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        match input_source with
        | Keeper_request_source.Completion_review -> Keeper_turn_driver_try_provider.Completion_review
        | Keeper_request_source.Keeper_history { trace_id } ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            let continuity, notes =
              Keeper_turn_driver_try_provider.read_keeper_continuity
                ~config:(Workspace.default_config base_path)
                ~keeper_name ~trace_id ~messages:initial_messages
            in
            List.iter
              (Keeper_turn_driver_try_provider.log_continuity_note ~keeper_name)
              notes;
            Keeper_turn_driver_try_provider.Keeper_history { trace_id; continuity }))
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
	      (* The front this turn moved replaces the stored seed. A runtime's
	         own stored refusal still stands beside it: the moved front can
	         sit exactly where that runtime was refused. *)
	      let refused_start =
	        match carried_front_seed with
	        | Some read -> (read ()).Keeper_carried_front.refused_start
	        | None -> None
	      in
	      { Keeper_carried_front.no_seed_read with seed = Some seed; refused_start }
	    | None ->
	      (match carried_front_seed with
	       | Some read -> read ()
	       | None -> Keeper_carried_front.no_seed_read)
	  in
	  (* The official-client branches take the continuity the Agent Core branch
	     takes ([continuity] above): one choice per turn for every lane, so a
	     fitting working state, else the Librarian's read position, is the same
	     absorbed point on both. What each lane weighs it against differs: the
	     Agent Core branch composes from the absorbed point, or from a later
	     start the provider accepted past it ([choose_range_start]), while
	     these lanes cut their start
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
	    | Keeper_turn_driver_try_provider.Completion_review ->
	      Ok Keeper_turn_driver_try_provider.no_librarian_position
	    | Keeper_turn_driver_try_provider.Keeper_history { continuity = chosen; _ } ->
	      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
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
	    (* Reached only for a range the lane sent: a Claude Code resume reports
	       no front, and composing a range logs nothing. *)
	    Keeper_official_client_host.warn_if_sent_on_unknown_start ~keeper_name front;
	    match session_id with
	    | None -> ()
	    | Some trace_id ->
	      Keeper_continuity_observation.record
	        ~config:(Workspace.default_config base_path) ~keeper_name
	        { Keeper_continuity_observation.prepared_at = Time_compat.now ()
	        ; runtime_id
	        ; input =
	            Keeper_official_client_host.continuity_observation_input
	              ~trace_id ~continuity:(match Eio.Lazy.force continuity with
                | Keeper_turn_driver_try_provider.Completion_review -> None
                | Keeper_turn_driver_try_provider.Keeper_history { continuity; _ } -> Some continuity) front
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
     selecting a fresh lane walk. A resumed walk was already ordered before
     pre-dispatch shaping ([resumed_runtime_lane]), so re-reading wall-clock
     quota state here could make the actual provider differ from the runtime
     used to shape the request. *)
  let pre_tool_rejects =
    match pre_tool_rejects with
    | Some rejects -> rejects
    | None -> ref []
  in
  let fresh_walk = fresh_walk_of walk_owner in
  let demote_quota_exhausted candidates =
    quota_ordered_runtime_ids
      (* NDT-OK: scheduling intentionally compares the stored expiry with
         wall clock; the ordering read receives one explicit [now]. *)
      ~now:(Unix.gettimeofday ())
      ~walk:fresh_walk
      candidates
  in
  let* native_runtime = match native_binding with
    | None -> Ok None
    | Some binding ->
      let* admission = Keeper_direct_native_continuation.load ~binding
        |> Result.map_error (fun detail -> Agent_core.Error.Internal detail) in
      (match admission with
       | Keeper_direct_native_continuation.No_pending -> Ok None
       | Resume resumed -> Ok (Some (Keeper_direct_native_continuation.runtime_id resumed))
       | Terminal_pending _ -> Error (Agent_core.Error.Internal
           "native terminal disposition awaits Owner settlement")) in
  let* lane_candidate_ids =
    match native_runtime with
    | Some saved_runtime ->
      let fallback = match Runtime.resolve_assignment runtime_id with
        | `Lane lane -> Runtime_lane.ordered_candidates lane |> demote_quota_exhausted
        | `Missing | `Unavailable _ -> [] in
      Ok (saved_runtime :: List.filter (fun id -> not (String.equal id saved_runtime)) fallback)
    | None -> (match output_contract, deferred_runtime_lane with
    | Tool_verdict, _ -> Ok [runtime_id]
    | Provider_default, Some hint -> Ok (resumed_walk_ids hint)
    | Provider_default, None ->
      (match Runtime.resolve_assignment runtime_id with
       | `Missing -> Ok []
       | `Unavailable missing ->
         Error (Runtime_agent_core_runner.runtime_catalog_error_to_core_error
           ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing))
       | `Lane lane -> Ok (Runtime_lane.ordered_candidates lane |> demote_quota_exhausted)))
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
  let first_candidate_id =
    match lane_candidate_ids with
    | first :: _ -> first
    | [] -> runtime_id
  in
  (* A reload between cycles can remove an id the resumed walk (or the
     fresh order) still names. Missing ids drop out of the walk instead of
     failing it: the walk rotates past them. Only when nothing resolves
     does the turn fail, with the head's own error. *)
  let resolve_opt id =
    match resolve_runtime_candidate id with Ok r -> Some r | Error _ -> None
  in
  let resolved_lane = List.filter_map resolve_opt lane_candidate_ids in
  let* first_candidate =
    match resolved_lane with
    | first :: _ ->
      (match deferred_runtime_lane, lane_candidate_ids with
       | Some _, head_id :: _
         when not (String.equal first.Runtime_instance.id head_id) ->
         (* The head rotated past ids a reload removed; the hint is spent
            the way a missing head spent it. Consume is idempotent. *)
         Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed
       | _ -> ());
      Ok first
    | [] -> (
      match resolve_runtime_candidate first_candidate_id with
      | Ok r -> Ok r
      | Error e ->
        (match deferred_runtime_lane with
         | Some _ ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed
         | None -> ());
        Error e)
  in
  let remaining_runtimes =
    match deferred_runtime_lane, resolved_lane with
    | Some _, _ -> []
    | None, _ :: rest -> rest
    | None, [] -> []
  in
  (* This decision is reported, not applied: the image walk already leads with
     the capable candidate a [Reroute] names. On a deferred lane the walk order
     was frozen before pre-dispatch shaping, so [modality_reroute_candidates]
     is [[]] and the decision can only be [No_reroute_needed] or
     [No_capable_runtime], and the image walk is empty. The media degrade
     itself is not decided here for any lane: every attempt projects the input
     against the runtime it dispatches to ([project_input_for_attempt] inside
     [run_attempt] below), because the walk crosses runtimes with different
     input capabilities and one strip bound here was right for the head only
     (#33034 fixed the deferred head; the tail still received the head's view). *)
  let reroute_candidates =
    if Option.is_some native_runtime then [] else
    match output_contract with
    | Tool_verdict -> []
    | Provider_default -> modality_reroute_candidates
      (* NDT-OK: quota windows compare a stored expiry with wall clock; the
         ordering read receives one explicit [now], as the lane's does above. *)
      ~now:(Unix.gettimeofday ())
      ~walk:fresh_walk
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
  (* What each candidate of the walk that resumes a hint is to the chain of
     turns the hint belongs to. Every candidate of any other walk is
     untried. *)
  let walk_member =
    match native_runtime, output_contract, deferred_runtime_lane with
    | None, Provider_default, Some hint -> resumed_member hint
    | Some _, (Provider_default | Tool_verdict), (Some _ | None)
    | None, Tool_verdict, (Some _ | None)
    | None, Provider_default, None -> fun (_ : string) -> Untried
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
      ~media_store
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
  (* H5: audio and document readings, like [project_images], belong to the
     walk. Every text-only candidate of this walk reuses what an earlier one
     read or failed to read, under one reading deadline. *)
  let media_projector =
    Keeper_media_reading.projector
      ~base_path
      ~media_store
      ~keeper_name
      ~start_deadline:media_reading_deadline
      ~read:
        (Keeper_media_reading.production_reader
           ~base_path
           ~budget_sec:(Keeper_runtime_resolved.provider_call_deadline_sec ()))
      ()
  in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return. *)
  attempt_runtime_candidates
    ~pre_tool_rejects
    ~walk_owner
    ?retry_deferral:runtime_retry_deferral
    ~tool_results_saved:(fun () ->
      Keeper_turn_driver_try_provider.tool_results_saved checkpoint_progress)
    ?attempt_continuation
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
      | Resolved_runtime runtime -> runtime.Runtime_instance.id
      | Missing_runtime runtime_id -> runtime_id)
    ~quota_scope_of:(function
      | Resolved_runtime runtime -> Some (Runtime_instance.quota_scope_of_runtime runtime)
      | Missing_runtime _ -> None)
    ~candidate_backpressure_of:(function
      | Resolved_runtime runtime -> Some runtime.Runtime_instance.candidate_backpressure
      | Missing_runtime _ -> None)
    ~read_usage_after_account_refusal:(function
      | Resolved_runtime runtime -> read_runtime_usage_after_account_refusal runtime
      | Missing_runtime _ -> ())
    ~candidate_dispatchable:(function
      (* A materialized snapshot stays dispatchable even if a runtime.toml
         reload removed its id from the current table; only a candidate that
         never resolved is a dead head. *)
      | Resolved_runtime _ -> true
      | Missing_runtime _ -> false)
    ~member_of:(function
      | Resolved_runtime runtime -> walk_member runtime.Runtime_instance.id
      | Missing_runtime runtime_id -> walk_member runtime_id)
    ~provider_answered:(fun (named : named_run_result) -> run_result_answered named.run_result)
    ~emit_runtime_manifest
    ~run_attempt:(observe_native_attempt ?on_request_observation native_binding (fun ?on_request_evidence ~idx ~runtime_id:attempt_runtime_id candidate ->
      let native_admission = match native_binding with
        | None -> Ok None
        | Some binding ->
          let* admission = Keeper_direct_native_continuation.load ~binding
            |> Result.map_error (fun detail -> Agent_core.Error.Internal detail) in
          (match admission with
           | Keeper_direct_native_continuation.No_pending -> Ok None
           | Resume resumed -> Ok (Some (Keeper_direct_native_continuation.runtime_id resumed))
           | Terminal_pending (_, {Agent_core.Agent.recovery=Retire; _}) -> Ok None
           | Terminal_pending (_, {Agent_core.Agent.recovery=Operator_repair_required Effect_outcome_unknown; _}) ->
             Error (Agent_core.Error.Internal "native effect outcome requires reconciliation")) in
      match native_admission with
      | Error error -> Error error, None, Keeper_provider_attempt_effect.Observation_unavailable,
          Keeper_attempt_dispatch.Rejected_before_dispatch
      | Ok native_runtime ->
      match candidate with
      | Missing_runtime runtime_id ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        ( Error (runtime_candidate_missing_error runtime_id)
        , None
        , Keeper_provider_attempt_effect.No_effect_observed
        , Keeper_attempt_dispatch.Rejected_before_dispatch )
      | Resolved_runtime runtime ->
      let accepts_image_input, tools, agent_core_tools, loading_plan =
        match project_for_runtime with
        | Some (project : Keeper_tools_agent_core.model_tool_projection) ->
          let carried = match agent_ref with
            | None -> []
            | Some cell -> (match !cell with
                | None -> []
                | Some agent -> Agent_core.Tool_set.to_list (Agent_core.Agent.tools agent)) in
          let view = project ~runtime ~carried in
          let accepts_image_input = match view.image_admission with
            | Keeper_tools_agent_core.Image_input_admitted -> true
            | Image_input_unavailable -> false in
          accepts_image_input, view.tools, view.agent_core_tools,
          Keeper_official_client_host.Declared {
            on_demand=view.on_demand_tool_names;result_bounds=view.result_bounds}
        | None ->
          let tools_on_wire = match runtime.Runtime_instance.execution, agent_ref with
            | Runtime_execution.Agent_core _, Some agent_cell ->
              Keeper_agent_tool_surface.on_the_wire ~agent_cell ~built:agent_core_tools
            | (Runtime_execution.Agent_core _, None)
            | ((Runtime_execution.Codex_app_server _ | Antigravity_cli _
                | Claude_code _ | Muse_serve _ | Vibe_cli _), _) -> agent_core_tools in
          Runtime_agent.runtime_accepts_image_input ~runtime, tools, tools_on_wire, loading_plan
      in
      (* Freeze admission with this selected candidate, including tools loaded
         later in the loop. A text-only attempt can recover through the explicit
         analysis tool without a provider error or a second implicit inference. *)
      let image_hooks =
        { Agent_core.Hooks.empty with pre_tool_use = Some
            (Keeper_image_read.admission_hook
               ~accepts_image_input) }
      in
      let hooks = Some (match hooks with
        | None -> image_hooks
        | Some hooks -> Agent_core.Hooks.compose ~outer:image_hooks ~inner:hooks)
      in
      let source_reader_ready =
        let native_ready = match native_runtime, runtime.Runtime_instance.execution with
          | None, _ -> true
          | Some saved, Runtime_execution.Agent_core _ -> String.equal saved attempt_runtime_id
          | Some _, (Runtime_execution.Codex_app_server _ | Antigravity_cli _
                    | Muse_serve _ | Claude_code _ | Vibe_cli _) -> false in
        let execution_owner_ready = match on_request_execution_ready,native_binding with
          | Some _, Some _ -> false
          | None, _ | Some _, None -> true in
        if not execution_owner_ready then Error (Agent_core.Error.Config
          (Agent_core.Error.InvalidConfig {field="on_request_execution_ready";
            detail="original-owned execution cannot replace a direct-native binding"}))
        else if not native_ready then Error (Agent_core.Error.Internal
          "native recovery requires its saved Agent Core runtime")
        else if required_native_posture = Some Runtime_native_tools.Native_none
           && not (Runtime_execution.supports_native_none runtime.Runtime_instance.execution) then
          Error (Keeper_required_tools.to_core_error
            {runtime_id=attempt_runtime_id;reason=Native_tools_cannot_be_disabled})
        else match official_client_continuation with
        | Some checkpoint when attempt_runtime_id <> checkpoint.Keeper_semantic_execution.runtime_id
            || Runtime_execution.checkpoint_owner runtime.Runtime_instance.execution <> Runtime_execution.Official_client ->
          Error (Agent_core.Error.Internal "Gate continuation must resume its original official-client runtime")
        | Some _ | None -> Ok () in
      let has_tools, surface_enabled = match runtime.Runtime_instance.execution with
        | Runtime_execution.Agent_core _ -> agent_core_tools <> [], true
        | Runtime_execution.Codex_app_server _
        | Runtime_execution.Antigravity_cli _
        | Runtime_execution.Muse_serve _ -> tools <> [], true
        | Runtime_execution.Claude_code _ -> tools <> [], runtime.model.tools_support
        | Runtime_execution.Vibe_cli _ -> tools <> [], false in
      let complete_media () =
        match Runtime_agent.decide_modality_reroute_for_runtime_candidates
          ~assigned:runtime ~candidates:[] ~checkpoint_messages ~initial_messages
          current_goal_blocks with
        | Runtime_agent.No_reroute_needed -> Ok ()
        | Runtime_agent.Reroute _ | Runtime_agent.No_capable_runtime _ ->
          Error "The admitted verifier slot cannot consume the submitted media; use another admitted slot"
      in
      let verifier_ready =
        let admission = match input_source, output_contract with
          | Keeper_request_source.Keeper_history _, Provider_default -> Ok ()
          | Keeper_request_source.Completion_review, Provider_default -> complete_media ()
          | (Keeper_request_source.Keeper_history _ | Keeper_request_source.Completion_review), Tool_verdict ->
            Result.bind (Runtime.verifier_runtime_admission runtime) complete_media
        in
        admission |> Result.map_error (fun detail -> Agent_core.Error.Config
          (Agent_core.Error.InvalidConfig { field = "verifier.runtime"; detail }))
      in
      let bind_official_owner () =
        match runtime.Runtime_instance.execution,on_request_execution_ready with
        | Runtime_execution.Agent_core _, _
        | Vibe_cli _, _
        | (Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _), None -> Ok ()
        | (Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _), Some ready ->
          ready ~runtime_id:attempt_runtime_id ~execution:Types_core.Official_session
          |> Result.map_error (fun detail -> Agent_core.Error.Config
            (Agent_core.Error.InvalidConfig {field="review.execution_owner";detail}))
      in
      let execution_ready =
        match runtime.Runtime_instance.execution with
        | Runtime_execution.Vibe_cli _ -> Error Runtime_execution.vibe_keeper_turn_refused
        | Runtime_execution.Agent_core _
        | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ -> Ok ()
      in
      let admission = Result.bind execution_ready (fun () ->
        Result.bind verifier_ready (fun () ->
        Result.bind source_reader_ready (fun () ->
          let tools_ready = Keeper_required_tools.check_surface tool_requirement
            ~runtime_id:attempt_runtime_id ~surface_enabled ~has_tools
            |> Result.map_error Keeper_required_tools.to_core_error in
          Result.bind tools_ready bind_official_owner))) in
      (match admission with
       | Error failure ->
         Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
         Error failure, None,
         Keeper_provider_attempt_effect.No_effect_observed,
         Keeper_attempt_dispatch.Rejected_before_dispatch
       | Ok () ->
      (* Native continuation already owns its input in the checkpoint. Official
         clients still need the explicit goal, including any media blocks. *)
      let goal_blocks =
        match continue_from_checkpoint, runtime.Runtime_instance.execution with
        | true, Runtime_execution.Agent_core _ -> None
        | (true, (Runtime_execution.Codex_app_server _ | (Runtime_execution.Antigravity_cli _ | (Runtime_execution.Claude_code _ | (Runtime_execution.Muse_serve _ | Runtime_execution.Vibe_cli _)))))
        | (false, _) -> goal_blocks
      in
      (* Shadows the caller's inputs with this candidate's dispatch view; the
         originals stay bound above for the next candidate's own projection. *)
      let { attempt_goal_blocks = goal_blocks
          ; attempt_initial_messages = initial_messages
          ; attempt_agent_core_checkpoint = agent_core_checkpoint
          ; attempt_replay_prefix_projection = replay_prefix_projection
          } =
        match native_runtime with
        | Some _ ->
          {attempt_goal_blocks=goal_blocks;attempt_initial_messages=initial_messages;
           attempt_agent_core_checkpoint=agent_core_checkpoint;
           attempt_replay_prefix_projection=Keeper_replay_prefix.unchanged}
        | None -> project_input_for_attempt
          ~project_media:(Keeper_media_reading.project media_projector)
          ~media_store
          ~project_images
          ~keeper_name
          ~emit_runtime_manifest
          ~goal_blocks
          ~goal_metadata
          ~initial_messages
          ~agent_core_checkpoint
          ~runtime_id:attempt_runtime_id
          runtime
      in
      Agent_core.Base.Schema_observation.with_attempt
        ~routing_run_id ~lane_attempt_index:idx ~runtime_id:attempt_runtime_id
      @@ fun () ->
      Option.iter
        (fun observe ->
           observe
             { routing_run_id
             ; runtime_id = attempt_runtime_id
             ; lane_attempt_index = idx
             ; checkpoint_owner =
                 Runtime_execution.checkpoint_owner runtime.Runtime_instance.execution
             ; tool_result_inline_ceiling_bytes =
                 Runtime_execution.tool_result_inline_ceiling_bytes runtime.Runtime_instance.execution
             ; tool_surface_enabled = surface_enabled
             ; usage_report = Runtime_execution.usage_report runtime.Runtime_instance.execution
             })
        on_runtime_attempt;
      let error_runtime_id = attempt_runtime_id in
      let official_prompt_sent_at = ref None in
      let observe_official_result ~execution_result result =
        let observation = official_client_observation
          ~keeper_name
          ?turn_id:(Option.bind runtime_manifest_context (fun context ->
            context.Keeper_runtime_manifest.manifest_keeper_turn_id))
          ~runtime_id:attempt_runtime_id
          ~prompt_sent_at:!official_prompt_sent_at ~execution_result result in
        Option.iter (fun observe -> Option.iter observe observation) on_runtime_observation;
        Result.map (fun (run_result : Runtime_agent.run_result) ->
          { run_result with runtime_observation = observation }) result
      in
      let official_model_input_observation hooks =
        let attempted = ref None in
        let transmitted_observation = ref None in
        let on_observation =
          match
            on_model_input_window_observation,
            on_response_observed_model_input,
            on_refused_model_input
          with
          | None, None, None -> None
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
        let on_transmitted_model_input transmitted =
          official_prompt_sent_at := Some (Time_compat.now ());
          match transmitted with
          | Keeper_official_client_host.Whole_input_transmitted _ ->
            transmitted_observation := !attempted
          | Keeper_official_client_host.Held_by_client_session ->
            transmitted_observation := None
        in
        (* A typed refusal answers the seed this attempt handed over. A
           resumed session sent none, so its refusal names no range
           (RFC-librarian-lifecycle §4.10). *)
        let record_refused_model_input refusal =
          let refused = !transmitted_observation in
          transmitted_observation := None;
          match on_refused_model_input, refused with
          | ( Some observe
            , Some (window : Runtime_model_input_tail_window.window_observation) ) ->
            observe
              { Turn_record.runtime_profile = attempt_runtime_id
              ; window =
                  { Turn_record.transmitted_atoms = window.transmitted_atoms
                  ; total_atoms = window.total_atoms
                  ; measurement = Turn_record.Durable_shape
                  ; model_input_front = window.model_input_front
                  }
              ; refusal
              }
          | Some _, None ->
            Log.Keeper.info
              ~keeper_name
              "model input refusal names no range runtime=%s: the request carried no \
               observed seed"
              attempt_runtime_id
          | None, (Some _ | None) -> ()
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
                                   ; model_input_front = window.model_input_front
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
            transmitted_observation := None;
            official_prompt_sent_at := None)
        , on_observation
        , on_transmitted_model_input
        , record_refused_model_input
        , hooks )
      in
      let inference_policy =
        attempt_inference_policy
          ~runtime_id:attempt_runtime_id
          ~fallback_enable_thinking:enable_thinking
          ()
      in
      let official_argument_source =
        match runtime.Runtime_instance.execution with
        | Runtime_execution.Agent_core _ | Vibe_cli _ -> None
        | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ ->
          Keeper_official_client_host.create_argument_source
            ~base_path ~keeper_name ~seed:argument_demotion_seed
            ~replay_prefix:replay_prefix_projection
            ~turn_start:(Eio.Lazy.force official_client_turn_boundary)
      in
      (match runtime.Runtime_instance.execution with
       | Runtime_execution.Agent_core _ | Vibe_cli _ -> ()
       | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ ->
         Log.Keeper.info ~keeper_name
           "model input references runtime=%s context_owner=official_client argument_source_available=%b"
           attempt_runtime_id
           (Option.is_some official_argument_source));
      let guidance_entry = ref false in
      let on_guidance_prepared () =
        let open Result.Syntax in
        let* () = match on_checkpoint_prepared with None -> Ok () | Some enter -> enter () in
        guidance_entry := true;
        Ok () in
      let guidance_result result =
        if !guidance_entry then Result.map_error Keeper_internal_error.without_guidance_preparation_authority result
        else result in
      match runtime.Runtime_instance.execution with
      | Runtime_execution.Vibe_cli _ ->
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        ( Error Runtime_execution.vibe_keeper_turn_refused
        , None
        , Keeper_provider_attempt_effect.No_effect_observed
        , Keeper_attempt_dispatch.Rejected_before_dispatch )
      | Runtime_execution.Codex_app_server config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , _record_refused_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_codex ~initial_messages () =
          match
            authorize_account walk_owner ~runtime_id:attempt_runtime_id config.account_home
          with
          | Error error ->
            { Keeper_codex_runtime.result = Error error
            ; pending_result_receipts = None
            ; settled_session = None
            ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed
            ; successful_tool_completion = Keeper_codex_runtime.No_successful_tool_completion
            }
          | Ok account ->
          reset_model_input_observation ();
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_codex_runtime.run ~on_guidance_prepared ~input_source ~media_store ?on_native_tool_completion ?on_native_tool_progress
            ?argument_source:official_argument_source
            ?on_memory_capacity_refusal
            ?on_tool_execution
            ~context_window:(Some (Runtime_instance.max_context_of_runtime runtime))
            ~configured_reasoning_effort:runtime.model.reasoning_effort
            ~turn_timeout_s:runtime.model.turn_timeout_s
            ?composed_context:official_client_composed_context
            ~accepts_image_input
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force official_client_turn_boundary)
            ~pre_tool_rejects
            ~base_path
            ~outbox_viewer
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~loading_plan
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
            ?on_usage_report:on_official_client_usage_report
            ~event_bus
            ~raw_trace
            ~on_event
            ~account
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
            ; pending_result_receipts = None
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
               | Runtime_agent.Completed _, [ Llm_provider.Types.Text text ]
                 when String.trim text = "" ->
                 Ok run_result
               | ( Runtime_agent.Completed _
                 | Runtime_agent.Yielded_to_durable_stimulus _
                 | Runtime_agent.InputRequired _ ),
                 ([]
                 | Llm_provider.Types.Text _ :: _
                 | ( Llm_provider.Types.Thinking _
                   | Llm_provider.Types.ReasoningDetails _
                   | Llm_provider.Types.RedactedThinking _
                   | Llm_provider.Types.ToolUse _
                   | Llm_provider.Types.ToolResult _
                   | Llm_provider.Types.Image _
                   | Llm_provider.Types.Document _
                   | Llm_provider.Types.Audio _ )
                   :: _) ->
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
        let codex_result = settle_accepted_official_client_results
          ~pending_result_receipts:codex_attempt.pending_result_receipts codex_result in
        let codex_result = observe_official_result
          ~execution_result:codex_attempt.result codex_result in
        let codex_result = guidance_result codex_result in
        ( selected_runtime_result ?official_client_settlement:codex_attempt.settled_session runtime ~lane_attempt_index:idx codex_result
        , None
        , codex_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform codex_result )
      | Runtime_execution.Antigravity_cli config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , _record_refused_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_antigravity ~initial_messages () =
          match authorize_host_account Runtime_account_access.Antigravity with
          | Error error ->
            { Keeper_antigravity_runtime.result = Error error
            ; pending_result_receipts = None
            ; settled_session = None
            ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed }
          | Ok host ->
          reset_model_input_observation ();
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_antigravity_runtime.run ~on_guidance_prepared ~input_source ?on_native_tool_completion
            ~host
            ~configured_reasoning_effort:runtime.model.reasoning_effort
            ~turn_timeout_s:runtime.model.turn_timeout_s
            ?argument_source:official_argument_source
            ?on_tool_execution
            ?composed_context:official_client_composed_context
            ~accepts_image_input
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force official_client_turn_boundary)
            (* Antigravity's CLI assembles the wire, so the shape masc can
               report is the list it handed over. *)
            ?on_model_input_window_observation:
              on_model_input_window_observation
            ~pre_tool_rejects
            ~base_path
            ~outbox_viewer
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~loading_plan
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
            ?on_usage_report:on_official_client_usage_report
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
            ; pending_result_receipts = None
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
        let antigravity_result = settle_accepted_official_client_results
          ~pending_result_receipts:antigravity_attempt.pending_result_receipts antigravity_result in
        let antigravity_result = observe_official_result
          ~execution_result:antigravity_attempt.result antigravity_result in
        let antigravity_result = guidance_result antigravity_result in
        ( selected_runtime_result ?official_client_settlement:antigravity_attempt.settled_session runtime ~lane_attempt_index:idx antigravity_result
        , None
        , antigravity_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform antigravity_result )
      | Runtime_execution.Muse_serve execution ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , record_refused_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_muse ~initial_messages () =
          match
            authorize_muse_account walk_owner ~runtime_id:attempt_runtime_id
              execution.account_home
          with
          | Error error ->
            { Keeper_muse_runtime.result = Error error
            ; pending_result_receipts = None
            ; settled_session = None
            ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed }
          | Ok account ->
          reset_model_input_observation ();
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          let workspace = muse_native_workspace ~base_path ~keeper_name
              ~required_native_posture
              ~account_home:(Runtime_account_access.declared_muse_home account) in
          match workspace with
          | Error error ->
            { Keeper_muse_runtime.result = Error error
            ; pending_result_receipts = None
            ; settled_session = None
            ; effect_disposition = Keeper_provider_attempt_effect.No_effect_observed }
          | Ok (workspace_root, workspace_origin, native_context) ->
          Keeper_muse_runtime.run ~on_guidance_prepared ~input_source ~media_store
            ~on_model_input_refused:record_refused_model_input
            ?on_native_tool_completion
            ?argument_source:official_argument_source
            ?on_tool_execution
            ?composed_context:official_client_composed_context
            ~configured_reasoning_effort:runtime.model.reasoning_effort
            ~turn_timeout_s:runtime.model.turn_timeout_s
            ~quota_scope:runtime.quota_scope
            ~workspace_root
            ~workspace_origin
            ~accepts_image_input
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force official_client_turn_boundary)
            (* [muse serve] assembles the wire from one rendered prompt, so the
               shape masc can report is the list it handed over. *)
            ?on_model_input_window_observation:
              on_model_input_window_observation
            ~pre_tool_rejects
            ~base_path
            ~outbox_viewer
            ~goal
            ~goal_blocks
            ~native_workspace_context:native_context
            ~system_prompt
            ~tools
            ~loading_plan
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
            ?on_usage_report:on_official_client_usage_report
            ~event_bus
            ~raw_trace
            ~on_event
            ~account
            ~config:(muse_serve_client_config execution)
            ()
        in
        let muse_attempt =
          match provider_config_transform, agent_core_checkpoint with
          | Some _, _ ->
            { Keeper_muse_runtime.result =
                Error
                  (Agent_core.Error.Config
                     (Agent_core.Error.InvalidConfig
                        { field = "provider_config_transform"
                        ; detail =
                            "provider config transforms cannot target a muse-serve runtime"
                        }))
            ; pending_result_receipts = None
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
            run_muse ~initial_messages ()
          | None, None -> run_muse ~initial_messages ()
        in
        Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
        let muse_result =
          Result.bind muse_attempt.result (fun run_result ->
            apply_official_client_accept
              ~runtime_id:attempt_runtime_id
              ~accept
              ~terminal_effect_state
              run_result)
        in
        let muse_result = settle_accepted_official_client_results
          ~pending_result_receipts:muse_attempt.pending_result_receipts muse_result in
        let muse_result = observe_official_result
          ~execution_result:muse_attempt.result muse_result in
        let muse_result = guidance_result muse_result in
        ( selected_runtime_result ?official_client_settlement:muse_attempt.settled_session runtime ~lane_attempt_index:idx muse_result
        , None
        , muse_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform muse_result )
      | Runtime_execution.Claude_code config ->
        let ( reset_model_input_observation
            , on_model_input_window_observation
            , record_transmitted_model_input
            , _record_refused_model_input
            , hooks ) =
          official_model_input_observation hooks
        in
        let run_claude ~initial_messages () =
          match
            authorize_account walk_owner ~runtime_id:attempt_runtime_id config.account_home
          with
          | Error error -> {Keeper_claude_code_runtime.result=Error error;
              pending_result_receipts=None;settled_session=None;
              effect_disposition=Keeper_provider_attempt_effect.No_effect_observed}
          | Ok account ->
          match on_guidance_prepared () with
          | Error error -> {Keeper_claude_code_runtime.result=Error error;
              pending_result_receipts=None;settled_session=None;
              effect_disposition=Keeper_provider_attempt_effect.No_effect_observed}
          | Ok () ->
          reset_model_input_observation ();
          let tools = if runtime.model.tools_support then tools else [] in
          let on_transmitted_model_input transmitted =
            record_transmitted_model_input transmitted;
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          let native_attempt : Runtime_native_tasks.attempt =
            { routing_run_id; runtime_id = attempt_runtime_id; lane_attempt_index = idx } in
          Keeper_claude_code_runtime.run ~input_source ~media_store ?on_native_tool_progress ?on_native_tool_completion
            ~configured_reasoning_effort:runtime.model.reasoning_effort
            ~turn_timeout_s:runtime.model.turn_timeout_s
            ?argument_source:official_argument_source
            ?on_provider_retry:(Option.map
              (fun observe retry -> observe ~attempt:native_attempt retry)
              on_provider_retry)
            ?on_memory_capacity_refusal
            ?on_child_content_observation:(Option.map
              (fun observe observation -> observe ~attempt:native_attempt observation)
              on_child_content_observation)
            ?on_native_task_observation:(Option.map
              (fun observe bound -> observe ~attempt:native_attempt bound)
              on_native_task_observation)
            ?on_tool_execution
            ?composed_context:official_client_composed_context
            ~accepts_image_input
            ?required_native_posture
            ~runtime_id:attempt_runtime_id
            ~keeper_name
            ~carried_front_seed:official_client_carried_front_seed
            ~librarian_front:
              (official_client_librarian_front ~attempt_messages:initial_messages)
            ~on_carried_front:(record_official_client_continuity ~runtime_id:attempt_runtime_id)
            ~turn_start:(Eio.Lazy.force official_client_turn_boundary)
            ~pre_tool_rejects
            ~base_path
            ~outbox_viewer
            ~goal
            ~goal_blocks
            ~system_prompt
            ~tools
            ~loading_plan
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
            ?on_usage_report:on_official_client_usage_report
            ~event_bus
            ~raw_trace
            ~on_event
            ~account
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
            ; pending_result_receipts = None
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
        let claude_result = settle_accepted_official_client_results
          ~pending_result_receipts:claude_attempt.pending_result_receipts claude_result in
        let claude_result = observe_official_result
          ~execution_result:claude_attempt.result claude_result in
        ( selected_runtime_result ?official_client_settlement:claude_attempt.settled_session runtime ~lane_attempt_index:idx claude_result
        , None
        , claude_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform claude_attempt.result )
      | Runtime_execution.Agent_core sealed ->
       (* Held to this candidate's own rendering of the history, for the
          reason [official_client_librarian_front] states. *)
       let request_input = match Eio.Lazy.force continuity with
         | Keeper_turn_driver_try_provider.Completion_review ->
           Keeper_turn_driver_try_provider.Completion_review
         | Keeper_turn_driver_try_provider.Keeper_history { trace_id; continuity } ->
           Keeper_turn_driver_try_provider.Keeper_history
             { trace_id; continuity = Keeper_turn_driver_try_provider.continuity_for_attempt
                 ~messages:initial_messages continuity }
       in
       (match
          match authorize_api_provider sealed with
          | Error _ as refused -> refused
          | Ok runtime_provider_config ->
            (match provider_config_transform with
             | None -> Ok runtime_provider_config
             | Some transform -> transform runtime_provider_config)
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
            tool_requirement
            ~runtime_id:attempt_runtime_id provider_config with
         | Error failure ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
           Error (Keeper_required_tools.to_core_error failure), None,
           Keeper_provider_attempt_effect.No_effect_observed,
           Keeper_attempt_dispatch.Rejected_before_dispatch
         | Ok () ->
        (match
           Runtime_instance.validate_dispatch_credential ~provider_config runtime
         with
         | Error credential_error ->
           Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
           ( Error
               (Runtime_instance.dispatch_credential_error_to_core_error credential_error)
           , None
           , Keeper_provider_attempt_effect.No_effect_observed
           , Keeper_attempt_dispatch.Rejected_before_dispatch )
         | Ok () ->
          (
            let candidate = Runtime_candidate.of_provider_config provider_config in
            (* Cached provider health is observation only. Every eligible runtime
               reaches the real provider boundary; only the resulting typed error
               may drive fallback. *)
            let name = Printf.sprintf "agent_core-%s" attempt_runtime_id in
          let request_serialized = ref false in
          let on_request_wire_observation =
            Some
              (fun ~runtime_id ~body_bytes ~serialized ~projected_messages ->
                 request_serialized := true;
                 Option.iter
                   (fun observe -> observe ~runtime_id ~body_bytes ~serialized ~projected_messages)
                   on_request_wire_observation)
          in
          let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx =
            { runtime_id = attempt_runtime_id
            ; input_runtime = Some runtime
            ; error_runtime_id
            ; turn_boundary = Eio.Lazy.force turn_boundary
            ; history_at_start
            ; argument_demotion_seed
            ; argument_replay_prefix = replay_prefix_projection
            ; request_input
            ; (* The range the newest response-observed turn record on this
                 history measured, whichever runtime ran it. Without a
                 Librarian point it is read only when the process holds no
                 ledger for this pair, so a restart or a lane's next
                 candidate resumes the range the last turn carried rather
                 than this turn's own boundary. With one it is the accepted
                 start the point yields to when it lies past the point (RFC
                 librarian-lifecycle §4.10). A caller that reads no records
                 leaves the first request to that boundary, or to the
                 point. *)
              carried_front_seed =
                (fun () ->
                   match carried_front_seed with
                   | Some read -> read ()
                   | None -> Keeper_carried_front.no_seed_read)
            ; carried_front_after_refusal = (fun () -> !refused_carried_front)
            ; hold_carried_front = (fun seed -> refused_carried_front := Some seed)
            ; restore_carried_front = (fun prior -> refused_carried_front := prior)
            ; base_path
            ; outbox_viewer
            ; media_store
            ; keeper_name
            ; name
            ; goal
            ; goal_blocks
            ; goal_metadata
            ; system_prompt
            ; (* Only this lane can widen a running turn, so only this lane
                 is handed the listing. The official-client branches above
                 take [tools] whole. A caller that named no lane view is not
                 deferring anything, so this lane sends every tool too --
                 which is what every caller did before the listing existed. *)
              tools = agent_core_tools
            ; initial_messages
            ; model_input_projection
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
            ; temperature
            ; accept
            ; hooks
            ; approval_gate
            ; raw_trace
            ; transport_resolved
            ; checkpoint_sidecar
            ; cache_system_prompt
            ; checkpoint_sink =
                Option.map
                  (Keeper_attempt_checkpoint.canonical_sink ~projection:replay_prefix_projection)
                  checkpoint_sink
            ; checkpoint_progress
            ; context_injector
            ; context
            ; enable_thinking = inference_policy.attempt_enable_thinking
            ; preserve_thinking = inference_policy.attempt_preserve_thinking
            ; cooperative_yield_probe
            ; agent_core_checkpoint
            ; on_request_evidence
            ; on_request_execution_ready
            ; native_binding
            ; native_retired_history_cut = None
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
          (match on_guidance_prepared () with
           | Error error -> Error error, None, Keeper_provider_attempt_effect.No_effect_observed,
               Keeper_attempt_dispatch.Rejected_before_dispatch
           | Ok () ->
          Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
          let provider_result, checkpoint_after, _success_sample =
            Keeper_turn_driver_try_provider.run_try_provider_with_truncation_recovery
              ?on_memory_capacity_refusal
              ?continuation_checkpoint:
                (if continue_from_checkpoint then agent_core_checkpoint else None)
              try_provider_ctx candidate
          in
          let { Keeper_attempt_checkpoint.turn_result; checkpoint_after } =
            Keeper_attempt_checkpoint.project ?checkpoint_after
              ~projection:replay_prefix_projection provider_result in
          ( selected_runtime_result runtime ~lane_attempt_index:idx turn_result
          , checkpoint_after
          , Keeper_provider_attempt_effect.No_effect_observed
          , provider_attempt_dispatch ~request_serialized:!request_serialized
              turn_result )))))
       ))))
    attempt_candidates)


module For_testing = struct
  let official_client_turn_start = official_client_turn_start

  let run_result_answered = run_result_answered

  let make_deferred_runtime_lane ~assignment_id ~failed_runtime_id
        ~next_runtime_id ~later_runtime_ids ~failure =
    restore_deferred_runtime_lane ~assignment_id ~failed_runtime_id
      ~next_runtime_id ~later_runtime_ids ~failure
  ;;

  let resumed_member = resumed_member

  let checkpoint_after_attempt = checkpoint_after_attempt
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
  let official_client_dispatch = official_client_dispatch
  let provider_attempt_dispatch = provider_attempt_dispatch
  let official_client_observation = official_client_observation
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

  let lane_should_retry = lane_should_retry

end
