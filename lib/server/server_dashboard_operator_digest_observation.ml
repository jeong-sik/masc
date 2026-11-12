module Cache = Server_dashboard_http_cache

type origin = Source_read | Default_request
type completion = Installed of origin | Failed of origin | Invalidated
type publication_status = Current | Superseded | Source_pending | Retired
type terminal = Success of int | Failure of int
type listener = {completed : completion -> unit}
type observation_state = Initializing | Ready | Read_failed

type owner = {
  state : Mcp_server.server_state;
  scope : Mcp_server.workspace_scope;
  identity : string;
  cache : Cache.cached_surface;
  mu : Stdlib.Mutex.t;
  generation : int ref;
  admitted_generation : int ref;
  next_sequence : int ref;
  terminal : terminal option ref;
  next_deadline : float option ref;
  retained_completeness : Dashboard_projection_read.completeness option ref;
  listeners : listener list Atomic.t;
}

type attempt = {owner : owner; sequence : int; origin : origin}
type publication = {json : Yojson.Safe.t; source : Cache.surface_snapshot; generation : int}

let generation_sequence = Atomic.make 0
let next_generation () = Atomic.fetch_and_add generation_sequence 1 + 1

let with_metadata ~scope ~generation ~sequence ~state = function
  | `Assoc fields ->
      let keys = ["observer_instance_id"; "digest_publication_generation";
        "digest_publication_sequence"; "digest_observation_state"] in
      let state = match state with Initializing -> "initializing" | Ready -> "ready" | Read_failed -> "error" in
      `Assoc (["observer_instance_id", `String (Server_observer_scope.instance_id scope);
        "digest_publication_generation", `Int generation;
        "digest_publication_sequence", `Int sequence;
        "digest_observation_state", `String state]
        @ List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid_arg "Operator Digest projection must be a JSON object"

let is_current owner = Mcp_server.Workspace_scope_epoch.equal owner.scope.epoch
    (Mcp_server.workspace_scope owner.state).epoch

let create_owner ~state (scope : Mcp_server.workspace_scope) =
  let generation = next_generation () in
  let initial = `Assoc ["health", `String "initializing";
    "generated_at", `String (Masc_domain.now_iso ())] in
  {state; scope; identity = Server_observer_scope.instance_id scope;
   cache = Cache.create_cached_surface
     (with_metadata ~scope ~generation ~sequence:0 ~state:Initializing initial);
   mu = Stdlib.Mutex.create (); generation = ref generation; admitted_generation = ref generation;
   next_sequence = ref 0; terminal = ref None; next_deadline = ref None; retained_completeness = ref None; listeners = Atomic.make []}

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
      Stdlib.Mutex.protect active_mu (fun () ->
        match selected () with
        | Some owner -> owner
        | None -> if is_current candidate then active := Some candidate; candidate)

let cache owner = owner.cache
let has_observation owner = Stdlib.Mutex.protect owner.mu (fun () -> Option.is_some !(owner.retained_completeness))
let has_terminal_answer owner = Stdlib.Mutex.protect owner.mu (fun () ->
  is_current owner && Option.is_some !(owner.terminal))
let next_deadline_unix owner = Stdlib.Mutex.protect owner.mu (fun () -> !(owner.next_deadline))

let subscribe_completed owner completed =
  let listener = {completed} in
  Lockfree_atomic.update owner.listeners (fun listeners -> listener :: listeners);
  fun () -> Lockfree_atomic.update owner.listeners (List.filter (fun current -> current != listener))

let completion_failures = Atomic.make 0
let notify owner completion =
  List.iter (fun listener ->
    try listener.completed completion with
    (* cancel-guard-ok: metadata listeners cannot replace a completed read or
       its original failure/cancellation with their own callback exception. *)
    | _ -> ignore (Atomic.fetch_and_add completion_failures 1))
    (Atomic.get owner.listeners)

let begin_attempt owner ~origin = Stdlib.Mutex.protect owner.mu (fun () ->
  incr owner.next_sequence;
  Cache.mark_cached_surface_attempt owner.cache;
  {owner; sequence = !(owner.next_sequence); origin})

let admits attempt ~failure =
  let owner = attempt.owner in
  is_current owner
  && match !(owner.terminal) with
     | None -> true
     | Some (Success sequence) ->
         if failure then attempt.sequence > sequence else attempt.sequence >= sequence
     | Some (Failure sequence) -> attempt.sequence >= sequence

let publish_observation attempt (observation : Dashboard_projection_cache.digest_observation) =
  let owner = attempt.owner in
  let now = Unix.gettimeofday () in
  let failure = match observation.completeness with
    | Dashboard_projection_read.Complete -> false | Partial _ -> true in
  let published = Stdlib.Mutex.protect owner.mu (fun () ->
    if not (admits attempt ~failure) then false else (
      let generation = !(owner.generation) in
      let state = if failure then Read_failed else Ready in
      let json = Dashboard_projection_read.json_with_read_diagnostics observation
          |> with_metadata ~scope:owner.scope ~generation ~sequence:attempt.sequence ~state in
      (match observation.completeness with
       | Complete -> Cache.mark_cached_surface_success owner.cache json
       | Partial detail -> Cache.update_cached_surface owner.cache (fun current ->
           {current with json; last_error = Some detail; last_error_unix = Some now}));
      owner.terminal := Some (if failure then Failure attempt.sequence else Success attempt.sequence);
      owner.admitted_generation := generation;
      owner.retained_completeness := Some observation.completeness;
      owner.next_deadline := observation.next_deadline_unix;
      true)) in
  if published then notify owner (if failure then Failed attempt.origin else Installed attempt.origin);
  published

let publish_failure_message attempt message =
  let owner = attempt.owner in
  let now = Unix.gettimeofday () in
  let published = Stdlib.Mutex.protect owner.mu (fun () ->
    if not (admits attempt ~failure:true) then false else (
      let generation = !(owner.generation) in
      Cache.update_cached_surface owner.cache (fun current ->
        {current with json = with_metadata ~scope:owner.scope ~generation
            ~sequence:attempt.sequence ~state:Read_failed current.json;
          last_error = Some message; last_error_unix = Some now});
      owner.terminal := Some (Failure attempt.sequence);
      owner.admitted_generation := generation;
      true)) in
  if published then notify owner (Failed attempt.origin);
  published

let invalidate owner =
  let changed = Stdlib.Mutex.protect owner.mu (fun () ->
    if not (is_current owner) then false else (
      owner.generation := next_generation (); owner.next_deadline := None; true)) in
  if changed then notify owner Invalidated

let publication owner =
  let now = Unix.gettimeofday () in
  Stdlib.Mutex.protect owner.mu (fun () ->
    let source = Cache.snapshot owner.cache in
    {json = Cache.surface_snapshot_json ~now source; source; generation = !(owner.admitted_generation)})

let publication_status owner publication =
  Stdlib.Mutex.protect owner.mu (fun () ->
    if not (is_current owner) then Retired
    else if !(owner.admitted_generation) <> !(owner.generation) then Source_pending
    else if publication.generation <> !(owner.generation)
      || publication.source != Cache.snapshot owner.cache then Superseded
    else Current)

let publication_is_current owner publication = match publication_status owner publication with
  | Current -> true | Superseded | Source_pending | Retired -> false

let cache_identity owner = Stdlib.Mutex.protect owner.mu (fun () ->
  let sequence = match !(owner.terminal) with
    | None -> 0 | Some (Success sequence | Failure sequence) -> sequence in
  Printf.sprintf "%s:%d:%d" owner.identity !(owner.generation) sequence)
