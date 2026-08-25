(** Agent Registry Eio - Global agent identity tracking for MCP sessions

    Provides a singleton registry for tracking agent identities across
    MCP tool calls. Integrates with Client_identity module.

    Actor model: one immutable identity/session/cache snapshot is swapped behind
    a single mutex. Identity materialization and logging stay outside the
    critical section; pure transitions close creation races.

    @since 0.5.0
*)

(** {1 Actor State} *)

module State = Client_registry_state

(** Single process-wide actor state.  Protected by [state_mu]. *)
let state = ref State.empty
let state_mu : Eio.Mutex.t = Eio.Mutex.create ()

let apply_transition transition =
  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
    let next, value = transition !state in
    state := next;
    value)
;;

let snapshot () =
  Eio.Mutex.use_ro state_mu (fun () -> !state)

(** {1 Initialization} *)

(** Replace the registry and both session maps as one lifecycle operation. *)
let clear_all () =
  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
    state := State.empty
  )

(** Reset registry for testing. *)
let reset_for_testing () = clear_all ()

(** {1 Identity Resolution} *)

(** Get or create identity for an MCP request.

    Resolution order:
    1. Check session_map for existing mcp_session_id → session_key mapping
    2. Extract identity from MCP params (_agent_name, _channel, etc.)
    3. Register new identity

    Existing sessions are touched in one atomic transition. A miss materializes
    its candidate outside [state_mu], then commits through a second atomic
    transition that rechecks ownership. Concurrent creators therefore converge
    without running clock, randomness, nested locks, or logging under the state
    mutex.

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
    let reused =
      let now = Time_compat.now () in
      apply_transition (fun state ->
        match State.reuse_session ~now ~mcp_session_id:sid state with
        | Some (next, identity) -> next, Some identity
        | None -> state, None)
    in
    (match reused with
     | Some identity -> identity
     | None ->
       (* Candidate materialization owns clock/random effects and therefore
          stays outside [state_mu]. A second pure check at commit closes the
          race with another creator for the same MCP session. *)
       let candidate = Client_identity.from_mcp_params params in
       let now = Time_compat.now () in
       let outcome =
         apply_transition (fun state ->
           State.install_session
             ~now
             ~mcp_session_id:sid
             ~candidate
             state)
       in
       (match outcome with
        | State.Reused identity -> identity
        | State.Registered identity ->
          Log.Session.info
            "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
            identity.agent_name
            (String.sub
               identity.session_key
               0
               (min 8 (String.length identity.session_key)))
            sid;
          identity))

(** {1 Resolved Agent Name Cache}

    Caches the final resolved agent_name per MCP session to skip
    ~180 lines of identity resolution on 2nd+ calls. *)

let get_resolved_name sid =
  State.resolved_name (snapshot ()) sid

let set_resolved_name sid name ~is_ephemeral =
  apply_transition (fun state ->
    ( State.cache_resolved_name
        ~mcp_session_id:sid
        ~name
        ~is_ephemeral
        state
    , () ))

(** {1 Statistics} *)

(** Get total registered count *)
let total_count () =
  State.count (snapshot ())

(** {1 Cleanup} *)

(** End one explicit MCP-session registration. The identity row is removed
    only when no other MCP session references the same session key. *)
let unregister_mcp_session mcp_session_id =
  apply_transition (fun state ->
    State.unregister_mcp_session ~mcp_session_id state, ())
