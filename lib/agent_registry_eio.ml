open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Agent Registry Eio - Global agent identity tracking for MCP sessions

    Provides a singleton registry for tracking agent identities across
    MCP tool calls. Integrates with Agent_identity module.

    Actor model: all mutable state is encapsulated in a single Mutex-protected
    record.  The three previously independent global stores (identity registry,
    session→key map, resolved-name cache) are now one coherent unit, eliminating
    the TOCTOU window that existed between the old separate Atomic.t updates.

    Usage:
    - Call [init ()] once during server startup (within Eio context)
    - Use [get_or_create_identity] in tool handlers
    - Identity persists across tool calls via MCP session ID
    - Optionally call [start_cleanup_loop ~sw ~clock] to enable background eviction

    @since 0.5.0
*)

module SMap = Map.Make(String)

(** {1 Actor State} *)

(** Consolidated actor state – replaces three separate mutable globals.
    Held behind a single Mutex so that read-modify-write sequences are
    atomic (e.g. cache-miss create + map insert in [get_or_create_identity]). *)
type state = {
  registry : Agent_identity.Registry.registry;
  session_map : string SMap.t;   (** mcp_session_id → session_key *)
  resolved_map : string SMap.t;  (** mcp_session_id → resolved agent_name *)
}

let make_state () = {
  registry = Agent_identity.Registry.create ();
  session_map = SMap.empty;
  resolved_map = SMap.empty;
}

(** Single process-wide actor state.  Protected by [state_mu]. *)
let state : state ref = ref (make_state ())
let state_mu : Eio.Mutex.t = Eio.Mutex.create ()

let with_state_rw f =
  Eio.Mutex.use_rw ~protect:true state_mu (fun () -> f state)

let with_state_ro f =
  Eio.Mutex.use_ro state_mu (fun () -> f !state)

(** Maximum session cache entries before forced eviction.
    Prevents unbounded growth when many MCP sessions connect over time. *)
let max_session_cache_entries = 1024

(** {1 Initialization} *)

(** Initialize (or re-initialize) the actor state.
    Idempotent when called more than once – the existing state is kept. *)
let init () = ()  (* state is created eagerly at module load time *)

(** Reset registry for testing.
    Replaces all state with a fresh empty record. *)
let reset_for_testing () =
  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
    state := make_state ()
  )

let clear_session_caches () =
  with_state_rw (fun s ->
    s := { !s with session_map = SMap.empty; resolved_map = SMap.empty }
  )

(** Evict session caches when either map exceeds [max_session_cache_entries].
    Caller must hold [state_mu]. *)
let maybe_evict_caches_locked s =
  if SMap.cardinal s.session_map > max_session_cache_entries
     || SMap.cardinal s.resolved_map > max_session_cache_entries
  then begin
    Log.Identity.info
      "[AgentRegistry] session cache eviction: session_map=%d resolved_map=%d (max=%d)"
      (SMap.cardinal s.session_map)
      (SMap.cardinal s.resolved_map)
      max_session_cache_entries;
    { s with session_map = SMap.empty; resolved_map = SMap.empty }
  end else s

(** {1 Internal helpers — must be called under [state_mu]} *)

let get_registry_locked s = s.registry

(** {1 Identity Resolution} *)

