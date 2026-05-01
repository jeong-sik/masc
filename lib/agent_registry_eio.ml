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

    Usage:
    - Call [init ()] once during server startup (within Eio context)
    - Use [get_or_create_identity] in tool handlers
    - Identity persists across tool calls via MCP session ID

    @since 0.5.0
*)

(** {1 Global Registry} *)

(** Global registry instance - must be initialized within Eio context.
    All reads and writes go through [registry_lock] to prevent races. *)
let global_registry : Agent_identity.Registry.registry option ref = ref None

(** Initialize the global registry.
    Idempotent: non-yielding ref check. *)
let init () =
  match !global_registry with
  | Some _ -> ()
  | None -> global_registry := Some (Agent_identity.Registry.create ())

(** Raised when the agent registry cannot be initialized.
    Contains the step name and detail of the failure. *)
exception Registry_init_failed of string

(** Get the global registry. Initializes if needed (must be in Eio context).
    Returns [Error msg] if initialization fails instead of raising. *)
let get_registry () : (Agent_identity.Registry.registry, string) Result.t =
  match !global_registry with
  | Some reg -> Ok reg
  | None ->
      global_registry := Some (Agent_identity.Registry.create ());
      (match !global_registry with
      | Some reg -> Ok reg
      | None ->
          Error "agent registry initialization failed: \
                 global_registry is None after creation")

(** Get the registry, raising [Registry_init_failed] on failure.
    Used by internal callers that cannot change their return type. *)
let get_registry_exn () =
  match get_registry () with
  | Ok reg -> reg
  | Error msg -> raise (Registry_init_failed msg)

module SMap = Map.Make(String)

let atomic_update atomic f = Lockfree_atomic.update atomic f

(** MCP session to identity mapping for fast lookup *)
let session_identity_map : string SMap.t Atomic.t = Atomic.make SMap.empty

(** Caches the final resolved agent_name per MCP session *)
let resolved_names : string SMap.t Atomic.t = Atomic.make SMap.empty

(** Maximum session cache entries before forced eviction.
    Prevents unbounded growth when many MCP sessions connect over time. *)
let max_session_cache_entries = 1024

let clear_session_caches () =
  Atomic.set session_identity_map SMap.empty;
  Atomic.set resolved_names SMap.empty

(** Evict all session cache entries if either cache exceeds [max_session_cache_entries].
    A simple full-clear is safe because the caches are write-through
    (identity is reconstructed from params on the next call).
    Caller must hold [session_cache_mu]. *)
let maybe_evict_session_caches_locked () =
  let id_map = Atomic.get session_identity_map in
  let res_map = Atomic.get resolved_names in
  if SMap.cardinal id_map > max_session_cache_entries
     || SMap.cardinal res_map > max_session_cache_entries
  then begin
    Log.Identity.info
      "[AgentRegistry] session cache eviction: identity=%d resolved=%d (max=%d)"
      (SMap.cardinal id_map)
      (SMap.cardinal res_map)
      max_session_cache_entries;
    Atomic.set session_identity_map SMap.empty;
    Atomic.set resolved_names SMap.empty
  end

(** Reset registry for testing *)
let reset_for_testing () =
  Atomic.set session_identity_map SMap.empty;
  Atomic.set resolved_names SMap.empty;
  global_registry := Some (Agent_identity.Registry.create ())

(** {1 Identity Resolution} *)

(** Get or create identity for an MCP request.

    Resolution order:
    1. Check session_identity_map for existing session -> identity mapping
    2. Extract identity from MCP params (_agent_name, _channel, etc.)
    3. Create new identity if not found

    @param mcp_session_id Optional MCP HTTP session ID
    @param params Tool call params (may contain _agent_name, etc.)
    @return Agent identity for this request
*)
let get_or_create_identity ?mcp_session_id params =
  let reg = get_registry_exn () in

  let touch_and_return identity =
    let room_id = Yojson.Safe.Util.(
      try Some (params |> member "room" |> to_string)
      with Yojson.Safe.Util.Type_error _ -> None
    ) in
    Agent_identity.Registry.touch reg identity.Agent_identity.session_key
      ?room_id ();
    match Agent_identity.Registry.find_by_session reg identity.session_key with
    | Some updated -> updated
    | None -> identity
  in

  (* Fast path: unlocked lookup is safe because values in
     [session_identity_map] are immutable [session_key] strings and
     [Hashtbl.find_opt] is atomic on a single Eio domain.  Registry
     touches have their own internal lock. *)
  let get_from_cache sid =
    match SMap.find_opt sid (Atomic.get session_identity_map) with
    | Some session_key -> Agent_identity.Registry.find_by_session reg session_key
    | None -> None
  in

  let existing =
    match mcp_session_id with
    | None -> None
    | Some sid -> get_from_cache sid
  in

  match existing with
  | Some identity -> touch_and_return identity
  | None ->
      (* Lock-free identity creation path. Concurrent creation might result in
         a transient orphaned identity in the registry which the zombie sweep
         will eventually collect. This trade-off removes the multi-step Mutex
         bottleneck on the hot path. *)
      let identity = Agent_identity.from_mcp_params params in
      let registered = Agent_identity.Registry.register reg identity in
      (match mcp_session_id with
       | Some sid ->
           (* Use compare-and-swap loop to update the map *)
           atomic_update session_identity_map (fun map -> SMap.add sid registered.session_key map)
       | None -> ());
      Log.Session.info "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
        registered.agent_name
        (String.sub registered.session_key 0
           (min 8 (String.length registered.session_key)))
        (Option.value mcp_session_id ~default:"none");
      maybe_evict_session_caches_locked ();
      registered

