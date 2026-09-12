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

type runtime_selection = Resolve_assignment | Exact_runtime | Exact_route

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
  { routing_run_id : string
  ; runtime_id : string
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
  }

(* Quota demotion must never promote a candidate the runtime table cannot
   resolve (for example one removed by a runtime.toml reload while a deferred
   suffix was frozen): a missing id at the head fails the attempt with a
   non-rotating error before resolvable alternatives are tried. Order is
   therefore resolvable-active, then resolvable-exhausted, then unresolvable —
   declared relative order preserved within each class (PR #28219 review). *)
let demote_unavailable_candidates ~now ~quota_scope_of ~candidate_preference_of candidates =
  let available, backpressured = List.partition (fun candidate ->
    let quota_exhausted =
      Option.fold ~none:false
        ~some:(fun scope -> Runtime_quota_window.is_exhausted ~scope ~now)
        (quota_scope_of candidate)
    in
    let rate_limited =
      Option.fold ~none:false
        ~some:(fun candidate -> Option.is_some
          (Runtime_lane_preference.candidate_backpressure ~now ~candidate))
        (candidate_preference_of candidate)
    in
    not (quota_exhausted || rate_limited)) candidates in
  available @ backpressured
;;

let quota_ordered_runtime_ids ~now runtime_ids =
  (* Resolve once so both kinds of ordering evidence use the same catalog row. *)
  let resolved = List.map (fun id -> id, Runtime.get_runtime_by_id id) runtime_ids in
  let resolvable, unresolvable = List.partition (fun (_, rt) -> Option.is_some rt) resolved in
  let ordered = demote_unavailable_candidates ~now
    ~quota_scope_of:(fun (_, rt) -> Option.map Runtime.quota_scope_of_runtime rt)
    ~candidate_preference_of:(fun (_, rt) ->
      Option.map (fun (rt : Runtime.t) -> rt.candidate_preference) rt)
    resolvable in
  List.map fst (ordered @ unresolvable)
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

(* Whether a runtime is one of the lane's own declared candidates.
   [Runtime_lane_preference.prefer_order] reorders the list it is given, which
   for a lane is that lane's candidates, so a preference naming a runtime
   outside them promotes nothing. *)
let lane_declares ~lane_id runtime_id =
  match Runtime.get_lane_by_id lane_id with
  | None -> false
  | Some lane -> List.mem runtime_id (Runtime_lane.ordered_candidates lane)

let attempt_runtime_candidates
    ?(preserve_order = false)
    ?(pre_tool_rejects = ref [])
    ?(allow_retry = fun ~runtime_id:_ ~attempt:_ _error -> true)
    ?(allow_accept_no_progress_retry = fun ~runtime_id:_ ~attempt:_ _error ->
      true)
    ?lane_id
    ?(on_retry_deferred = fun _ -> ())
    ?(on_attempt_error = fun ~runtime_id:_ ~attempt:_ ~dispatch:_ _error -> ())
    ?(on_lane_terminal_error = fun (_ : lane_terminal_error) -> ())
    ?quota_scope_of
    ?candidate_preference_of
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
  let candidate_preference_of =
    match candidate_preference_of with
    | Some candidate_preference_of -> candidate_preference_of
    | None -> fun candidate ->
        Runtime.get_runtime_by_id (runtime_id_of candidate)
        |> Option.map (fun (runtime : Runtime.t) -> runtime.candidate_preference)
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
    if preserve_order then rest else
    let dispatchable, undispatchable =
      List.partition candidate_dispatchable rest
    in
    demote_unavailable_candidates
      ~now:(Unix.gettimeofday ())
      ~quota_scope_of ~candidate_preference_of
      dispatchable
    @ undispatchable
  in
  (* Every error the walk returns from a candidate passes through here, so
     the caller learns which candidate produced the lane's error. *)
  let lane_terminal (terminal : lane_terminal_error) =
    on_lane_terminal_error terminal;
    Error terminal.lane_error
  in
  let rec loop ~(observed_overflow : lane_terminal_error option) idx = function
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
      let is_last = rest = [] in
      let attempt_runtime_id = runtime_id_of candidate in
      (* Bind quota ownership to the exact candidate that will be dispatched.
         [run_attempt] may span a runtime.toml reload; resolving the id after
         the provider returns could then attribute the old credential's
         response to the replacement catalog row. *)
      let attempt_quota_scope = quota_scope_of candidate in
      let attempt_candidate_preference = candidate_preference_of candidate in
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
         (* Sticky failover: remember the winning candidate so later turns on
            this lane start from it (idx 0 or a failover success alike).

            Only a candidate the lane declares. The media walk reaches past
            the lane into media_failover, and a winner from out there cannot
            be remembered for this lane: [prefer_order] would find it in no lane list and
            promote nothing, while the record has already replaced the last
            in-lane success. The next text turn then starts from the declared
            head again, and if that head is the one that was failing, it
            fails again every turn (#34823).

            A lane_id naming no configured lane records nothing either. There
            is no candidate list for [prefer_order] to reorder, so the entry
            could never be read. *)
         (match lane_id with
          | Some lane_id when lane_declares ~lane_id attempt_runtime_id ->
            Runtime_lane_preference.note_success ~lane_id
              ~candidate:attempt_runtime_id
          | Some _ | None -> ());
         Option.iter
           (fun candidate -> Runtime_lane_preference.note_candidate_success ~candidate)
           attempt_candidate_preference;
         (* A call getting through is the only evidence a quota came back that
            a provider stating no reset time leaves available, so it is what
            clears the observation. A stated window is left alone: it names a
            time, and one success inside it does not make that untrue. *)
         (match attempt_quota_scope with
          | Some scope -> Runtime_quota_window.note_succeeded ~scope
          | None -> ());
         Ok value
       | Error error, _checkpoint_after, effect_disposition, dispatch ->
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
           match attempt_quota_scope, retry_after with
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
             (fun candidate -> Runtime_lane_preference.note_rate_limit ~candidate ~retry_after)
             attempt_candidate_preference
         in
         (match error with
          | Agent_core.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ })
          | Agent_core.Error.Provider (Llm_provider.Error.RateLimit { retry_after; _ }) ->
              note_rate_limit retry_after
          | Agent_core.Error.Provider (Llm_provider.Error.HardQuota { retry_after; _ }) ->
              note_quota retry_after
          | Agent_core.Error.Api (Llm_provider.Retry.PaymentRequired _) -> note_quota None
          | _ -> ());
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
             then
               Some
                 { origin_runtime_id = attempt_runtime_id
                 ; origin_attempt = idx
                 ; lane_error = error
                 }
             else None
         in
         let this_candidate lane_error =
           { origin_runtime_id = attempt_runtime_id
           ; origin_attempt = idx
           ; lane_error
           }
         in
         if not effect_retry_admitted
         then lane_terminal (this_candidate terminal_error)
         else if retry_admitted && error_is_retryable
         then loop ~observed_overflow (idx + 1) rest
         else if is_last
         then (
           (* Lane fully exhausted: an overflow seen anywhere in the rotation
              outranks the last candidate's error so the failure route and
              blocker report the deterministic capacity bound. Cascade
              telemetry already published each candidate's own error. *)
           match observed_overflow with
           | Some overflow -> lane_terminal overflow
           | None -> lane_terminal (this_candidate error))
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
           lane_terminal (this_candidate terminal_error)))
  in
  loop ~observed_overflow:None 0 candidates

let runtime_candidate_missing_error id =
  Agent_core.Error.Internal
    (Printf.sprintf
       "keeper_turn_driver: lane candidate %S disappeared from runtimes"
       id)

let runtime_candidate_invalid_request_cap_error error =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "max-request-body-bytes"
       ; detail = Runtime.request_body_cap_error_to_string error
       })

