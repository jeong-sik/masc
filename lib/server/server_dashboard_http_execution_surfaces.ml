(** Cached execution and transport dashboard surfaces extracted from the
    dashboard HTTP facade. *)

open Server_utils
open Server_dashboard_http_core

type cached_surface = Server_dashboard_http_cache.cached_surface


let deep_surface_cache_ttl_s = Server_dashboard_http_core_cache.deep_surface_cache_ttl_s
let shell_surface_cache_ttl_s = Server_dashboard_http_core_cache.shell_surface_cache_ttl_s

(* Transport health probe timeout — env-overridable with sane bounds.
   SSOT: env_config_snapshot.ml also registers the same env var. *)
let transport_health_timeout_default_s = 8.0
let transport_health_timeout_min_s = 3.0
let transport_health_timeout_max_s = 30.0

(* Routed through Env_config_runtime.Dashboard so operators can raise
   the ceiling on slow-disk deployments without a rebuild. The outer
   wrapper at [server_runtime_bootstrap.ml] uses the matching
   [shell_prewarm_outer_timeout_sec] env to keep the 5s headroom. *)
let shell_prewarm_timeout_s = Env_config_runtime.Dashboard.shell_prewarm_inner_timeout_sec

(* Delta push follows the replay commit, not the start or return of a
   broadcast. Different domains and external subscribers can interleave
   publications and callbacks for the same event type. *)
type broadcast_payload_state =
  { mutable fanout : (int * string) option
  ; mutable committed_id : int option
  }

let last_broadcast_payload : (string, broadcast_payload_state) Hashtbl.t =
  Hashtbl.create 8
let broadcast_payload_mu = Stdlib.Mutex.create ()

(* Where a surface payload is encoded. Either way it is encoded once, and the
   SSE frame is written around those bytes.

   An operator snapshot is 2.8 MB: encoding it, hashing it for the delta check
   and encoding it again for the frame took 27 ms standalone, and the snapshot
   refresh fiber's runs on the scheduler domain were 35-63 ms (2026-09-16).

   The pool hands the fiber back to the scheduler while it encodes, so only a
   caller that may yield takes it. [still_current] is checked after encoding
   and again after acquiring the publication lock, so waiting for an earlier
   broadcast does not send a payload already superseded while it waited;
   [on_superseded] runs instead. *)
type surface_encoding =
  | Encode_inline
  | Encode_on_pool of
      { still_current : unit -> bool
      ; on_superseded : unit -> unit
      }

(** Broadcast a single cached surface to all Observer SSE sessions.
    [event_type] becomes the SSE event "type" field. Skips the broadcast when
    the payload text equals the previous one for [event_type] (delta push). *)
let broadcast_cached_surface ?(target = Sse.Observers) ~encoding ~event_type (json : Yojson.Safe.t) : unit =
  let payload =
    match encoding with
    | Encode_inline -> Some (Sse_wire.encode_json json)
    | Encode_on_pool { still_current; on_superseded } ->
      let payload =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> Sse_wire.encode_json json)
      in
      if still_current ()
      then Some payload
      else (
        Log.Dashboard.routine
          "%s: payload superseded while encoding, skipping broadcast"
          event_type;
        on_superseded ();
        None)
  in
  match payload with
  | None -> ()
  | Some payload ->
    Stdlib.Mutex.lock broadcast_payload_mu;
    let locked = ref true in
    let outcome =
      Fun.protect
        ~finally:(fun () -> if !locked then Stdlib.Mutex.unlock broadcast_payload_mu)
        (fun () ->
        let current = match encoding with
          | Encode_inline -> true
          | Encode_on_pool { still_current; _ } -> still_current () in
        if not current then `Superseded else begin
        let state =
          match Hashtbl.find_opt last_broadcast_payload event_type with
          | Some state -> state
          | None ->
              let state = { fanout = None; committed_id = None } in
              Hashtbl.add last_broadcast_payload event_type state;
              state
        in
        match state.fanout, state.committed_id with
        | Some (fanout_id, previous), Some committed_id
          when Int.equal fanout_id committed_id
               && String.equal previous payload.Sse_wire.text ->
            `Unchanged
        | (None | Some _), (None | Some _) ->
            let on_fanout event_id =
              state.fanout <- Some (event_id, payload.Sse_wire.text);
              locked := false;
              Stdlib.Mutex.unlock broadcast_payload_mu
            in
            let on_committed event_id =
              Stdlib.Mutex.protect broadcast_payload_mu (fun () ->
                match state.committed_id with
                | Some previous_id when previous_id >= event_id -> ()
                | Some _ | None -> state.committed_id <- Some event_id)
            in
            let encoded =
              Sse_wire.encoded_object
                [ "type", Sse_wire.encode_json (`String event_type)
                ; "payload", payload
                ; "ts_unix", Sse_wire.encode_json (`Float (Time_compat.now ()))
                ]
            in
            Sse.broadcast_encoded_to_with_receipts target ~on_fanout ~on_committed encoded;
            `Published
        end)
    in
    (match outcome with
     | `Published -> ()
     | `Unchanged ->
         Log.Dashboard.routine "%s: payload unchanged, skipping broadcast" event_type
     | `Superseded ->
         Log.Dashboard.routine "%s: payload superseded before broadcast" event_type;
         (match encoding with
          | Encode_inline -> ()
          | Encode_on_pool { on_superseded; _ } -> on_superseded ()))
;;

let execution_actor_for_request ~base_path request =
  Server_auth.sanitized_dashboard_actor_for_request ~base_path request
;;

