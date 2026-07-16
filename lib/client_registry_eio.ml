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
    MCP tool calls. Integrates with Client_identity module.

    Actor model: all mutable state is encapsulated in a single Mutex-protected
    record.  The three previously independent global stores (identity registry,
    session→key map, resolved-name cache) are now one coherent unit, eliminating
    the TOCTOU window that existed between the old separate Atomic.t updates.

    Usage:
    - Call [init ()] once during server startup (within Eio context)
    - Use [get_or_create_identity] in tool handlers
    - Identity persists across tool calls via MCP session ID

    @since 0.5.0
*)

module SMap = Set_util.StringMap

(** {1 Actor State} *)

(** Consolidated actor state – replaces three separate mutable globals.
    Held behind a single Mutex so that read-modify-write sequences are
    atomic (e.g. cache-miss create + map insert in [get_or_create_identity]). *)
type state = {
  registry : Client_identity.Registry.registry;
  session_map : string SMap.t;   (** mcp_session_id → session_key *)
  resolved_map : (string * bool) SMap.t;
      (** mcp_session_id → (resolved agent_name, is_ephemeral).

          [is_ephemeral] is decided at the write site from the typed
          origin (identity provenance / own generated fallback), not
          re-derived from the name string on read. *)
}

let make_state () = {
  registry = Client_identity.Registry.create ();
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

(** {1 Initialization} *)

(** Replace the registry and both session maps as one lifecycle operation. *)
let clear_all () =
  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
    state := make_state ()
  )

(** Reset registry for testing. *)
let reset_for_testing () = clear_all ()

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
  match mcp_session_id with
  | None ->
    (* A call without a transport session has no explicit lifecycle owner.
       Return its typed identity without inserting an immortal registry row. *)
    Client_identity.from_mcp_params params
  | Some sid ->
    with_state_rw (fun s ->
      let reg = get_registry_locked !s in
      match
        Option.bind
          (SMap.find_opt sid (!s).session_map)
          (Client_identity.Registry.find_by_session reg)
      with
      | Some identity ->
        Client_identity.Registry.touch reg identity.Client_identity.session_key ();
        Option.value
          (Client_identity.Registry.find_by_session reg identity.session_key)
          ~default:identity
      | None ->
        let identity = Client_identity.from_mcp_params params in
        let registered = Client_identity.Registry.register reg identity in
        let s' =
          { !s with
            session_map =
              SMap.add sid registered.Client_identity.session_key (!s).session_map
          }
        in
        s := s';
        Log.Session.info
          "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
          registered.agent_name
          (String.sub
             registered.session_key
             0
             (min 8 (String.length registered.session_key)))
          sid;
        registered)

(** {1 Resolved Agent Name Cache}

    Caches the final resolved agent_name per MCP session to skip
    ~180 lines of identity resolution on 2nd+ calls. *)

let get_resolved_name sid =
  with_state_ro (fun s -> SMap.find_opt sid s.resolved_map)

let set_resolved_name sid name ~is_ephemeral =
  with_state_rw (fun s ->
    s := { !s with resolved_map = SMap.add sid (name, is_ephemeral) (!s).resolved_map }
  )

(** {1 Statistics} *)

(** Get total registered count *)
let total_count () =
  with_state_ro (fun s -> Client_identity.Registry.count s.registry)

(** {1 Cleanup} *)

(** End one explicit MCP-session registration. The identity row is removed
    only when no other MCP session references the same session key. *)
let unregister_mcp_session mcp_session_id =
  with_state_rw (fun s ->
    let reg = get_registry_locked !s in
    match SMap.find_opt mcp_session_id (!s).session_map with
    | None -> ()
    | Some session_key ->
      let session_map = SMap.remove mcp_session_id (!s).session_map in
      let still_referenced =
        SMap.exists (fun _ mapped -> String.equal mapped session_key) session_map
      in
      if not still_referenced then Client_identity.Registry.unregister reg session_key;
      s :=
        { !s with
          session_map
        ; resolved_map = SMap.remove mcp_session_id (!s).resolved_map
        })