let validate_provider_request_cap ~runtime_id
    (provider_config : Llm_provider.Provider_config.t) =
  match Runtime.validate_request_body_cap ~runtime_id provider_config with
  | Ok cap -> Ok cap
  | Error error -> Error (runtime_candidate_invalid_request_cap_error error)

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

(* RFC-0440: a live lane reroutes over the lane, then [runtime.media_failover],
   then the other declared runtimes, so an image turn on a lane whose capable
   head is down reaches a capable runtime declared elsewhere. The set is held
   in the same quota and backpressure order the lane itself uses
   ([demote_unavailable_candidates]): a candidate whose account answered a hard
   quota rejection earlier moves behind the live ones, so the reroute picks a
   live candidate instead of the first declared one. A deferred lane offers no
   candidates: its walk dispatches the frozen suffix ([lane_candidate_ids] in
   [run_agent_turn]), so a decision that moved the head would be recorded as a
   reroute the walk never performs. *)
let modality_reroute_candidates ~now ~deferred_runtime_lane ~first_candidate
    ~remaining_runtimes =
  match deferred_runtime_lane with
  | Some _ -> []
  | None ->
    Runtime_agent.media_candidates ~lane:(first_candidate :: remaining_runtimes)
    |> demote_unavailable_candidates
         ~now
         ~quota_scope_of:(fun (runtime : Runtime.t) ->
           Some (Runtime.quota_scope_of_runtime runtime))
         ~candidate_preference_of:(fun (runtime : Runtime.t) ->
           Some runtime.Runtime.candidate_preference)