(** Get or create identity for an MCP request.

    Resolution order:
    1. Check session_map for existing mcp_session_id → session_key mapping
    2. Extract identity from MCP params (_agent_name, _channel, etc.)
    3. Register new identity

    The entire check-then-create sequence runs under [state_mu] so concurrent
    callers with the same [mcp_session_id] are serialised — no more transient
    orphan identities from the old lock-free path.

    @param mcp_session_id Optional MCP HTTP session ID
    @param params Tool call params (may contain _agent_name, etc.)
    @return Agent identity for this request
*)
let get_or_create_identity ?mcp_session_id params =
  let room_id =
    match Yojson.Safe.Util.(params |> member "room") with
    | `String r -> Some r
    | _ -> None
    | exception Yojson.Safe.Util.Type_error _ -> None
  in
  with_state_rw (fun s ->
    let reg = get_registry_locked !s in
    let find_from_cache sid =
      match SMap.find_opt sid (!s).session_map with
      | Some session_key -> Agent_identity.Registry.find_by_session reg session_key
      | None -> None
    in
    let existing =
      match mcp_session_id with
      | None -> None
      | Some sid -> find_from_cache sid
    in
    match existing with
    | Some identity ->
        Agent_identity.Registry.touch reg identity.Agent_identity.session_key
          ?room_id ();
        (match Agent_identity.Registry.find_by_session reg identity.session_key with
         | Some updated -> updated
         | None -> identity)
    | None ->
        let identity = Agent_identity.from_mcp_params params in
        let registered = Agent_identity.Registry.register reg identity in
        let s' =
          match mcp_session_id with
          | Some sid ->
              { !s with session_map = SMap.add sid registered.Agent_identity.session_key (!s).session_map }
          | None -> !s
        in
        let s'' = maybe_evict_caches_locked s' in
        s := s'';
        Log.Session.info "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
          registered.agent_name
          (String.sub registered.session_key 0
             (min 8 (String.length registered.session_key)))
          (Option.value mcp_session_id ~default:"none");
        registered
  )

(** Get identity by agent name. Returns [None] if not found. *)
let get_by_name agent_name =
  with_state_ro (fun s ->
    Agent_identity.Registry.find_by_name s.registry agent_name
  )

(** Get identity by session key. Returns [None] if not found. *)
let get_by_session session_key =
  with_state_ro (fun s ->
    Agent_identity.Registry.find_by_session s.registry session_key
  )

(** {1 Resolved Agent Name Cache}

    Caches the final resolved agent_name per MCP session to skip
    ~180 lines of identity resolution on 2nd+ calls. *)

let get_resolved_name sid =
  with_state_ro (fun s -> SMap.find_opt sid s.resolved_map)

let set_resolved_name sid name =
  with_state_rw (fun s ->
    s := { !s with resolved_map = SMap.add sid name (!s).resolved_map }
  )

(** {1 Statistics} *)

(** Get count of active agents *)
let active_count ?(within_seconds = Env_config.Zombie.threshold_seconds) () =
  with_state_ro (fun s ->
    List.length (Agent_identity.Registry.list_active s.registry ~within_seconds)
  )

(** Get total registered count *)
let total_count () =
  with_state_ro (fun s -> Agent_identity.Registry.count s.registry)

(** List all active identities *)
let list_active ?(within_seconds = Env_config.Zombie.threshold_seconds) () =
  with_state_ro (fun s ->
    Agent_identity.Registry.list_active s.registry ~within_seconds
  )

(** {1 Cleanup} *)

(** Clean up stale session mappings and resolved-name cache entries.

    Runs under [state_mu] so that a concurrent [get_or_create_identity]
    cannot install a fresh entry between the stale-detection scan and the
    removal step. *)
let cleanup_stale_sessions () =
  with_state_rw (fun s ->
    let reg = get_registry_locked !s in
    let to_remove =
      SMap.fold (fun sid session_key acc ->
        match Agent_identity.Registry.find_by_session reg session_key with
        | None -> sid :: acc
        | Some _ -> acc
      ) (!s).session_map []
    in
    let remove_from map sids =
      List.fold_left (fun m sid -> SMap.remove sid m) map sids
    in
    s := { !s with
      session_map = remove_from (!s).session_map to_remove;
      resolved_map = remove_from (!s).resolved_map to_remove;
    };
    List.length to_remove
  )

(** Unregister an identity and remove all associated cache entries. *)
let unregister session_key =
  with_state_rw (fun s ->
    let reg = get_registry_locked !s in
    Agent_identity.Registry.unregister reg session_key;
    let to_remove =
      SMap.fold (fun sid sk acc ->
        if String.equal sk session_key then sid :: acc else acc
      ) (!s).session_map []
    in
    let remove_from map sids =
      List.fold_left (fun m sid -> SMap.remove sid m) map sids
    in
    s := { !s with
      session_map = remove_from (!s).session_map to_remove;
      resolved_map = remove_from (!s).resolved_map to_remove;
    }
  )

(** {1 Background Maintenance} *)

(** Start a periodic cleanup fiber that removes stale sessions and evicts
    caches when they grow too large.  Call once at server startup. *)
let start_cleanup_loop ~sw ~clock ?(interval = 300.0) () =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
         let removed = cleanup_stale_sessions () in
         if removed > 0 then
           Log.Identity.info "[AgentRegistry] cleanup: removed %d stale sessions" removed
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Identity.warn "[AgentRegistry] cleanup error: %s"
             (Stdlib.Printexc.to_string exn));
      loop ()
    in
    loop ()
  )