(** Get identity by agent name (for backward compatibility) *)
let get_by_name agent_name =
  match get_registry () with
  | Ok reg -> Agent_identity.Registry.find_by_name reg agent_name
  | Error e ->
      Log.Identity.warn "get_by_name(%s): registry unavailable: %s" agent_name e;
      None

(** Get identity by session key *)
let get_by_session session_key =
  match get_registry () with
  | Ok reg -> Agent_identity.Registry.find_by_session reg session_key
  | Error e ->
      Log.Identity.warn "get_by_session: registry unavailable: %s" e;
      None

(** {1 Resolved Agent Name Cache}

    Caches the final resolved agent_name per MCP session to skip
    ~180 lines of identity resolution on 2nd+ calls. *)

let get_resolved_name sid =
  SMap.find_opt sid (Atomic.get resolved_names)

let set_resolved_name sid name =
  atomic_update resolved_names (fun map -> SMap.add sid name map)

(** {1 Statistics} *)

(** Get count of active agents *)
let active_count ?(within_seconds = Env_config.Zombie.threshold_seconds) () =
  match get_registry () with
  | Ok reg -> List.length (Agent_identity.Registry.list_active reg ~within_seconds)
  | Error e ->
      Log.Identity.debug "active_count: registry unavailable: %s" e;
      0

(** Get total registered count *)
let total_count () =
  match get_registry () with
  | Ok reg -> Agent_identity.Registry.count reg
  | Error e ->
      Log.Identity.debug "total_count: registry unavailable: %s" e;
      0

(** List all active identities *)
let list_active ?(within_seconds = Env_config.Zombie.threshold_seconds) () =
  match get_registry () with
  | Ok reg -> Agent_identity.Registry.list_active reg ~within_seconds
  | Error e ->
      Log.Identity.debug "list_active: registry unavailable: %s" e;
      []

(** {1 Cleanup} *)

(** Clean up stale session mappings and resolved-name cache entries.

    Two-phase under [session_cache_mu]: snapshot the [(sid, session_key)]
    pairs inside the lock, look them up against the registry while still
    holding the lock (Registry has its own lock but does not depend on
    ours), then remove stale entries.  Holding the mutex across the
    scan prevents a concurrent [get_or_create_identity] from installing
    a fresh entry that this scan would then incorrectly remove. *)
let cleanup_stale_sessions () =
  match get_registry () with
  | Error e ->
      Log.Identity.warn "cleanup_stale_sessions: registry unavailable: %s" e;
      0
  | Ok reg ->
      let current_map = Atomic.get session_identity_map in
      let to_remove = SMap.fold (fun sid session_key acc ->
        match Agent_identity.Registry.find_by_session reg session_key with
        | None -> sid :: acc
        | Some _ -> acc
      ) current_map [] in
      
      atomic_update session_identity_map (fun map ->
        List.fold_left (fun m sid -> SMap.remove sid m) map to_remove
      );
      atomic_update resolved_names (fun map ->
        List.fold_left (fun m sid -> SMap.remove sid m) map to_remove
      );
      List.length to_remove

(** Unregister an identity *)
let unregister session_key =
  match get_registry () with
  | Error e ->
      Log.Identity.warn "unregister(%s): registry unavailable: %s"
        (String.sub session_key 0 (min 8 (String.length session_key))) e
  | Ok reg ->
    Agent_identity.Registry.unregister reg session_key;
    let current_map = Atomic.get session_identity_map in
    let to_remove = SMap.fold (fun sid sk acc ->
      if String.equal sk session_key then sid :: acc else acc
    ) current_map [] in
    
    atomic_update session_identity_map (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map to_remove
    );
    atomic_update resolved_names (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map to_remove
    )