(* RFC-0440 §3: the media walk (every candidate that takes the media, live ones
   first), then the lane's remaining candidates as the degrade tail — per-attempt
   projection drops the image there (PR-C replaces this tail with delegation). A
   text turn has an empty media walk and keeps [first_runtime :: remaining_runtimes].

   The walk leads, [first_runtime] does not. Putting the dispatch head at 0
   unconditionally undid the liveness ordering in the one case it is needed:
   when the assigned runtime takes the media itself,
   [decide_modality_reroute_for_runtime_candidates] answers [No_reroute_needed]
   on capability alone and never looks at the account, so a head already
   exhausted by a 402/429 stayed in front of the live out-of-lane candidate and
   every image turn hit it first again. When the head is live it is the walk's
   own head, so leading with the walk changes nothing; after a reroute the
   target is the walk head for the same reason, and the dedupe drops the second
   mention either way.

   [assigned_runtime] closes the list. A reroute replaces the head with an
   out-of-lane media runtime, so on a single-candidate text lane the assigned
   runtime appeared nowhere: every media candidate answering 402 exhausted the
   loop into an error instead of reaching the assigned runtime, whose
   per-attempt projection is what drops the image and delegates. It is the last
   entry because it is the degrade, not a candidate for the media. Whenever it
   is already the head or already in the walk the dedupe drops this mention, so
   a text turn and an un-rerouted media turn keep the list they had. *)
let attempt_runtimes_for_turn ~media_walk ~assigned_runtime ~first_runtime
    ~remaining_runtimes =
  dedupe_runtimes_preserve_order
    (media_walk @ (first_runtime :: remaining_runtimes) @ [ assigned_runtime ])

let lane_modality_reroute_decision ~checkpoint_messages ~initial_messages
    ~goal_blocks ~first_candidate ~candidates =
  Runtime_agent.decide_modality_reroute_for_runtime_candidates
    ~assigned:first_candidate
    ~candidates
    ~checkpoint_messages
    ~initial_messages
    goal_blocks

(* The WARN names the runtime being left and the runtime being taken. It used to
   print [assignment_id] on the left, which for a keeper whose assignment is a
   bare runtime id reads as a reroute from a runtime to itself — the "<id> -> <id>"
   lines that made a working reroute look like a no-op. The assignment is still
   reported, as the assignment. *)