(* These two used to be installed into process-global Atomics from module
   initializers, because Server_dashboard_http_core_operator is compiled before
   Sse is in scope here and so cannot name these bodies. They are ordinary
   functions now; the refresh loops take them as arguments (#25927). *)
let operator_snapshot_publication_is_current
      (publication :
        Server_dashboard_http_core_operator.operator_snapshot_publication)
  =
  let current =
    Server_dashboard_http_core_operator.operator_snapshot_publication ()
  in
  String.equal current.epoch publication.epoch
  && Int.equal current.generation publication.generation
  && Int.equal current.compute_sequence publication.compute_sequence
  && Int.equal current.terminal_sequence publication.terminal_sequence
;;

let operator_snapshot_json =
  Server_dashboard_http_core_operator.operator_snapshot_publication_json
;;

let broadcast_operator_snapshot
      (publication :
        Server_dashboard_http_core_operator.operator_snapshot_publication)
  =
    if operator_snapshot_publication_is_current publication
    then
      broadcast_cached_surface
        ~encoding:Encode_inline
        ~event_type:"operator_snapshot"
        (operator_snapshot_json publication)
;;

(* A publication that replaced this one while it was encoding is handed on.
   An invalidation or a failure was broadcast by whoever published it; a
   success the /api/v1/operator route published is broadcast by nobody else,
   so the current success is broadcast in this one's place. When its publisher
   has already sent it, the delta check drops it. *)
let rec broadcast_refreshed_operator_snapshot
      (publication :
        Server_dashboard_http_core_operator.operator_snapshot_publication)
  =
    if operator_snapshot_publication_is_current publication
    then
      broadcast_cached_surface
        ~encoding:
          (Encode_on_pool
             { still_current =
                 (fun () -> operator_snapshot_publication_is_current publication)
             ; on_superseded = broadcast_current_successful_operator_snapshot
             })
        ~event_type:"operator_snapshot"
        (operator_snapshot_json publication)

and broadcast_current_successful_operator_snapshot () =
  let current = Server_dashboard_http_core_operator.operator_snapshot_publication () in
  if current.has_success then broadcast_refreshed_operator_snapshot current
;;

let () =
  Dashboard_projection_cache.register_snapshot_generation_observer
    (fun generation ->
       match
         Server_dashboard_http_core_operator
         .publish_operator_snapshot_invalidation_if_current
           ~generation
       with
       | None -> ()
       | Some publication -> broadcast_operator_snapshot publication)
;;

let broadcast_operator_digest json =
  broadcast_cached_surface ~encoding:Encode_inline ~event_type:"operator_digest" json

let create_execution_cache () : cached_surface =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc [ "status", `String "initializing";
      "generated_at", `String (Masc_domain.now_iso ());
      "message", `String "Execution data is being computed." ])
;;

let execution_default_light_cache_key = "execution:default:light"

type execution_http_source = {
  snapshot : Server_dashboard_http_cache.surface_snapshot;
  base_path : string;
  workspace_path : string;
}

type execution_http_preparation = {
  source : execution_http_source;
  settled : unit Eio.Promise.t;
  settle : unit Eio.Promise.u;
}

type execution_http_payload = {
  source : execution_http_source;
  response_json : Yojson.Safe.t;
  encoded : Http_response_payload.prepared;
  etag : string;
}

type execution_http_response =
  | Execution_json of Yojson.Safe.t
  | Execution_payload of Dashboard_cache.cached_payload

let execution_payload_response (payload : execution_http_payload) =
  let raw_json, _ = Http_response_payload.select_prepared payload.encoded
      ~accept_encoding:(Some "identity") in
  { Dashboard_cache.json = payload.response_json;
    raw_json; etag = payload.etag; origin = Dashboard_cache.Computed;
    encoded = Some payload.encoded }
;;

type execution_http_state =
  | Empty
  | Preparing of execution_http_preparation
  | Ready of execution_http_payload

type last_publication =
  | No_publication
  | Published_success of int
  | Published_failure of int

let execution_publication_epoch =
  (* NDT-OK: process-incarnation identity only. Scope identity is captured
     separately below before the read, never inferred from a later lookup. *)
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string
;;

let execution_publication_epoch_field = "execution_publication_epoch"
let execution_publication_generation_field = "execution_publication_generation"
let execution_invalidated_field = "execution_invalidated"
let execution_generation_sequence = Atomic.make 0
let next_execution_generation () = Atomic.fetch_and_add execution_generation_sequence 1 + 1

type execution_origin = Observation_read | Request_read

type execution_completion =
  | Cache_installed of execution_origin
  | Cache_failed of execution_origin
  | Cache_patched
  | Shell_installed

type completion_listener = { completed : execution_completion -> unit }

type execution_owner = {
  cache : cached_surface;
  binding : (Mcp_server.server_state * Mcp_server.workspace_scope) option;
  stream_epoch : string;
  cache_identity : string;
  target : Sse.broadcast_target;
  publication_mu : Stdlib.Mutex.t;
  generation : int ref;
  default_light_http : execution_http_state ref;
  next_ticket : int ref;
  last_publication : last_publication ref;
  completion_listeners : completion_listener list Atomic.t;
  next_deadline_unix : float option ref;
  shell : Yojson.Safe.t option ref;
  shell_light : Yojson.Safe.t option ref;
  namespace_revision : int ref;
}

type execution_attempt = { owner : execution_owner; generation : int; ticket : int; origin : execution_origin }

let unbound_owner_sequence = Atomic.make 0

let create_execution_owner binding =
  let identity = match binding with
    | Some (_, scope) -> Mcp_server.Workspace_scope_epoch.to_string scope.Mcp_server.epoch
    | None -> "fixture:" ^ string_of_int (Atomic.fetch_and_add unbound_owner_sequence 1) in
  let target = match binding with
    | None -> Sse.Observers
    | Some (_, scope) -> Sse.Scoped_runtime_observers (Sse.observer_scope
        ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
        ~instance_id:(Server_observer_scope.instance_id scope)) in
  { cache = create_execution_cache (); binding; target;
    stream_epoch = execution_publication_epoch;
    cache_identity = execution_publication_epoch ^ ":" ^ identity;
    publication_mu = Stdlib.Mutex.create (); generation = ref (next_execution_generation ());
    default_light_http = ref Empty; next_ticket = ref 0;
    last_publication = ref No_publication; completion_listeners = Atomic.make [];
    next_deadline_unix = ref None; shell = ref None; shell_light = ref None; namespace_revision = ref 0 }
;;

let execution_owner_is_current owner = match owner.binding with
  | None -> true
  | Some (state, scope) -> Mcp_server.Workspace_scope_epoch.equal scope.epoch
      (Mcp_server.workspace_scope state).epoch
;;

let active_execution_owner_mu = Stdlib.Mutex.create ()
let active_execution_owner : execution_owner option ref = ref None

let execution_owner_for_scope ~state (scope : Mcp_server.workspace_scope) =
  let selected_unlocked () = match !active_execution_owner with
    | Some ({binding = Some (_, current); _} as owner)
      when Mcp_server.Workspace_scope_epoch.equal current.epoch scope.epoch -> Some owner
    | Some _ | None -> None in
  match Stdlib.Mutex.protect active_execution_owner_mu selected_unlocked with
  | Some owner -> owner
  | None ->
      (* Runtime authority resolution may touch the filesystem. It precedes
         admission and never runs under the publication/owner mutexes. *)
      let candidate = create_execution_owner (Some (state, scope)) in
      Stdlib.Mutex.protect active_execution_owner_mu (fun () ->
        match selected_unlocked () with
        | Some owner -> owner
        | None ->
            if execution_owner_is_current candidate then
              active_execution_owner := Some candidate;
            candidate)
;;

let execution_cache_for_scope ~state scope =
  (execution_owner_for_scope ~state scope).cache
;;

let execution_cache ~state =
  execution_cache_for_scope ~state (Mcp_server.workspace_scope state)
;;

let current_execution_owner () =
  Stdlib.Mutex.protect active_execution_owner_mu (fun () ->
    match !active_execution_owner with
    | Some owner when execution_owner_is_current owner -> Some owner
    | Some _ | None -> None)
;;

let with_execution_publication_lock ~owner f =
  Stdlib.Mutex.protect owner.publication_mu f
;;

let subscribe_execution_completion ~owner completed =
  let listener = {completed} in
  Lockfree_atomic.update owner.completion_listeners (fun current -> listener :: current);
  fun () -> Lockfree_atomic.update owner.completion_listeners
    (List.filter (fun current -> current != listener))
;;

let execution_completion_failures = Atomic.make 0

let notify_execution_completion owner completion =
  List.iter (fun listener ->
    try listener.completed completion with
    (* cancel-guard-ok: after-cache metadata callbacks must not replace the
       admitted publication or the authoritative caller's cancellation. *)
    | _ -> ignore (Atomic.fetch_and_add execution_completion_failures 1))
    (Atomic.get owner.completion_listeners)
;;

let last_good_shell_for_scope ~state scope =
  let owner = execution_owner_for_scope ~state scope in
  with_execution_publication_lock ~owner (fun () -> !(owner.shell))
;;

let namespace_cache_revision ~state scope =
  let owner = execution_owner_for_scope ~state scope in
  with_execution_publication_lock ~owner (fun () -> !(owner.namespace_revision))
;;

let publish_shell_cache_success ~state ~scope ~light json =
  let owner = execution_owner_for_scope ~state scope in
  let published = with_execution_publication_lock ~owner (fun () ->
    if not (execution_owner_is_current owner) then false else (
      incr owner.namespace_revision;
      if light then (
        owner.shell_light := Some json;
        Atomic.set last_good_shell_light json)
      else (
        owner.shell := Some json;
        Atomic.set last_good_shell json;
        Atomic.set shell_warmed true);
      true)) in
  if published then notify_execution_completion owner Shell_installed
;;

let warm_shell_cache (state : Mcp_server.server_state) =
  let scope = Mcp_server.workspace_scope state in
  Atomic.set shell_warming true;
  Eio_guard.protect
    ~finally:(fun () -> Atomic.set shell_warming false)
    (fun () ->
       let t0 = Time_compat.now () in
       let cache_shell_payload ~light =
         let cache_key =
           dashboard_shell_cache_key ~light scope.config
         in
         let compute =
           Pool_work.cpu ~name:__FUNCTION__ (fun () ->
             dashboard_shell_payload_json ~light scope.config)
         in
         match state.Mcp_server.clock with
         | Some clock ->
           Dashboard_cache.get_or_compute_with_timeout
             cache_key
             ~ttl:shell_surface_cache_ttl_s
             ~clock
             ~timeout_sec:shell_prewarm_timeout_s
             compute
         | None -> Dashboard_cache.get_or_compute cache_key ~ttl:shell_surface_cache_ttl_s compute
       in
       (try
          let light_result = cache_shell_payload ~light:true in
          if Dashboard_cache.is_timeout_envelope light_result
          then
            Log.Dashboard.warn
              "light shell cache pre-warm timed out during compute (%.0fs)"
              shell_prewarm_timeout_s
          else (
            publish_shell_cache_success ~state ~scope ~light:true light_result;
            Log.Dashboard.info
              "light shell cache pre-warmed (%.1fms)"
              ((Time_compat.now () -. t0) *. 1000.0))
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Dashboard.warn
            "light shell cache pre-warm failed: %s"
            (Printexc.to_string exn));
       try
         let result = cache_shell_payload ~light:false in
         if Dashboard_cache.is_timeout_envelope result
         then
           Log.Dashboard.warn
             "shell cache pre-warm timed out during compute (%.0fs)"
             shell_prewarm_timeout_s
         else (
           publish_shell_cache_success ~state ~scope ~light:false result;
           Log.Dashboard.info
             "shell cache pre-warmed (%.1fms)"
             ((Time_compat.now () -. t0) *. 1000.0))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Dashboard.warn "shell cache pre-warm failed: %s" (Printexc.to_string exn))
;;

let clear_execution_default_light_http_body ~owner () =
  owner.default_light_http := Empty
;;

let execution_surface_has_fresh_success_unlocked ~owner () =
  let snapshot = Server_dashboard_http_cache.snapshot owner.cache in
  match snapshot.last_success_unix, snapshot.last_error_unix with
  | Some success, Some error when error > success -> false
  | Some _, _ -> true
  | None, _ -> false
;;

let execution_attempt_now ~owner ~origin () =
  with_execution_publication_lock ~owner (fun () ->
    incr owner.next_ticket;
    { owner; generation = !(owner.generation); ticket = !(owner.next_ticket); origin })
;;

let begin_execution_attempt ~owner ~origin () =
  with_execution_publication_lock ~owner (fun () ->
    incr owner.next_ticket;
    clear_execution_default_light_http_body ~owner ();
    Server_dashboard_http_cache.mark_cached_surface_attempt owner.cache;
    { owner; generation = !(owner.generation); ticket = !(owner.next_ticket); origin })
;;

let current_execution_publication_generation ~owner () =
  with_execution_publication_lock ~owner (fun () -> !(owner.generation))
;;

let current_execution_http_revision ~owner () =
  with_execution_publication_lock ~owner (fun () ->
    let ticket = match !(owner.last_publication) with
      | No_publication -> 0
      | Published_success ticket | Published_failure ticket -> ticket in
    !(owner.generation), ticket)
;;

let with_execution_observer_instance ~owner json =
  match owner.binding, json with
  | Some (_, scope), `Assoc fields ->
      `Assoc (("observer_instance_id", `String (Server_observer_scope.instance_id scope))
        :: List.remove_assoc "observer_instance_id" fields)
  | None, `Assoc fields -> `Assoc (List.remove_assoc "observer_instance_id" fields)
  | (None | Some _), (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) -> json
;;

let with_execution_publication_generation ~owner ~generation json =
  (match json with
  | `Assoc fields ->
      let fields = fields
        |> List.remove_assoc execution_publication_epoch_field
        |> List.remove_assoc execution_publication_generation_field
        |> List.remove_assoc execution_invalidated_field in
      `Assoc ((execution_publication_epoch_field, `String owner.stream_epoch)
        :: (execution_publication_generation_field, `Int generation)
        :: (execution_invalidated_field, `Bool false) :: fields)
  | json -> `Assoc [execution_publication_epoch_field, `String owner.stream_epoch;
      execution_publication_generation_field, `Int generation;
      execution_invalidated_field, `Bool false; "snapshot", json])
  |> with_execution_observer_instance ~owner
;;

let execution_publication_admits_unlocked attempt ~failure =
  let owner = attempt.owner in
  execution_owner_is_current owner && attempt.generation = !(owner.generation)
  && match !(owner.last_publication) with
     | No_publication -> true
     | Published_success last -> if failure then attempt.ticket > last else attempt.ticket >= last
     | Published_failure last -> attempt.ticket >= last
;;

let publish_execution_observation attempt (observation : Dashboard_execution.observation) =
  let owner = attempt.owner in
  let published = with_execution_publication_lock ~owner (fun () ->
    if not (execution_publication_admits_unlocked attempt ~failure:false) then false
    else (
      Server_dashboard_http_cache.mark_cached_surface_success owner.cache
        (with_execution_publication_generation ~owner ~generation:attempt.generation observation.json);
      owner.next_deadline_unix := observation.next_deadline_unix;
      incr owner.namespace_revision;
      owner.last_publication := Published_success attempt.ticket;
      true)) in
  if published then notify_execution_completion owner (Cache_installed attempt.origin);
  published
;;

let publish_execution_attempt_success attempt json =
  publish_execution_observation attempt {Dashboard_execution.json; next_deadline_unix = None;
    completeness = Dashboard_projection_read.Complete}
;;

let publish_execution_attempt_failure_message attempt message =
  let owner = attempt.owner in
  let published = with_execution_publication_lock ~owner (fun () ->
    if not (execution_publication_admits_unlocked attempt ~failure:true) then false
    else (
      clear_execution_default_light_http_body ~owner ();
      Server_dashboard_http_cache.mark_cached_surface_error_message owner.cache message;
      owner.last_publication := Published_failure attempt.ticket;
      true)) in
  if published then notify_execution_completion owner (Cache_failed attempt.origin);
  published
;;

let publish_execution_attempt_failure attempt exn =
  publish_execution_attempt_failure_message attempt (Printexc.to_string exn)
;;

let execution_trust_cache_key = "execution-trust:default"

let create_execution_trust_cache () : cached_surface =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc
        [ "source", `String Dashboard_http_keeper_types.execution_trust_source
        ; "producer", `String Dashboard_http_keeper_types.execution_trust_producer
        ; "dashboard_surface", `String Dashboard_http_keeper_types.execution_trust_dashboard_surface
        ; "freshness_slo_s", `Float Dashboard_http_keeper_types.execution_trust_freshness_slo_s
        ; "entry_count", `Int 0
        ; "exists", `Bool false
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; "keepers", `List []
        ; "total", `Int 0
        ; "coverage_gaps", `List []
        ; "coverage_gap_count", `Int 0
        ; "health", `String "initializing"
        ])
;;

let execution_trust_cache_mu = Stdlib.Mutex.create ()
let execution_trust_cache_scope :
    (Mcp_server.Workspace_scope_epoch.t * cached_surface) option ref = ref None

let execution_trust_cache_for_scope ~state (scope : Mcp_server.workspace_scope) =
  Stdlib.Mutex.protect execution_trust_cache_mu (fun () ->
    if not (Mcp_server.Workspace_scope_epoch.equal scope.epoch
              (Mcp_server.workspace_scope state).epoch) then
      (* A delayed old request must not retire the current worker's cell.
         Its private answer may finish, but is never installed as current. *)
      create_execution_trust_cache ()
    else match !execution_trust_cache_scope with
    | Some (epoch, cache)
      when Mcp_server.Workspace_scope_epoch.equal epoch scope.epoch -> cache
    | Some _ | None ->
        let cache = create_execution_trust_cache () in
        execution_trust_cache_scope := Some (scope.epoch, cache);
        cache)
;;

let execution_trust_cache ~state =
  execution_trust_cache_for_scope ~state (Mcp_server.workspace_scope state)
;;

(** Invalidate the execution surface cache so the next
    [/api/v1/dashboard/execution] request recomputes fresh data.
    Called via [Workspace_hooks.on_task_mutation_fn] from the authoritative
    backlog and goal-link commit boundaries.
    Best-effort: never raises — cache staleness must not break
    the mutation path. *)
let record_invalidation_failure ~callback ~message exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[ "callback", callback ]
    ();
  Log.Dashboard.error "%s: %s" message (Printexc.to_string exn)
;;

let invalidate_execution_cache_with_hooks_for_testing
      ~invalidate_execution_surface
      ~invalidate_light_cache
      ()
  =
  (try invalidate_execution_surface () with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     record_invalidation_failure
       ~callback:"execution_surface_cache_invalidate"
       ~message:"Failed to invalidate execution surface cache"
       exn);
  try invalidate_light_cache () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    record_invalidation_failure
      ~callback:"dashboard_execution_light_cache_invalidate"
      ~message:"Failed to invalidate dashboard execution cache"
      exn
;;

let invalidate_execution_owner_with ~owner ~before_broadcast () =
  let invalidate () =
  let invalidated_generation = ref None in
  invalidate_execution_cache_with_hooks_for_testing
    ~invalidate_execution_surface:(fun () ->
      with_execution_publication_lock ~owner (fun () ->
        owner.generation := next_execution_generation ();
        owner.next_deadline_unix := None;
        invalidated_generation := Some !(owner.generation);
        clear_execution_default_light_http_body ~owner ();
        Server_dashboard_http_cache.invalidate_cached_surface owner.cache))
    ~invalidate_light_cache:(fun () ->
      Dashboard_cache.invalidate_prefix "execution:")
    ();
  before_broadcast ();
  Option.iter
    (fun generation ->
       try
         broadcast_cached_surface ~target:owner.target
           ~encoding:Encode_inline
           ~event_type:Dashboard_event_slices.execution_snapshot_type
           (`Assoc
               [ execution_publication_epoch_field, `String owner.stream_epoch
               ; execution_publication_generation_field, `Int generation
               ; execution_invalidated_field, `Bool true
               ] |> with_execution_observer_instance ~owner)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         record_invalidation_failure
           ~callback:"execution_snapshot_invalidation_broadcast"
           ~message:"Failed to broadcast execution cache invalidation"
           exn)
    !invalidated_generation
  in
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect invalidate
  | Eio_guard.Non_eio -> invalidate ()
;;

let invalidate_execution_cache_with ~before_broadcast () =
  match current_execution_owner () with
  | Some owner -> invalidate_execution_owner_with ~owner ~before_broadcast ()
  | None ->
      Dashboard_cache.invalidate_prefix "execution:";
      before_broadcast ()
;;

let invalidate_execution_cache () =
  invalidate_execution_cache_with ~before_broadcast:(fun () -> ()) ()
;;

let invalidate_task_mutation_caches ~invalidate_full_health_snapshot () =
  (* Wake health after invalidating execution, but before the SSE fanout can
     wait on a subscriber. Preserve the old cancellation order: an exception
     from health is re-raised only after execution's broadcast is attempted.
     The planning projection carries the task backlog, so a reader that
     answers [execution_snapshot] by reading planning reads it after the
     write. *)
  let cancellation = ref None in
  invalidate_execution_cache_with
    ~before_broadcast:(fun () ->
      (try
         Dashboard_cache.invalidate_prefix
           Server_dashboard_http_core_cache.planning_cache_prefix
       with
       | Eio.Cancel.Cancelled _ as exn ->
         cancellation := Some (exn, Printexc.get_raw_backtrace ())
       | exn ->
         record_invalidation_failure
           ~callback:"planning_cache_invalidate"
           ~message:"Failed to invalidate the planning projection"
           exn);
      try invalidate_full_health_snapshot () with
      | Eio.Cancel.Cancelled _ as exn ->
        cancellation := Some (exn, Printexc.get_raw_backtrace ())
      | exn ->
        record_invalidation_failure
          ~callback:"full_health_snapshot_invalidate"
          ~message:"Failed to invalidate full-health snapshot"
          exn)
    ();
  match !cancellation with
  | None -> ()
  | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;

let install_task_mutation_cache_invalidation ~invalidate_full_health_snapshot () =
  Atomic.set
    Workspace_hooks.on_task_mutation_fn
    (invalidate_task_mutation_caches ~invalidate_full_health_snapshot)
;;

(** Bypass the proactive warm-up guard so tests that call
    [dashboard_namespace_truth_http_json] get the full response instead of
    the "initializing" short-circuit. *)
let seed_execution_cache_for_test ~state () =
  let owner = execution_owner_for_scope ~state (Mcp_server.workspace_scope state) in
  with_execution_publication_lock ~owner (fun () ->
    Server_dashboard_http_cache.mark_cached_surface_success
      owner.cache
      (`Assoc [ "status", `String "seeded_for_test" ]))
;;

let transport_health_cache =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc
        [ "status", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; ( "message"
          , `String "Transport health data is warming up. Refresh in a few seconds." )
        ])
;;

let cached_surface_assoc_field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let cached_surface_projection_fields json =
  match cached_surface_assoc_field_opt "projection_diagnostics" json with
  | Some (`Assoc fields) -> fields
  | _ -> []
;;

let cached_surface_projection_field json key =
  List.assoc_opt key (cached_surface_projection_fields json)
;;

let cached_surface_generated_at_iso json =
  match cached_surface_projection_field json "generated_at" with
  | Some (`String value) -> value
  | _ ->
    (match cached_surface_assoc_field_opt "generated_at" json with
     | Some (`String value) -> value
     | _ -> Masc_domain.now_iso ())
;;

let cached_surface_cache_json
      ?cache_key
      ~scope
      json
  =
  let diagnostic_field key =
    match cached_surface_projection_field json key with
    | Some value -> value
    | None -> `Null
  in
  let cache_state =
    match cached_surface_projection_field json "cache_state" with
    | Some (`String value) -> value
    | _ -> "request_swr_or_inline_compute"
  in
  `Assoc
    [ "scope", `String scope
    ; "cache_state", `String cache_state
    ; "projection_surface", diagnostic_field "surface"
    ; "last_success_at", diagnostic_field "last_success_at"
    ; "last_attempt_at", diagnostic_field "last_attempt_at"
    ; "last_error_at", diagnostic_field "last_error_at"
    ; "stale_reason", diagnostic_field "stale_reason"
    ; "stale_age_ms", diagnostic_field "stale_age_ms"
    ; "request_cache_key", Json_util.string_opt_to_json cache_key
    ; "background_refresh_interval_s", `Null
    ; "policy", `String "original changes, semantic deadlines and failed-read recovery"
    ]
;;

let with_cached_dashboard_surface_metadata
      ~(config : Workspace_utils.config)
      ?cache_key
      ~dashboard_surface
      ~source
      ~scope
      ~producer
      ~store_kind
      ~query
      json
  =
  match json with
  | `Assoc fields ->
    let metadata_keys =
      [ "dashboard_surface"
      ; "source"
      ; "generated_at_iso"
      ; "retention"
      ; "query"
      ; "cache"
      ]
    in
    let metadata =
      [ "dashboard_surface", `String dashboard_surface
      ; "source", `String source
      ; "generated_at_iso", `String (cached_surface_generated_at_iso json)
      ; ( "retention"
        , `Assoc
            [ "scope", `String scope
            ; "workspace_root", `String config.base_path
            ; "workspace_path", `String config.workspace_path
            ; "producer", `String producer
            ; "store_kind", `String store_kind
            ; "background_refresh_interval_s", `Null
            ; ( "cache_policy"
              , `String
                  "source-driven cached surface; parameterized HTTP stale-while-revalidate"
              )
            ] )
      ; ( "query", query )
      ; ( "cache"
        , cached_surface_cache_json
            ?cache_key
            ~scope
            json )
      ]
    in
    let fields =
      List.filter (fun (key, _) -> not (List.mem key metadata_keys)) fields
    in
    `Assoc (metadata @ fields)
  | other -> other
;;

let execution_query_json ~actor ~fixture ~full_mode ~light ~default_light_request ~force =
  `Assoc
    [ "actor", Json_util.string_opt_to_json actor
    ; "fixture", Json_util.string_opt_to_json fixture
    ; "full", `Bool full_mode
    ; "light", `Bool light
    ; "default_light_request", `Bool default_light_request
    ; "force", `Bool force
    ]
;;

let default_light_execution_query =
  execution_query_json
    ~actor:None
    ~fixture:None
    ~full_mode:false
    ~light:true
    ~default_light_request:true
    ~force:false
;;

let with_execution_metadata ~config ?cache_key ~query json =
  with_cached_dashboard_surface_metadata
    ~config
    ?cache_key
    ~dashboard_surface:"/api/v1/dashboard/execution"
    ~source:"dashboard_execution_read_model"
    ~scope:"dashboard_execution"
    ~producer:"Dashboard_execution.observe_current"
    ~store_kind:"process_cache"
    ~query
    json
;;

(* The reuse gates serve a body's bytes only while re-projecting it changes
   nothing, so the default-light body is built through the same projection
   the gates read back -- keeper-row overlays, the Candle summary, and the
   observation sequence stamp it sets. The producer's own fill carries all
   three already (its snapshot is projected and its sequence copied); a fill
   that reaches this surface any other way -- a test fixture, a future
   publisher -- becomes a fixed point of the gate here instead of silently
   losing prepared-bytes reuse.

   Built outside the publication lock: the projection reads configuration
   and the Candle ledger from the filesystem, and the lock guards
   publication state, not I/O -- the rule
   {!prepare_execution_snapshot_broadcast} states below. The callers under
   the lock choose what to do; this builds what they chose. *)
let build_default_light_response_json ~owner ~config =
  Server_dashboard_http_cache.cached_surface_json owner.cache
  |> with_execution_observer_instance ~owner
  |> (match Dashboard_execution_helpers.execution_fixture_name () with
      | Some _ -> Fun.id
      | None -> Dashboard_projection_cache.with_current_keeper_observations ~config)
  |> with_execution_metadata
       ~config
       ~cache_key:execution_default_light_cache_key
       ~query:default_light_execution_query
;;

let execution_http_source_matches ~owner ~(config : Workspace.config) (source : execution_http_source) =
  execution_owner_is_current owner
  && source.snapshot == Server_dashboard_http_cache.snapshot owner.cache
  && String.equal source.base_path config.base_path
  && String.equal source.workspace_path config.workspace_path
;;

let rec refresh_execution_default_light_http_body_with ~owner
      ~prepare ~config () =
  let owned = ref None in
  Eio_guard.protect
    ~finally:(fun () ->
      Option.iter
        (fun preparation ->
          with_execution_publication_lock ~owner (fun () ->
            match !(owner.default_light_http) with
            | Preparing current when current == preparation ->
              owner.default_light_http := Empty
            | Empty | Preparing _ | Ready _ -> ());
          Eio.Promise.resolve preparation.settle ())
        !owned)
    (fun () ->
      (* The lock answers which of the three things this call is -- reuse,
         wait, or prepare -- and admits the preparation; the body itself is
         built after it, because building reads the Candle ledger from the
         filesystem and the lock guards publication state, not I/O. *)
      let action =
        with_execution_publication_lock ~owner (fun () ->
          if not (execution_surface_has_fresh_success_unlocked ~owner ()) then
            `Build_fresh
          else
            match !(owner.default_light_http) with
            | Ready payload when execution_http_source_matches ~owner ~config payload.source ->
              `Return payload.response_json
            | Preparing preparation
              when execution_http_source_matches ~owner ~config preparation.source ->
              `Await preparation.settled
            | Empty | Preparing _ | Ready _ ->
              let settled, settle = Eio.Promise.create () in
              let preparation =
                { source =
                    { snapshot = Server_dashboard_http_cache.snapshot owner.cache
                    ; base_path = config.base_path
                    ; workspace_path = config.workspace_path
                    }
                ; settled
                ; settle
                }
              in
              owned := Some preparation;
              owner.default_light_http := Preparing preparation;
              `Prepare preparation)
      in
      match action with
      | `Build_fresh -> build_default_light_response_json ~owner ~config
      | `Return json -> json
      | `Await settled ->
        Eio.Promise.await settled;
        refresh_execution_default_light_http_body_with ~owner ~prepare ~config ()
      | `Prepare preparation ->
        let response_json = build_default_light_response_json ~owner ~config in
        let etag, encoded =
          Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
            let body = Yojson.Safe.to_string response_json in
            Http_server_eio.Response.weak_etag_value body, prepare body)
        in
        with_execution_publication_lock ~owner (fun () ->
          (* An older completion cannot replace or clear a newer preparation. *)
          match !(owner.default_light_http) with
          | Preparing current
            when current == preparation
                 && execution_http_source_matches ~owner ~config preparation.source
                 && execution_surface_has_fresh_success_unlocked ~owner () ->
            owner.default_light_http :=
              Ready { source = preparation.source; response_json; encoded; etag };
            `Published response_json
          | Empty | Preparing _ | Ready _ -> `Build_fresh)
        |> function
        | `Published json -> json
        | `Build_fresh -> build_default_light_response_json ~owner ~config)
;;

let refresh_execution_default_light_http_body ~owner ~config =
  refresh_execution_default_light_http_body_with ~owner
    ~prepare:Http_response_payload.prepare ~config ()
;;

(* Observe the ledger after cached response preparation, outside the publication
   lock, so a completed purchase/equip is not replaced by an older snapshot. *)
let prepare_execution_snapshot_broadcast ~owner ~config () =
  refresh_execution_default_light_http_body ~owner ~config
  |> (match Dashboard_execution_helpers.execution_fixture_name () with
      | Some _ -> Fun.id
      | None -> Dashboard_projection_cache.with_current_keeper_observations ~config)
;;

type execution_read =
  | Published_snapshot of Server_dashboard_http_cache.surface_snapshot * Yojson.Safe.t
  | Unpublished_response of Yojson.Safe.t

let cached_execution_or_first_success ~owner ~clock ~timeout_sec work =
  let cached_success () =
    with_execution_publication_lock ~owner (fun () ->
      if execution_surface_has_fresh_success_unlocked ~owner ()
      then Some (Published_snapshot
        (Server_dashboard_http_cache.snapshot owner.cache,
         Server_dashboard_http_cache.cached_surface_json owner.cache))
      else None)
  in
  match cached_success () with
  | Some json -> json
  | None ->
    let compute_and_track =
      Pool_work.wrap work (fun compute ->
        let attempt = begin_execution_attempt ~owner ~origin:Request_read () in
        try
          let observation = compute () in
          let (_ : bool) = publish_execution_observation attempt observation in
          observation.json
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          let (_ : bool) = publish_execution_attempt_failure attempt exn in
          raise exn)
    in
    let json =
      Dashboard_cache.get_or_compute_with_timeout
        (execution_default_light_cache_key ^ ":" ^ owner.cache_identity)
        ~ttl:deep_surface_cache_ttl_s
        ~clock
        ~timeout_sec
        compute_and_track
    in
    (match cached_success () with
     | Some current -> current
     | None ->
       (* DET-OK: invalidation won the publication race, or an attempt that
          began later published a failure over this one, so this request may
          receive only its own completed value.  It is left unstamped and
          cannot republish either cache; clients with a mutation watermark
          reject identity-less late responses. *)
       Unpublished_response json)
;;

let prepared_execution_payload_for_snapshot ~owner ~config snapshot =
  with_execution_publication_lock ~owner (fun () ->
    match !(owner.default_light_http) with
    | Ready payload
      when payload.source.snapshot == snapshot
           && execution_http_source_matches ~owner ~config payload.source
           && execution_surface_has_fresh_success_unlocked ~owner () ->
      Some (execution_payload_response payload)
    | Empty | Preparing _ | Ready _ -> None)
;;

let with_transport_health_metadata ?(source = "cached_surface") json =
  extend_projection_diagnostics json [ "source", `String source ]
;;

let execution_snapshot_json ~owner () =
  with_execution_publication_lock ~owner (fun () ->
    Server_dashboard_http_cache.cached_surface_json owner.cache)
;;

(* Cache patchers project a typed lifecycle transition onto dashboard row fields
   (keepalive_running / phase / pipeline_stage / paused). Phase-derived events
   and custom events arrive here only after the event-bus
   payload has been decoded by [Keeper_lifecycle_events.lifecycle_event_of_wire].
   The operator pause path constructs [Phase_event Paused] directly. *)

type lifecycle_display =
  { ld_keepalive_running : bool
  ; ld_phase : string
  ; ld_pipeline_stage : string
  ; ld_paused : bool option
  }

(* Exhaustive over the closed custom-event sum. A new [Keeper_lifecycle_events.t]
   variant breaks this match (no catch-all) until its dashboard projection is
   declared. Values are byte-identical to the prior per-field string whitelist. *)
let display_of_custom_event (verb : Keeper_lifecycle_events.t) : lifecycle_display =
  let open Keeper_lifecycle_events in
  match verb with
  | Started | Restarted | Reconciled ->
    { ld_keepalive_running = true; ld_phase = "running"; ld_pipeline_stage = "idle"; ld_paused = Some false }
  | Purged ->
    { ld_keepalive_running = false; ld_phase = "stopped"; ld_pipeline_stage = "offline"; ld_paused = Some false }
  | Admission_denied ->
    (* admission guard refused to launch a fiber *)
    { ld_keepalive_running = false; ld_phase = "offline"; ld_pipeline_stage = "offline"; ld_paused = Some false }
  | Supervisor_cleaned ->
    (* cleanup == no longer alive *)
    { ld_keepalive_running = false; ld_phase = "dead"; ld_pipeline_stage = "offline"; ld_paused = Some false }
;;

let display_of_phase_event = function
  | Keeper_state_machine.Running ->
    Some { ld_keepalive_running = true; ld_phase = "running"; ld_pipeline_stage = "idle"; ld_paused = Some false }
  | Keeper_state_machine.Stopped ->
    Some
      { ld_keepalive_running = false; ld_phase = "stopped"; ld_pipeline_stage = "offline"; ld_paused = None }
  | Keeper_state_machine.Crashed ->
    Some
      { ld_keepalive_running = false; ld_phase = "crashed"; ld_pipeline_stage = "crashed"; ld_paused = Some false }
  | Keeper_state_machine.Paused ->
    Some { ld_keepalive_running = true; ld_phase = "paused"; ld_pipeline_stage = "paused"; ld_paused = Some true }
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Failing
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Restarting ->
    None
;;

let lifecycle_display_of_event = function
  | Keeper_lifecycle_events.Custom_event { verb; _ } ->
    Some (display_of_custom_event verb)
  | Keeper_lifecycle_events.Phase_event phase ->
    display_of_phase_event phase
;;

let keepalive_running_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_keepalive_running) (lifecycle_display_of_event event)
;;

let phase_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_phase) (lifecycle_display_of_event event)
;;

