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
let get_registry () : (Agent_identity.Registry.registry, string) result =
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

(** MCP session to identity mapping for fast lookup *)
let session_identity_map : (string, string) Hashtbl.t = Hashtbl.create 64

(** Caches the final resolved agent_name per MCP session to skip
    ~180 lines of identity resolution on 2nd+ calls. *)
let resolved_names : (string, string) Hashtbl.t = Hashtbl.create 64

(** Mutex serialising multi-step operations on the two session caches
    above.  Single [Hashtbl] operations are atomic on a single Eio
    domain, but [get_or_create_identity] interleaves a cache lookup
    with a [Registry.register] call that yields via [reg.lock], which
    is a classic check-then-act race window:

    Fiber A                             Fiber B
    Hashtbl.find_opt sid -> None
                                        Hashtbl.find_opt sid -> None
    Registry.register id_a              Registry.register id_b
    Hashtbl.replace sid id_a.key        Hashtbl.replace sid id_b.key

    Both fibers produce fresh UUID session keys via
    [Agent_identity.generate_session_key], so [Registry.register] is
    NOT idempotent here — it installs two distinct identities for the
    same MCP session, and only the last writer wins in
    [session_identity_map].  The earlier identity is orphaned in the
    registry until the zombie sweep collects it.

    Fix: double-checked locking in the create path and a short
    critical section around all multi-step cache mutations
    (clear / evict / cleanup / unregister).  Single-entry reads
    and writes (get_resolved_name / set_resolved_name) also go
    through the mutex to keep invariants simple. *)
let session_cache_mu = Eio.Mutex.create ()

(** Maximum session cache entries before forced eviction.
    Prevents unbounded growth when many MCP sessions connect over time. *)
let max_session_cache_entries = 1024

let clear_session_caches () =
  Eio_guard.with_mutex session_cache_mu (fun () ->
    Hashtbl.clear session_identity_map;
    Hashtbl.clear resolved_names)

(** Evict all session cache entries if either cache exceeds [max_session_cache_entries].
    A simple full-clear is safe because the caches are write-through
    (identity is reconstructed from params on the next call).
    Caller must hold [session_cache_mu]. *)
let maybe_evict_session_caches_locked () =
  if Hashtbl.length session_identity_map > max_session_cache_entries
     || Hashtbl.length resolved_names > max_session_cache_entries
  then begin
    Log.Identity.info
      "[AgentRegistry] session cache eviction: identity=%d resolved=%d (max=%d)"
      (Hashtbl.length session_identity_map)
      (Hashtbl.length resolved_names)
      max_session_cache_entries;
    Hashtbl.clear session_identity_map;
    Hashtbl.clear resolved_names
  end

(** Reset registry for testing *)
let reset_for_testing () =
  Eio_guard.with_mutex session_cache_mu (fun () ->
    Hashtbl.clear session_identity_map;
    Hashtbl.clear resolved_names);
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
  let existing_by_session =
    match mcp_session_id with
    | None -> None
    | Some sid ->
        (match Hashtbl.find_opt session_identity_map sid with
         | Some session_key ->
             Agent_identity.Registry.find_by_session reg session_key
         | None -> None)
  in

  match existing_by_session with
  | Some identity -> touch_and_return identity
  | None ->
      (* Slow path: serialise identity creation so concurrent fibers
         sharing an [mcp_session_id] cannot both register distinct
         identities and leak the earlier one into the registry.  The
         double-check inside the critical section covers the window
         between the lockless lookup above and lock acquisition. *)
      Eio_guard.with_mutex session_cache_mu (fun () ->
        let already =
          match mcp_session_id with
          | None -> None
          | Some sid ->
              (match Hashtbl.find_opt session_identity_map sid with
               | Some session_key ->
                   Agent_identity.Registry.find_by_session reg session_key
               | None -> None)
        in
        match already with
        | Some identity -> touch_and_return identity
        | None ->
            let identity = Agent_identity.from_mcp_params params in
            let registered = Agent_identity.Registry.register reg identity in
            (match mcp_session_id with
             | Some sid ->
                 Hashtbl.replace session_identity_map sid registered.session_key
             | None -> ());
            Log.Session.info "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
              registered.agent_name
              (String.sub registered.session_key 0
                 (min 8 (String.length registered.session_key)))
              (Option.value mcp_session_id ~default:"none");
            maybe_evict_session_caches_locked ();
            registered)

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
  Eio_guard.with_mutex session_cache_mu (fun () ->
    Hashtbl.find_opt resolved_names sid)

let set_resolved_name sid name =
  Eio_guard.with_mutex session_cache_mu (fun () ->
    Hashtbl.replace resolved_names sid name)

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
    Eio_guard.with_mutex session_cache_mu (fun () ->
      let to_remove = ref [] in
      Hashtbl.iter (fun sid session_key ->
        match Agent_identity.Registry.find_by_session reg session_key with
        | None -> to_remove := sid :: !to_remove
        | Some _ -> ()
      ) session_identity_map;
      List.iter (fun sid ->
        Hashtbl.remove session_identity_map sid;
        Hashtbl.remove resolved_names sid
      ) !to_remove;
      List.length !to_remove)

(** Unregister an identity *)
let unregister session_key =
  match get_registry () with
  | Error e ->
      Log.Identity.warn "unregister(%s): registry unavailable: %s"
        (String.sub session_key 0 (min 8 (String.length session_key))) e
  | Ok reg ->
    Agent_identity.Registry.unregister reg session_key;
    Eio_guard.with_mutex session_cache_mu (fun () ->
      let to_remove = ref [] in
      Hashtbl.iter (fun sid sk ->
        if sk = session_key then to_remove := sid :: !to_remove
      ) session_identity_map;
      List.iter (fun sid ->
        Hashtbl.remove session_identity_map sid;
        Hashtbl.remove resolved_names sid
      ) !to_remove)