let first_runtime_after_modality_reroute ~keeper_name ~assignment_id
    ~first_candidate_id ~first_candidate = function
  | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ ->
    first_candidate_id, first_candidate
  | Runtime_agent.Reroute { target; reason } ->
    let to_runtime_id = target.Runtime.id in
    Log.Keeper.warn
      "%s: RFC-0265 modality reroute %s -> %s (assignment %s: %s)"
      keeper_name
      first_candidate_id
      to_runtime_id
      assignment_id
      reason;
    to_runtime_id, target

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
          RFC-0265 had run and given up. Reachable when the modalities are
          each supported but the runtime does not accept them bundled: no single
          media block is individually unsupported, so the strip removes nothing.
          ToolResult-nested media used to land here too, before the strip
          learned to descend. *)
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
    ~runtime_id
    ?(runtime_selection = Resolve_assignment)
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
    ?(continue_from_checkpoint = false)
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?on_request_wire_observation
    ?on_request_attribution
    ?on_official_client_tool_boundary
    ?on_official_client_result_handoff
    ?on_official_client_native_action
    ?on_model_input_window_observation
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?deferred_runtime_lane
    ?on_runtime_attempt
    ?on_runtime_retry_deferred
    ?on_runtime_attempt_error
    ?on_runtime_lane_terminal_error
    ?on_deferred_runtime_consumed
    ?(output_contract = Provider_default)
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (named_run_result, Agent_core.Error.t) result =
  if runtime_selection <> Resolve_assignment && Option.is_some deferred_runtime_lane then
    Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig
      {field="runtime_selection";detail="an exact runtime cannot consume an ordinary deferred lane"}))
  else if continue_from_checkpoint && Option.is_none agent_core_checkpoint then
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
	  (* Audit F8: removed dead routing knobs from the signature so callers cannot
	     pass values that would be silently ignored. *)
  let routing_run_id = Random_id.hex ~bytes:16 in
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  let checkpoint_stage_observed = Atomic.make false in
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
     operators can route through explicit failover groups.  Lane candidate
     order passes through the sticky last-good preference so a known-healthy
     failover candidate is tried before re-hitting a dead head candidate. *)
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
  let* lane_id_opt, lane_candidate_ids =
    match runtime_selection, deferred_runtime_lane with
    | Exact_runtime, _ -> Ok (None, [runtime_id])
    | Exact_route, _ ->
      Ok (None, match Runtime.get_lane_by_id runtime_id with
        | Some lane -> Runtime_lane.ordered_candidates lane
        | None -> [runtime_id])
    | Resolve_assignment, Some hint ->
      Ok (Some hint.assignment_id, deferred_runtime_ids hint)
    | Resolve_assignment, None ->
      (match Runtime.resolve_assignment runtime_id with
       | `Missing -> Ok (None, [])
       | `Unavailable missing ->
         Error (Runtime_agent_core_runner.runtime_catalog_error_to_core_error
           ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing))
       | `Lane lane ->
         let lane_id = Runtime_lane.id lane in
         Ok
           ( Some lane_id
           , Runtime_lane_preference.prefer_order ~lane_id
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
  (* This decision orders the walk: a [Reroute] moves a capable candidate to
     the head and drops the assigned one. On a deferred lane the suffix order
     was frozen before pre-dispatch shaping, so [modality_reroute_candidates]
     is [[]] and the decision can only be [No_reroute_needed] or
     [No_capable_runtime], neither of which moves the head. The media degrade
     itself is not decided here for any lane: every attempt projects the input
     against the runtime it dispatches to ([project_input_for_attempt] inside
     [run_attempt] below), because the walk crosses runtimes with different
     input capabilities and one strip bound here was right for the head only
     (#33034 fixed the deferred head; the tail still received the head's view). *)
  let reroute_candidates =
    match runtime_selection with
    | Exact_runtime | Exact_route -> []
    | Resolve_assignment ->
    modality_reroute_candidates
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
  let first_runtime =
    snd
      (first_runtime_after_modality_reroute ~keeper_name ~assignment_id:runtime_id
         ~first_candidate_id ~first_candidate reroute_decision)
  in
  let attempt_runtimes =
    attempt_runtimes_for_turn
      ~media_walk:
        (Runtime_agent.media_walk
           ~candidates:reroute_candidates
           ~checkpoint_messages
           ~initial_messages
           current_goal_blocks)
      ~assigned_runtime:first_candidate
      ~first_runtime
      ~remaining_runtimes
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
      ~exclude_runtime_ids:lane_candidate_ids
      ~keeper_name
      () in
    fun ~mode blocks ->
      (* Exact-lane admission also owns provider selection for image evidence:
         retain unread artifacts, but never dispatch an out-of-lane vision call. *)
      let mode = match runtime_selection with
        | Resolve_assignment -> mode
        | Exact_runtime | Exact_route -> Keeper_vision_ingest.Store_only in
      project ~mode blocks
  in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return.
     Modality reroutes are capability routing decisions, not provider-failure
     discoveries.  Do not let a media-only reroute update the lane-global
     sticky failover preference; otherwise one keeper can pin unrelated later
     text-only turns to a less-trusted fallback for the preference TTL. *)
  let sticky_lane_id =
    match reroute_decision with
    | Runtime_agent.Reroute _ -> None
    | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ ->
      lane_id_opt
  in
  attempt_runtime_candidates
    ~preserve_order:(runtime_selection <> Resolve_assignment)
    ~pre_tool_rejects
    ?lane_id:sticky_lane_id
    ?on_retry_deferred:on_runtime_retry_deferred
    ?on_attempt_error:on_runtime_attempt_error
    ?on_lane_terminal_error:on_runtime_lane_terminal_error
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
    ~candidate_preference_of:(function
      | Resolved_runtime runtime -> Some runtime.Runtime.candidate_preference
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
        else match recovery_view, runtime.Runtime.execution with
        | Some _, Runtime_execution.Agent_core _ ->
          Keeper_recovery_transmission.require_reader agent_core_tools
          |> Result.map_error Keeper_recovery_transmission.to_core_error
        | _ -> Ok () in
      let has_tools, surface_enabled = match runtime.Runtime.execution with
        | Runtime_execution.Agent_core _ -> agent_core_tools <> [], true
        | Runtime_execution.Codex_app_server _
        | Runtime_execution.Antigravity_cli _ -> tools <> [], true
        | Runtime_execution.Claude_code _ -> tools <> [], runtime.model.tools_support in
      (match Result.bind source_reader_ready (fun () ->
          Keeper_required_tools.check_surface tool_requirement
            ~runtime_id:attempt_runtime_id ~surface_enabled ~has_tools
          |> Result.map_error Keeper_required_tools.to_core_error) with
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
      let inference_policy =
        attempt_inference_policy
          ~runtime_id:attempt_runtime_id
          ~fallback_enable_thinking:enable_thinking
          ()
      in
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
        let run_codex ~initial_messages () =
          let on_transmitted_model_input transmitted =
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_codex_runtime.run
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
              (Option.map
                 (fun observe observation ->
                    observe ~measurement:Turn_record.Durable_shape observation)
                 on_model_input_window_observation)
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
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
        , codex_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Antigravity_cli config ->
        let run_antigravity ~initial_messages () =
          let on_transmitted_model_input transmitted =
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_antigravity_runtime.run
            ?required_native_posture
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
            ~on_transmitted_model_input
            ~hooks
            ~context_injector
            ~context
            ~terminal_effect_state
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
        , antigravity_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Claude_code config ->
        let run_claude ~initial_messages () =
          let tools = if runtime.model.tools_support then tools else [] in
          let on_transmitted_model_input transmitted =
            Option.iter
              (fun observe ->
                 observe ~runtime_id:attempt_runtime_id ~tools ~transmitted)
              on_request_attribution
          in
          Keeper_claude_code_runtime.run
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
        , claude_attempt.effect_disposition
        , official_client_dispatch ~provider_config_transform )
      | Runtime_execution.Agent_core runtime_provider_config ->
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
          (match
             validate_provider_request_cap
               ~runtime_id:attempt_runtime_id
               provider_config
           with
           | Error err ->
             Option.iter (fun consume -> consume ()) on_deferred_runtime_consumed;
             Error err, None, Keeper_provider_attempt_effect.No_effect_observed,
             Keeper_attempt_dispatch.Rejected_before_dispatch
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
            ; (* Only this lane can widen a running turn, so only this lane
                 is handed the listing. The official-client branches above
                 take [tools] whole. A caller that named no lane view is not
                 deferring anything, so this lane sends every tool too --
                 which is what every caller did before the listing existed. *)
              tools = agent_core_tools
            ; initial_messages
            ; model_input_projection
            ; recovery_view
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
            ; checkpoint_sink =
                Option.map
                  (canonical_checkpoint_sink ~replay_prefix_projection)
                  checkpoint_sink
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
            Keeper_turn_driver_try_provider.run_try_provider_with_truncation_recovery
              ?continuation_checkpoint:
                (if continue_from_checkpoint then agent_core_checkpoint else None)
              try_provider_ctx candidate
          in
          let outcomes =
            project_provider_attempt_result
              ~replay_prefix_projection
              provider_result
          in
          ( selected_runtime_result runtime ~lane_attempt_index:idx outcomes.turn_result
          , checkpoint_after
          , Keeper_provider_attempt_effect.No_effect_observed
          , Keeper_attempt_dispatch.Dispatched ))))
       )))
    attempt_candidates


module For_testing = struct
  type nonrec provider_attempt_outcomes = provider_attempt_outcomes

  let make_deferred_runtime_lane ~assignment_id ~failed_runtime_id
        ~next_runtime_id ~later_runtime_ids ~failure =
    restore_deferred_runtime_lane ~assignment_id ~failed_runtime_id
      ~next_runtime_id ~later_runtime_ids ~failure
  ;;

  let project_provider_attempt_result = project_provider_attempt_result
  let canonical_checkpoint_sink = canonical_checkpoint_sink
  let provider_result outcomes = outcomes.provider_result
  let turn_result outcomes = outcomes.turn_result
  let checkpoint_after_attempt = checkpoint_after_attempt
  let success_selected_model_raw = success_selected_model_raw
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let first_runtime_after_modality_reroute =
    first_runtime_after_modality_reroute

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

  let same_run_retry_allowed =
    Keeper_turn_driver_try_provider.same_run_retry_allowed

  let accept_no_progress_should_try_next =
    Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next

end