let pipeline_stage_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_pipeline_stage) (lifecycle_display_of_event event)
;;

let paused_of_lifecycle_event event =
  Option.bind (lifecycle_display_of_event event)
    (fun (d : lifecycle_display) -> d.ld_paused)
;;

let keeper_top_level_status_opt row =
  match Json_util.assoc_member_opt "status" row with
  | Some (`String status) -> Some status
  | _ -> None
;;

let lifecycle_display_for_row row event =
  match
    ( event
    , Option.bind
        (keeper_top_level_status_opt row)
        Keeper_status_runtime.control_plane_status_of_string_opt )
  with
  | ( Keeper_lifecycle_events.Custom_event
        { verb = Keeper_lifecycle_events.Reconciled; _ }
    , Some Keeper_status_runtime.Cp_paused ) ->
    display_of_phase_event Keeper_state_machine.Paused
  | ( ( Keeper_lifecycle_events.Custom_event
          { verb =
              ( Keeper_lifecycle_events.Started
              | Keeper_lifecycle_events.Restarted
              | Keeper_lifecycle_events.Supervisor_cleaned
              | Keeper_lifecycle_events.Purged
              | Keeper_lifecycle_events.Admission_denied )
          ; _
          }
      | Keeper_lifecycle_events.Phase_event _ )
    , _ )
  | ( Keeper_lifecycle_events.Custom_event
        { verb = Keeper_lifecycle_events.Reconciled; _ }
    , (None | Some (Keeper_status_runtime.Cp_surface _)) ) ->
    lifecycle_display_of_event event
;;

let control_status_override_of_lifecycle_event row event =
  match lifecycle_display_for_row row event with
  | Some { ld_paused = Some true; _ } ->
    Some Keeper_status_runtime.Cp_paused
  | Some _ | None ->
    (match event with
  | Keeper_lifecycle_events.Phase_event Keeper_state_machine.Running ->
    Some
      (Keeper_status_runtime.Cp_surface
         Keeper_status_runtime.Surface_idle)
  | Keeper_lifecycle_events.Phase_event Keeper_state_machine.Stopped ->
    (match
       Option.bind
         (keeper_top_level_status_opt row)
         Keeper_status_runtime.control_plane_status_of_string_opt
     with
     | Some Keeper_status_runtime.Cp_paused ->
       Some Keeper_status_runtime.Cp_paused
     | Some (Keeper_status_runtime.Cp_surface _) | None -> None)
  | Keeper_lifecycle_events.Custom_event _
  | Keeper_lifecycle_events.Phase_event
      ( Keeper_state_machine.Offline
      | Keeper_state_machine.Failing
      | Keeper_state_machine.Draining
      | Keeper_state_machine.Paused
      | Keeper_state_machine.Crashed
      | Keeper_state_machine.Restarting ) ->
    None)
;;

let patched_keeper_status row ~event ~keepalive_running =
  match control_status_override_of_lifecycle_event row event with
  | Some status ->
    `String (Keeper_status_runtime.control_plane_status_to_string status)
  | None when not keepalive_running -> `String "offline"
  | None ->
    (* RFC-0089: classify the row's display status via the typed operator
       SSOT. busy/active/listening/idle pass through; inactive/offline collapse
       to "offline"; an operator pause survives the patch, because a running
       keepalive fiber does not un-pause a keeper — collapsing it here made
       the rebuilt continuity brief read the row as live. Missing or unknown
       values fail loudly instead of manufacturing an idle keeper. *)
    let status =
      match keeper_top_level_status_opt row with
      | Some status -> status
      | None ->
        invalid_arg
          "dashboard execution cache: keeper row has no current status"
    in
    match Keeper_status_runtime.control_plane_status_of_string_opt status with
    | Some (Cp_surface s) ->
      `String (Keeper_status_runtime.surface_status_to_string s)
    | Some Cp_paused ->
      `String
        (Keeper_status_runtime.control_plane_status_to_string
           Keeper_status_runtime.Cp_paused)
    | None ->
      invalid_arg
        (Printf.sprintf
           "dashboard execution cache: unknown current keeper status %S"
           status)
;;

(* A lifecycle event reaches a published keeper list as a patch of the named
   row. A declaration row ([Keeper_declared_roster]) is a Keeper the snapshot
   saw before it ever booted: it has no diagnostic or trust to become a runtime
   row from, and a lifecycle event for it means boot has since touched that
   Keeper. So the row is not patched; the surface holding it is stale and has
   to be rebuilt from a fresh snapshot. *)
type 'rows row_patch =
  | Patched of 'rows
  | Declaration_row_is_stale

let patch_runtime_row ~event ~keepalive_running fields row =
  let lifecycle_display = lifecycle_display_for_row row event in
  let row_fields : (string * Yojson.Safe.t) list = fields in
  let row_fields =
    row_fields
    |> upsert_assoc_field "keepalive_running" (`Bool keepalive_running)
    |> upsert_assoc_field
         "status"
         (patched_keeper_status row ~event ~keepalive_running)
  in
  let row_fields =
    match lifecycle_display with
    | Some { ld_paused = Some paused; _ } ->
      upsert_assoc_field "paused" (`Bool paused) row_fields
    | Some { ld_paused = None; _ } | None -> row_fields
  in
  let row_fields =
    match lifecycle_display with
    | Some { ld_phase; _ } ->
      upsert_assoc_field "phase" (`String ld_phase) row_fields
    | None -> row_fields
  in
  let row_fields =
    match lifecycle_display with
    | Some { ld_pipeline_stage; _ } ->
      upsert_assoc_field
        "pipeline_stage"
        (`String ld_pipeline_stage)
        row_fields
    | None -> row_fields
  in
  `Assoc row_fields
;;

let patch_keeper_row ~keeper_name ~event ~keepalive_running = function
  | `Assoc fields as row ->
    (match Json_util.assoc_member_opt "name" row with
     | Some (`String name) when String.equal name keeper_name ->
       (match Keeper_declared_roster.row_kind_of_json row with
        | Ok Keeper_declared_roster.Runtime_row ->
          Patched (patch_runtime_row ~event ~keepalive_running fields row)
        | Ok Keeper_declared_roster.Declaration_row -> Declaration_row_is_stale
        | Error detail ->
          invalid_arg
            (Printf.sprintf
               "dashboard execution cache: keeper %S: %s"
               name
               detail))
     | _ -> Patched row)
  | other -> Patched other
