module Cache = Server_dashboard_http_cache

type origin = Source_read | Default_request
type completion = Installed of origin | Failed of origin | Source_changed | Invalidated
type publication_status = Current | Superseded | Source_pending | Retired
type observation_state = Initializing | Mutation_invalidated | Ready | Read_failed
type listener = {completed : completion -> unit}

type publication = {
  json : Yojson.Safe.t;
  state : observation_state;
}

type owner = {
  state : Mcp_server.server_state;
  scope : Mcp_server.workspace_scope;
  identity : string;
  cache : Cache.cached_surface;
  mu : Stdlib.Mutex.t;
  mutation_generation : int ref;
  source_revision : int ref;
  admitted_revision : int ref;
  compute_sequence : int ref;
  terminal_sequence : int ref;
  next_deadline : float option ref;
  retained_completeness : Dashboard_projection_read.completeness option ref;
  canonical : publication ref;
  listeners : listener list Atomic.t;
}

type attempt = {owner : owner; mutation_generation : int; sequence : int; origin : origin}

let compute_sequence = Atomic.make 0
let publication_epoch =
  (* NDT-OK: process-incarnation identity entropy only. *)
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let with_metadata ~identity ~generation ~compute_sequence ~terminal_sequence
    ~next_deadline ~state = function
  | `Assoc fields ->
      let state = match state with
        | Initializing -> "initializing" | Mutation_invalidated -> "invalidated"
        | Ready -> "ready" | Read_failed -> "error" in
      let keys = ["snapshot_epoch"; "snapshot_generation"; "snapshot_compute_sequence";
        "snapshot_terminal_sequence"; "snapshot_fresh_until_unix";
        "snapshot_observation_state"; "observer_instance_id"] in
      `Assoc (["snapshot_epoch", `String publication_epoch;
        "snapshot_generation", `Int generation;
        "snapshot_compute_sequence", `Int compute_sequence;
        "snapshot_terminal_sequence", `Int terminal_sequence;
        "snapshot_fresh_until_unix", Json_util.float_opt_to_json next_deadline;
        "snapshot_observation_state", `String state;
        "observer_instance_id", `String identity]
        @ List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid_arg "Operator Snapshot projection must be a JSON object"

let placeholder ~now status = `Assoc ["status", `String status;
  "generated_at", `String (Masc_domain.iso8601_of_unix_seconds now)]

let is_current owner = Mcp_server.Workspace_scope_epoch.equal owner.scope.epoch
    (Mcp_server.workspace_scope owner.state).epoch

let create_owner ~state (scope : Mcp_server.workspace_scope) =
  let now = Unix.gettimeofday () in
  let generation = Dashboard_projection_cache.snapshot_invalidation_generation () in
  let identity = Server_observer_scope.instance_id scope in
  let initial = with_metadata ~identity ~generation ~compute_sequence:0 ~terminal_sequence:0
      ~next_deadline:None ~state:Initializing (placeholder ~now "initializing") in
  {state; scope; identity; cache = Cache.create_cached_surface initial;
   mu = Stdlib.Mutex.create (); mutation_generation = ref generation;
   source_revision = ref 0; admitted_revision = ref 0;
   compute_sequence = ref 0; terminal_sequence = ref 0; next_deadline = ref None;
   retained_completeness = ref None; canonical = ref {json = initial; state = Initializing};
   listeners = Atomic.make []}

let active_mu = Stdlib.Mutex.create ()
let active : owner option ref = ref None

let owner_for_scope ~state (scope : Mcp_server.workspace_scope) =
  let selected () = match !active with
    | Some owner when Mcp_server.Workspace_scope_epoch.equal owner.scope.epoch scope.epoch -> Some owner
    | Some _ | None -> None in
  match Stdlib.Mutex.protect active_mu selected with
  | Some owner -> owner
  | None ->
      let candidate = create_owner ~state scope in
      Stdlib.Mutex.protect active_mu (fun () -> match selected () with
        | Some owner -> owner
        | None -> if is_current candidate then active := Some candidate; candidate)

let subscribe_completed owner completed =
  let listener = {completed} in
  Lockfree_atomic.update owner.listeners (fun listeners -> listener :: listeners);
  fun () -> Lockfree_atomic.update owner.listeners (List.filter (fun current -> current != listener))

let completion_failures = Atomic.make 0
let notify owner completion =
  List.iter (fun listener ->
    try listener.completed completion with
    (* cancel-guard-ok: metadata listeners cannot replace the original
       producer completion, failure or cancellation. *)
    | _ -> ignore (Atomic.fetch_and_add completion_failures 1))
    (Atomic.get owner.listeners)

(* The caller holds the original mutation guard, then [owner.mu]. Publication
   metadata and the source cell change together; no transport runs here. *)
let synchronize_locked (owner : owner) ~now generation =
  if generation = !(owner.mutation_generation) then false else (
    owner.mutation_generation := generation;
    incr owner.source_revision;
    owner.admitted_revision := !(owner.source_revision);
    owner.compute_sequence := 0;
    owner.terminal_sequence := 0;
    owner.next_deadline := None;
    owner.retained_completeness := None;
    let json = with_metadata ~identity:owner.identity ~generation ~compute_sequence:0
        ~terminal_sequence:0 ~next_deadline:None ~state:Mutation_invalidated
        (placeholder ~now "invalidated") in
    Cache.invalidate_cached_surface ~json owner.cache;
    owner.canonical := {json; state = Mutation_invalidated};
    true)

let guarded owner f =
  let now = Unix.gettimeofday () in
  let invalidated, result = Dashboard_projection_cache.with_snapshot_publication_generation
      (fun generation -> Stdlib.Mutex.protect owner.mu (fun () ->
        let invalidated = synchronize_locked owner ~now generation in
        invalidated, f ~now generation)) in
  if invalidated && is_current owner then notify owner Invalidated;
  result

let has_observation owner = guarded owner (fun ~now:_ _ ->
  is_current owner && Option.is_some !(owner.retained_completeness))

let cache_snapshot owner = guarded owner (fun ~now:_ _ -> Cache.snapshot owner.cache)

let observation_is_usable owner =
  let now = Time_compat.now () in
  guarded owner (fun ~now:_ _ ->
    is_current owner && Option.is_some !(owner.retained_completeness)
    && !(owner.source_revision) = !(owner.admitted_revision)
    && match !(owner.next_deadline) with None -> true | Some at -> now < at)

let next_deadline_unix owner = guarded owner (fun ~now:_ _ -> !(owner.next_deadline))

let begin_attempt owner ~origin = guarded owner (fun ~now generation ->
  let sequence = Atomic.fetch_and_add compute_sequence 1 + 1 in
  Cache.update_cached_surface owner.cache (fun source -> {source with last_attempt_unix = Some now});
  {owner; mutation_generation = generation; sequence; origin})

let admits attempt generation =
  is_current attempt.owner && attempt.mutation_generation = generation
  && attempt.sequence > !(attempt.owner.terminal_sequence)

let install_canonical owner ~now ~generation ~sequence ~state ~next_deadline json =
  let source = Cache.snapshot owner.cache in
  let json = Cache.surface_snapshot_json ~now {source with json}
      |> with_metadata ~identity:owner.identity ~generation
        ~compute_sequence:!(owner.compute_sequence) ~terminal_sequence:sequence ~next_deadline ~state in
  owner.canonical := {json; state};
  owner.terminal_sequence := sequence;
  owner.admitted_revision := !(owner.source_revision)

let publish_observation attempt (observation : Dashboard_projection_read.observation) =
  let owner = attempt.owner in
  let body = Dashboard_projection_read.json_with_read_diagnostics observation in
  let installed = guarded owner (fun ~now generation ->
    if not (admits attempt generation) then false else (
      let state = match observation.completeness with
        | Dashboard_projection_read.Complete ->
            Cache.update_cached_surface owner.cache (fun source ->
              {source with json = body; last_success_unix = Some now; last_error = None; last_error_unix = None});
            Ready
        | Partial detail ->
            Cache.update_cached_surface owner.cache (fun source ->
              {source with json = body; last_error = Some detail; last_error_unix = Some now});
            Read_failed in
      owner.compute_sequence := attempt.sequence;
      owner.retained_completeness := Some observation.completeness;
      owner.next_deadline := observation.next_deadline_unix;
      install_canonical owner ~now ~generation ~sequence:attempt.sequence ~state
        ~next_deadline:observation.next_deadline_unix body;
      true)) in
  if installed then notify owner (match observation.completeness with
    | Complete -> Installed attempt.origin | Partial _ -> Failed attempt.origin);
  installed

let publish_failure_message attempt message =
  let owner = attempt.owner in
  let installed = guarded owner (fun ~now generation ->
    if not (admits attempt generation) then false else (
      let body = placeholder ~now "unavailable" in
      Cache.update_cached_surface owner.cache (fun source ->
        {source with json = body; last_success_unix = None;
          last_error = Some message; last_error_unix = Some now});
      owner.retained_completeness := None;
      owner.next_deadline := None;
      install_canonical owner ~now ~generation ~sequence:attempt.sequence ~state:Read_failed
        ~next_deadline:None body;
      true)) in
  if installed then notify owner (Failed attempt.origin);
  installed

let source_changed owner =
  let changed = guarded owner (fun ~now:_ _ ->
    if not (is_current owner) then false else (
      incr owner.source_revision;
      owner.next_deadline := None;
      true)) in
  if changed then notify owner Source_changed

let synchronize_invalidation () =
  let current = Stdlib.Mutex.protect active_mu (fun () -> !active) in
  Option.iter (fun owner -> guarded owner (fun ~now:_ _ -> ())) current

let publication owner = guarded owner (fun ~now:_ _ -> !(owner.canonical))
let publication_json publication = publication.json

let publication_status owner publication = guarded owner (fun ~now:_ _ ->
  if not (is_current owner) then Retired
  else if !(owner.source_revision) <> !(owner.admitted_revision)
      && (match (!(owner.canonical)).state with Ready | Read_failed -> true | Initializing | Mutation_invalidated -> false)
  then Source_pending
  else if publication != !(owner.canonical) then Superseded
  else Current)

let publication_is_current owner publication = match publication_status owner publication with
  | Current -> true | Superseded | Source_pending | Retired -> false