;;

let patch_keeper_rows ~keeper_name ~event ~keepalive_running rows =
  let rec loop acc = function
    | [] -> Patched (List.rev acc)
    | row :: rest ->
      (match patch_keeper_row ~keeper_name ~event ~keepalive_running row with
       | Patched patched_row -> loop (patched_row :: acc) rest
       | Declaration_row_is_stale -> Declaration_row_is_stale)
  in
  loop [] rows
;;

let replace_keeper_rows_and_rebuild_briefs ~now_ts ~keeper_rows ~keepers_json fields =
  let fields = upsert_assoc_field "keepers" keepers_json fields in
  match List.assoc_opt "continuity_briefs" fields with
  | Some (`List _) ->
    upsert_assoc_field
      "continuity_briefs"
      (`List
        (Dashboard_execution_builders.build_continuity_briefs ~now_ts keeper_rows
         |> List.map (fun (row : Dashboard_execution_helpers.continuity_context) ->
           row.json)))
      fields
  | Some _ | None -> fields
;;

let running_keeper_names (config : Workspace.config) =
  (match Keeper_meta_store.keeper_names_result config with
   | Ok names -> names
   | Error detail ->
     Log.Keeper.warn "running_keeper_names: keeper names unread: %s" detail;
     [])
  |> List.filter_map (fun name ->
    match Keeper_meta_store.read_meta config name with
    | Ok (Some meta) when Keeper_status_bridge.runtime_keepalive_running config meta ->
      Some name
    | Ok (None) | Error _ | Ok (Some _) -> None)
;;

let patch_surface_json_for_running_keepers (config : Workspace.config) = function
  | `Assoc fields as json ->
    let running = running_keeper_names config in
    if running = []
    then json
    else (
      let patch_rows rows =
        List.fold_left
          (fun acc keeper_name ->
             match
               patch_keeper_rows
                 ~keeper_name
                 ~event:
                   (Keeper_lifecycle_events.Custom_event
                      { verb = Keeper_lifecycle_events.Reconciled
                      ; phase = None
                      })
                 ~keepalive_running:true
                 acc
             with
             | Patched rows -> rows
             | Declaration_row_is_stale ->
               (* The snapshot this render read was taken before this Keeper
                  booted, so its row is still a declaration row. It stays as
                  the snapshot described it: it has no diagnostic or trust to
                  build a runtime row from.

                  The boot publishes a lifecycle event. Its handler
                  ([Server_dashboard_http_keeper_api.refresh_keeper_execution_surfaces])
                  drops the operator snapshot caches and the [execution:] read
                  caches, then patches the cached surface
                  ([patchexecution_cache_for_keeper]). The patch advances the
                  publication generation, so a render that began before it
                  can no longer publish, and it invalidates the cached surface
                  when that surface holds this declaration row.

                  The listener ([Server_bootstrap_loops]) refreshes each
                  event on its own. When its subscription reports events
                  dropped past its capacity, or a refresh raises or reports a
                  prefix it could not drop, it drops
                  the same caches for every Keeper
                  ([Server_dashboard_http_keeper_api_lifecycle_post.invalidate_keeper_execution_surfaces]),
                  the cached surface included, so the row clears as it would
                  with the event handled.

                  On a cold start the cached surface can still be the
                  initializing placeholder. It has no keepers row, so the
                  patch has nothing to invalidate in it; the handler's cache
                  drops above are what clear a pre-boot render.

                  The source observer also subscribes to the original Keeper
                  lifecycle and metadata inputs before its initial read.
                  Its current read bypasses the nested metadata TTLs. The
                  last-good declaration remains visible until a successful
                  read replaces it; actual failures retain retry debt. There
                  is no healthy periodic refresh as a fallback. *)
               acc)
          rows
          running
      in
      match List.assoc_opt "keepers" fields with
      | Some (`List rows) ->
        let keeper_rows = patch_rows rows in
        if keeper_rows = rows
        then json
        else
          `Assoc
            (replace_keeper_rows_and_rebuild_briefs
               ~now_ts:(Time_compat.now ())
               ~keeper_rows
               ~keepers_json:(`List keeper_rows)
               fields)
      | Some (`Assoc keeper_fields) ->
        (match List.assoc_opt "items" keeper_fields with
         | Some (`List rows) ->
           let keeper_rows = patch_rows rows in
           if keeper_rows = rows
           then json
           else (
             let keeper_fields =
               upsert_assoc_field "items" (`List keeper_rows) keeper_fields
             in
             `Assoc
               (replace_keeper_rows_and_rebuild_briefs
                  ~now_ts:(Time_compat.now ())
                  ~keeper_rows
                  ~keepers_json:(`Assoc keeper_fields)
                  fields))
         | _ -> json)
      | _ -> json)
  | other -> other
;;

let patchexecution_cache_for_keeper ~owner ~keeper_name ~event ~keepalive_running =
  if Option.is_none (Dashboard_execution_helpers.execution_fixture_name ()) then
  let patch =
    with_execution_publication_lock ~owner (fun () ->
      owner.generation := next_execution_generation ();
      let generation = !(owner.generation) in
      clear_execution_default_light_http_body ~owner ();
      let publish json =
        incr owner.namespace_revision;
        let json = with_execution_publication_generation ~owner ~generation json in
        Server_dashboard_http_cache.update_cached_surface owner.cache
          (fun current -> { current with json });
        Patched ()
      in
      match (Server_dashboard_http_cache.snapshot owner.cache).json with
      | `Assoc fields ->
        (match List.assoc_opt "keepers" fields with
         | Some (`List rows) ->
           (match patch_keeper_rows ~keeper_name ~event ~keepalive_running rows with
            | Declaration_row_is_stale -> Declaration_row_is_stale
            | Patched keeper_rows ->
              if keeper_rows = rows
              then publish (`Assoc fields)
              else
                publish
                  (`Assoc
                    (replace_keeper_rows_and_rebuild_briefs
                       ~now_ts:(Time_compat.now ())
                       ~keeper_rows
                       ~keepers_json:(`List keeper_rows)
                       fields)))
         | Some _ | None -> publish (`Assoc fields))
      | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
        Patched ())
  in
  (* Invalidation takes the publication lock itself and broadcasts outside it,
     so it runs after the patch has released the lock. *)
  match patch with
  | Patched () -> notify_execution_completion owner Cache_patched
  | Declaration_row_is_stale -> invalidate_execution_owner_with ~owner ~before_broadcast:(fun () -> ()) ()
;;

let patch_keeper_dependent_caches ~keeper_name ~event =
  match keepalive_running_of_lifecycle_event event with
  | None -> ()
  | Some keepalive_running ->
    Option.iter (fun owner -> patchexecution_cache_for_keeper ~owner ~keeper_name ~event ~keepalive_running)
      (current_execution_owner ())
;;

(** Late-bound broadcast hook. Set after [broadcast_namespace_truth_snapshot]
    is defined in [Server_dashboard_http_namespace_truth]. *)
let broadcast_namespace_truth_ref : (Mcp_server.server_state -> unit) ref =
  ref (fun (_state : Mcp_server.server_state) -> ())
;;

let compute_execution_observation ~state ~config ~sw ~clock ?net ?mono_clock () =
  let started_at = Unix.gettimeofday () in
  run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ?net ?mono_clock
    ~config ~kind:Pool_work.Cpu ~name:__FUNCTION__ (fun ~config ~sw ->
      let observation = Dashboard_execution.observe_current ~light:true ~config
          ~sw ~clock ~proc_mgr:state.Mcp_server.proc_mgr () in
      let json = observation.json
        |> (match Dashboard_execution_helpers.execution_fixture_name () with
            | Some _ -> Fun.id
            | None -> patch_surface_json_for_running_keepers config)
        |> Server_dashboard_http_core_cache.with_projection_diagnostics
             ~surface:"execution" ~started_at
             ~extra:["readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json ()] in
      {observation with json})
;;

module Execution_completions = Server_workspace_invalidation.Make (struct
  type t = unit
  let compare () () = 0
end)

let start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock =
  let timeout_s = float_of_env_default "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:48.0 ~min_v:30.0 ~max_v:300.0 in
  Server_observation_refresh.install_scoped ~state ~sw
    ~install:(fun ~scope ~sw ~is_current ->
      let owner = execution_owner_for_scope ~state scope in
      let changes = Eio.Stream.create 1 in
      let changes_mu = Stdlib.Mutex.create () in
      let changed () = Stdlib.Mutex.protect changes_mu (fun () ->
        if Eio.Stream.is_empty changes then Eio.Stream.add changes ()) in
      Server_observation_input.subscribe ~sw ~base_path:scope.config.base_path
        ~observer_instance_id:(Server_observer_scope.instance_id scope)
        (fun input ->
          if Server_observation_refresh.affects Execution input then changed ());
      let enqueue_completion = ref (fun () -> ()) in
      let publish_current () =
        let selected = with_execution_publication_lock ~owner (fun () ->
          let snapshot = Server_dashboard_http_cache.snapshot owner.cache in
          if Option.is_some snapshot.last_success_unix || Option.is_some snapshot.last_error_unix
          then Some snapshot else None) in
        Option.iter (fun snapshot ->
          if is_current () then (
            let still_current () = is_current () && execution_owner_is_current owner
              && snapshot == Server_dashboard_http_cache.snapshot owner.cache in
            let json = prepare_execution_snapshot_broadcast ~owner ~config:scope.config () in
            broadcast_cached_surface ~target:owner.target
              ~encoding:(Encode_on_pool {still_current; on_superseded = (fun () -> !enqueue_completion ())})
              ~event_type:Dashboard_event_slices.execution_snapshot_type json;
            if still_current () then !broadcast_namespace_truth_ref state)) selected
      in
      let enqueue = Execution_completions.start ~sw ~mono_clock
          ~publish:(fun () -> publish_current ()) in
      enqueue_completion := (fun () -> enqueue ());
      let unsubscribe = subscribe_execution_completion ~owner (fun completion ->
        (* Request completions and lifecycle patches can supersede a source
           attempt. A patch retains a trailing read even if the original
           lifecycle hint was already consumed by that attempt. The source
           worker's own output never wakes another source computation. *)
        (match completion with
         | Cache_installed Request_read | Cache_failed Request_read | Cache_patched -> changed ()
         | Cache_installed Observation_read | Cache_failed Observation_read | Shell_installed -> ());
        enqueue ()) in
      Eio.Switch.on_release sw unsubscribe;
      (* An HTTP fill may have won before this subscription was installed. *)
      enqueue ();
      let latest_attempt = ref None in
      Proactive_refresh.start_on_change_or_deadline ~sw ~clock ~changes
        ~config:{(Proactive_refresh.default_config ~label:"execution" ~interval_s:60.0) with
          timeout_s; warm_delay_s = 0.0;
          on_failure = Some (fun failure ->
            if is_current () then Option.iter (fun attempt ->
              ignore (publish_execution_attempt_failure_message attempt
                (Proactive_refresh.failure_message failure))) !latest_attempt)}
        ~compute:(fun () ->
          let attempt = begin_execution_attempt ~owner ~origin:Observation_read () in
          latest_attempt := Some attempt;
          try
            let observation = compute_execution_observation ~state ~config:scope.config
                ~sw ~clock ~net ~mono_clock () in
            (* The reusable worker reads the next deadline before on_result.
               Install the known successful observation before returning it;
               the attempt CAS preserves it if the outer window also fails. *)
            ignore (publish_execution_observation attempt observation);
            attempt, observation
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> ignore (publish_execution_attempt_failure attempt exn); raise exn)
        ~on_result:(fun _ -> ())
        ~next_deadline:(fun _ -> with_execution_publication_lock ~owner
          (fun () -> !(owner.next_deadline_unix))))
;;

type execution_parameters =
  { fixture : string option
  ; actor : string option
  ; full_mode : bool
  ; force : bool
  }

let execution_parameters ~(config : Workspace.config) request =
  let fixture = query_param request "fixture" in
  let actor = execution_actor_for_request ~base_path:config.base_path request in
  let full_mode = bool_query_param request "full" ~default:false in
  let force = bool_query_param request "force" ~default:false in
  { fixture; actor; full_mode; force }

type execution_http_request =
  { state : Mcp_server.server_state
  ; config : Workspace.config
  ; parameters : execution_parameters
  ; owner : execution_owner
  }

let execution_http_request ~state request =
  let scope = Mcp_server.workspace_scope state in
  let config = scope.config in
  let owner = execution_owner_for_scope ~state scope in
  let parameters = execution_parameters ~config request in
  { state; config; owner; parameters }

let execution_cached_http_response ~owner ~observe ~(config : Workspace.config)
      ~(parameters : execution_parameters) =
  let { fixture = requested_fixture; actor; full_mode; force } = parameters in
  let fixture =
    Dashboard_execution_helpers.execution_fixture_name ?fixture:requested_fixture ()
  in
  match fixture, actor, full_mode, force with
  | None, None, false, false when requested_fixture = None ->
    let selected = with_execution_publication_lock ~owner (fun () ->
      match !(owner.default_light_http) with
      | Ready payload
        when execution_surface_has_fresh_success_unlocked ~owner ()
             && execution_http_source_matches ~owner ~config payload.source ->
        Some payload
      | Empty | Preparing _ | Ready _ -> None) in
    (match selected with
     | None -> None
     | Some payload ->
       let json = observe ~config payload.response_json in
       (* Observation performs I/O. A mutation or newer publication while it
          yields must take the fallback rather than returning detached data.
          Compare immutable JSON outside the short publication lock. *)
       let response =
         if json = payload.response_json
         then Execution_payload (execution_payload_response payload)
         else Execution_json json in
       with_execution_publication_lock ~owner (fun () ->
         if execution_surface_has_fresh_success_unlocked ~owner ()
            && execution_http_source_matches ~owner ~config payload.source
         then Some response
         else None))
  | _ -> None
;;

let dashboard_execution_cached_http_response context =
  let owner = context.owner in
  execution_cached_http_response ~owner
    ~observe:Dashboard_projection_cache.with_current_keeper_observations
    ~config:context.config ~parameters:context.parameters
;;

module For_testing = struct
  type owner = execution_owner
  type nonrec execution_attempt = execution_attempt

  let create_owner () =
    let owner = create_execution_owner None in
    Stdlib.Mutex.protect active_execution_owner_mu (fun () ->
      active_execution_owner := Some owner);
    owner
  let owner_for_state ~state =
    execution_owner_for_scope ~state (Mcp_server.workspace_scope state)
  let cache owner = owner.cache
  let invalidate owner =
    Stdlib.Mutex.protect active_execution_owner_mu (fun () ->
      active_execution_owner := Some owner);
    invalidate_execution_owner_with ~owner ~before_broadcast:(fun () -> ()) ()
  let cached_response
      ?(observe = Dashboard_projection_cache.with_current_keeper_observations)
      ~owner ~config request =
    let parameters = execution_parameters ~config request in
    execution_cached_http_response ~owner ~observe ~config ~parameters
  let execution_publication_generation = current_execution_publication_generation
  let publish_execution_success_if_current ~owner ~generation json =
    publish_execution_attempt_success
      { (execution_attempt_now ~owner ~origin:Observation_read ()) with generation } json
  let begin_execution_attempt ~owner () =
    begin_execution_attempt ~owner ~origin:Observation_read ()
  let publish_execution_attempt_success = publish_execution_attempt_success
  let publish_execution_attempt_failure = publish_execution_attempt_failure
  let publish_execution_attempt_failure_message = publish_execution_attempt_failure_message
  let refresh_execution_default_light_http_body
        ?(prepare = Http_response_payload.prepare) ~owner ~config () =
    refresh_execution_default_light_http_body_with ~owner ~prepare ~config ()
  let prepare_execution_snapshot_broadcast = prepare_execution_snapshot_broadcast
  let prepared_payload_for_snapshot = prepared_execution_payload_for_snapshot
end
;;

let start_transport_health_refresh_loop ~state ~sw ~clock =
  let timeout_s =
    float_of_env_default
      "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      ~default:transport_health_timeout_default_s
      ~min_v:transport_health_timeout_min_s
      ~max_v:transport_health_timeout_max_s
  in
  let compute () =
    Server_dashboard_http_cache.mark_cached_surface_attempt transport_health_cache;
    Transport_metrics.transport_health_json ()
  in
  let broadcast_snapshot () =
    broadcast_cached_surface
      ~encoding:Encode_inline
      ~event_type:Dashboard_event_slices.transport_health_snapshot_type
      (Server_dashboard_http_cache.cached_surface_json transport_health_cache
       |> with_transport_health_metadata)
  in
  let interval_s = 30.0 in
  Server_observation_refresh.start ~state ~sw ~clock
    ~surface:Server_observation_refresh.Transport_health
    ~generation:(fun ~scope:_ ~sw:_ ->
      { Server_observation_refresh.config =
        { (Proactive_refresh.default_config ~label:"transport_health" ~interval_s) with
        timeout_s
      ; on_failure =
          Some
            (fun failure ->
              Server_dashboard_http_cache.mark_cached_surface_error_message
                transport_health_cache
                (Proactive_refresh.failure_message failure);
              broadcast_snapshot ())
      ; warm_delay_s = 0.0
        }
      ; compute
      ; on_result = (fun json ->
          Server_dashboard_http_cache.mark_cached_surface_success transport_health_cache json;
          broadcast_snapshot ())
      ; next_deadline = (fun _ -> None)
      })
;;

let compute_execution_trust_observation ~state ~config ~sw ~clock =
  (* NDT-OK: wall-clock is projection timing telemetry only; execution-trust
     content and routing do not branch on this value. *)
  let started_at = Unix.gettimeofday () in
  run_dashboard_compute
    ~mode:Offloaded_readonly
    ?net:state.Mcp_server.net
    ?mono_clock:state.Mcp_server.mono_clock
    ~sw
    ~clock
    ~config
    ~kind:Pool_work.Cpu ~name:__FUNCTION__
    (fun ~config ~sw:_ ->
       let json, deadline = Dashboard_http_keeper.execution_trust_dashboard_observation config in
       let json = Server_dashboard_http_core_cache.with_projection_diagnostics
            ~surface:"execution_trust"
            ~started_at
            ~extra:[] json in
       json, deadline)
;;

let start_execution_trust_refresh_loop ~state ~sw ~clock =
  Server_observation_refresh.start ~state ~sw ~clock ~surface:Execution_trust
    ~generation:(fun ~scope ~sw ->
      let cache = execution_trust_cache_for_scope ~state scope in
      let announce () =
        (* Source invalidation can be consumed before this read finishes.
           Publish completion too, so the last-good cache is not mistaken for
           the answer to that invalidation. Dashboard observations are output
           only: the input decoder never feeds this back into the worker. *)
        Dashboard_observation_commit.written
          ~base_path:scope.config.base_path ~scope:`Workspace `Telemetry
      in
      { Server_observation_refresh.config =
          { (Proactive_refresh.default_config
               ~label:"execution_trust"
               ~interval_s:Dashboard_http_keeper_types.execution_trust_refresh_interval_s)
            with
            timeout_s = Env_config_runtime.Dashboard.execution_trust_timeout_sec;
            on_failure = Some (fun failure ->
                Server_dashboard_http_cache.mark_cached_surface_error_message
                  cache (Proactive_refresh.failure_message failure);
                announce ());
            warm_delay_s = 0.0 }
      ; compute = (fun () ->
          Server_dashboard_http_cache.mark_cached_surface_attempt cache;
          compute_execution_trust_observation ~state ~config:scope.config ~sw ~clock)
      ; on_result = (fun (json, _) ->
          Server_dashboard_http_cache.mark_cached_surface_success
            cache json;
          announce ())
      ; next_deadline = snd
      })
;;

let cached_dashboard_execution_http_response ~sw ~clock context =
  let owner = context.owner in
  let state = context.state in
  let config = context.config in
  let net = state.Mcp_server.net in
  let mono_clock = state.Mcp_server.mono_clock in
  let { fixture = requested_fixture; actor; full_mode; force } = context.parameters in
  let fixture = Dashboard_execution_helpers.execution_fixture_name ?fixture:requested_fixture () in
  let light = not full_mode in
  let query =
    execution_query_json
      ~actor
      ~fixture
      ~full_mode
      ~light
      ~default_light_request:(requested_fixture = None && fixture = None && actor = None && not full_mode && not force)
      ~force
  in
  let compute ?actor ~light () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute
      ~mode:Offloaded_readonly
      ?net
      ?mono_clock
      ~sw
      ~clock
      ~config
      ~kind:Pool_work.Cpu ~name:__FUNCTION__
      (fun ~config ~sw ->
         Dashboard_execution.observe_current
           ?actor
           ?fixture:requested_fixture
           ~light
           ~config
           ~sw
           ~clock
           ~proc_mgr:state.Mcp_server.proc_mgr
           ()
         |> fun observation -> observation.Dashboard_execution.json
         |> (match fixture with
             | Some _ -> Fun.id
             | None -> patch_surface_json_for_running_keepers config)
         |> Server_dashboard_http_core_cache.with_projection_diagnostics
              ~surface:"execution"
              ~started_at
              ~extra:
                [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json ()
                ])
  in
  match fixture, actor, full_mode with
  | None, None, false when requested_fixture = None && force ->
    let timeout_sec = Env_config_runtime.Dashboard.execution_timeout_sec in
    let attempt = ref None in
    let publish_failure exn =
      Option.iter
        (fun attempt ->
          let (_ : bool) = publish_execution_attempt_failure attempt exn in
          ())
        !attempt
    in
    let compute_and_track () =
      let this_attempt = begin_execution_attempt ~owner ~origin:Request_read () in
      attempt := Some this_attempt;
      try
        let observation = compute_execution_observation ~state ~config ~sw ~clock ?net ?mono_clock () in
        if publish_execution_observation this_attempt observation
        then (
          let (_ : Yojson.Safe.t) =
            refresh_execution_default_light_http_body ~owner ~config
          in
          execution_snapshot_json ~owner ())
        else observation.json
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        publish_failure exn;
        raise exn
    in
    (* A refresh that finished, and published, as its window closed is the
       result: the window's error must not be published over it. *)
    (match
       Watched_work.run
         ~watcher:(fun () ->
           Eio.Time.sleep clock timeout_sec;
           Error `Timeout)
         (fun () -> Ok (compute_and_track ()))
     with
     | Ok json -> json
     | Error `Timeout ->
       let role = Dashboard_cache.Compute_owner in
       publish_failure
         (Dashboard_cache.Compute_timeout
            { key = execution_default_light_cache_key; role });
       Log.Dashboard.warn
         "dashboard execution force refresh timed out: %s (%.0fs)"
         execution_default_light_cache_key
         timeout_sec;
       Dashboard_cache.timeout_envelope_json
         ~kind:(Dashboard_cache.timeout_kind_of_role role)
         ~key:execution_default_light_cache_key
         ~timeout_sec)
    |> with_execution_metadata
         ~config
         ~cache_key:execution_default_light_cache_key
         ~query
    |> fun json -> Execution_json json
  | None, None, false when requested_fixture = None ->
    (* Default light mode: stay instant after first success, but avoid
         serving the empty initializing payload forever when proactive warm-up
         misses its first build window. *)
    let selected =
      cached_execution_or_first_success ~owner
        ~clock
        ~timeout_sec:Env_config_runtime.Dashboard.execution_timeout_sec
        (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
          compute_execution_observation ~state ~config ~sw ~clock ?net ?mono_clock ()))
    in
    let json = match selected with
      | Published_snapshot (_, json) | Unpublished_response json -> json
    in
    let response_json =
      with_execution_metadata
        ~config
        ~cache_key:execution_default_light_cache_key
        ~query
        json
    in
    let (_ : Yojson.Safe.t) = refresh_execution_default_light_http_body ~owner ~config in
    (* Preparation may yield to a mutation or another publication. Reuse only
       the selected snapshot's bytes; a newer Ready payload cannot replace
       this request's already chosen response. A lost/failed publication keeps
       the JSON fallback, including its original generation and diagnostics. *)
    (match selected with
     | Unpublished_response _ -> Execution_json response_json
     | Published_snapshot (snapshot, _) ->
       match prepared_execution_payload_for_snapshot ~owner ~config snapshot with
       | Some payload -> Execution_payload payload
       | None -> Execution_json response_json)
  | _ ->
    (* Authenticated dashboards use this path too. Cache the complete response
       so repeat reads retain its bytes instead of serializing the projection
       again. Scope every input that contributes to the response metadata. *)
    let generation, publication_ticket = current_execution_http_revision ~owner () in
    let cache_key =
      "execution:parameterized:"
      ^ Yojson.Safe.to_string
          (`List
             [ `String owner.cache_identity; `String config.base_path; `String config.workspace_path;
               `String (Workspace.masc_dir config);
               `Int generation; `Int publication_ticket; query ])
    in
    let compute_with_generation = Pool_work.cpu ~name:__FUNCTION__ @@ fun () ->
      compute ?actor ~light ()
      (* The request wrapper below re-projects every non-fixture response and
         serves the cached payload's bytes only when that changes nothing, so
         the parameterized fill projects here first -- same rule as the
         default-light body above. Without it a fill whose keepers came from
         the fixture-seeded cache rather than a projected snapshot carries no
         observation stamp, and every repeat request recomputes instead of
         reusing the bytes it already prepared. An explicit fixture is the
         exception both places: its Candle, portraits and balances are
         synthetic by contract, and the wrapper skips its gate for fixture
         requests -- so the fill leaves them alone too. *)
      |> (match fixture with
          | None -> Dashboard_projection_cache.with_current_keeper_observations ~config
          | Some _ -> fun json -> json)
      |> with_execution_publication_generation ~owner ~generation
      |> with_execution_metadata ~config ~cache_key ~query
    in
    let payload =
      Dashboard_cache.get_or_compute_payload_with_timeout
        ~preparation:Dashboard_cache.Http_encodings
        cache_key
        ~ttl:deep_surface_cache_ttl_s
        ~clock
        ~timeout_sec:Env_config_runtime.Dashboard.execution_timeout_sec
        compute_with_generation
    in
    if Dashboard_cache.is_timeout_envelope payload.json then
      (* Owner/waiter/circuit timeouts are generated outside [compute]. They
         still need this request's metadata and must not become cached success. *)
      Execution_json
        (with_execution_metadata ~config ~cache_key ~query payload.json)
    else Execution_payload payload
;;

let dashboard_execution_http_response ~sw ~clock context =
  let response = cached_dashboard_execution_http_response ~sw ~clock context in
  let refresh json =
    let json = with_execution_observer_instance ~owner:context.owner json in
    match Dashboard_execution_helpers.execution_fixture_name ?fixture:context.parameters.fixture () with
    | Some _ -> json
    | None -> Dashboard_projection_cache.with_current_keeper_observations ~config:context.config json in
  match response with
  | Execution_json json -> Execution_json (refresh json)
  | Execution_payload payload ->
      let json = refresh payload.json in
      if json = payload.json then response else Execution_json json
;;

let dashboard_execution_http_json ~state ~sw ~clock request =
  let context = execution_http_request ~state request in
  match dashboard_execution_http_response ~sw ~clock context with
  | Execution_json json -> json
  | Execution_payload payload -> payload.json
;;

let dashboard_execution_trust_http_json ~state ~sw ~clock _request =
  let scope = Mcp_server.workspace_scope state in
  let cache = execution_trust_cache_for_scope ~state scope in
  let scoped_cache_key = execution_trust_cache_key ^ ":"
    ^ Mcp_server.Workspace_scope_epoch.to_string scope.epoch in
  let attach_surface_envelope json =
    Server_dashboard_surface.attach
      ~surface:Dashboard_http_keeper_types.execution_trust_dashboard_surface
      ~source:Dashboard_http_keeper_types.execution_trust_source
      ~cache_key:scoped_cache_key
      ~ttl_s:shell_surface_cache_ttl_s
      json
  in
  let has_success =
    Server_dashboard_http_cache.cached_surface_has_success cache
  in
  let json =
    if has_success
    then
      Server_dashboard_http_cache.cached_surface_json cache
    else
      Server_dashboard_http_cache.cached_surface_or_first_success_json
        cache
        ~cache_key:scoped_cache_key
        ~ttl:shell_surface_cache_ttl_s
        ~clock
        ~timeout_sec:Env_config_runtime.Dashboard.execution_trust_timeout_sec
        (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
           fst (compute_execution_trust_observation
             ~state ~config:scope.config ~sw ~clock)))
  in
  attach_surface_envelope json
;;

let dashboard_transport_health_http_json ~state:_ =
  (* An explicit HTTP read observes current mirror/delivery costs too. Keep
     its formatting cell local: a manual sample must not overwrite or signal
     the asynchronous source worker's publication. *)
  let json = Transport_metrics.transport_health_json () in
  let response = Server_dashboard_http_cache.create_cached_surface json in
  Server_dashboard_http_cache.mark_cached_surface_success response json;
  Server_dashboard_http_cache.cached_surface_json response
  |> with_transport_health_metadata ~source:"live_read"
;;
