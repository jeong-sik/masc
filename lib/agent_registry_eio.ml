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

(** Global registry instance - must be initialized within Eio context *)
let global_registry : Agent_identity.Registry.registry option ref = ref None
let registry_lock = Mutex.create ()
let initialized = ref false

(** Initialize the global registry. Must be called within Eio context. *)
let init () =
  Mutex.lock registry_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock registry_lock) (fun () ->
    if not !initialized then begin
      global_registry := Some (Agent_identity.Registry.create ());
      initialized := true
    end
  )

(** Get the global registry. Initializes if needed (must be in Eio context). *)
let get_registry () =
  match !global_registry with
  | Some reg -> reg
  | None ->
      (* Lazy init - must be in Eio context *)
      init ();
      match !global_registry with
      | Some reg -> reg
      | None -> failwith "Agent registry initialization failed"

(** Reset registry for testing *)
let reset_for_testing () =
  Mutex.lock registry_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock registry_lock) (fun () ->
    global_registry := Some (Agent_identity.Registry.create ());
    initialized := true
  )

(** {1 Identity Resolution} *)

(** MCP session to identity mapping for fast lookup *)
let session_identity_map : (string, string) Hashtbl.t = Hashtbl.create 64
let session_map_lock = Mutex.create ()

(** {1 SSH Key Binding} *)

(** SSH fingerprint to agent_id binding (one key = one agent) *)
let ssh_key_bindings : (string, string) Hashtbl.t = Hashtbl.create 64
let ssh_binding_lock = Mutex.create ()

(** Check if an SSH key is already bound to another agent *)
let[@warning "-32"] is_key_bound fingerprint =
  Mutex.lock ssh_binding_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"ssh_bind_check" ~finally:(fun () -> Mutex.unlock ssh_binding_lock) (fun () ->
    Hashtbl.mem ssh_key_bindings fingerprint
  )

(** Get the agent bound to an SSH key *)
let[@warning "-32"] get_key_binding fingerprint =
  Mutex.lock ssh_binding_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"ssh_get_bind" ~finally:(fun () -> Mutex.unlock ssh_binding_lock) (fun () ->
    Hashtbl.find_opt ssh_key_bindings fingerprint
  )

(** Bind an SSH key to an agent (Sybil prevention).
    Returns Error if key is already bound to a different agent.

    @param agent_id The agent to bind
    @param fingerprint SSH key fingerprint (from MASC_AGENT_SSH_KEY env var)
*)
let bind_ssh_key ~agent_id ~fingerprint =
  Mutex.lock ssh_binding_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"ssh_bind" ~finally:(fun () -> Mutex.unlock ssh_binding_lock) (fun () ->
    match Hashtbl.find_opt ssh_key_bindings fingerprint with
    | Some existing when existing <> agent_id ->
        Error (Printf.sprintf "SSH key already bound to agent '%s'" existing)
    | Some _ ->
        (* Already bound to this agent - OK *)
        Ok ()
    | None ->
        Hashtbl.add ssh_key_bindings fingerprint agent_id;
        Log.Session.info "[AgentRegistry] SSH key bound: %s -> %s"
          (String.sub fingerprint 0 (min 16 (String.length fingerprint))) agent_id;
        Ok ()
  )

(** Try to bind SSH key from environment variable.
    Called during identity creation. Non-binding if env var not set.
*)
let[@warning "-32"] try_bind_from_env ~agent_id =
  match Sys.getenv_opt "MASC_AGENT_SSH_KEY" with
  | None -> Ok ()  (* No binding required *)
  | Some fingerprint ->
      if String.length fingerprint < 8 then
        Error "Invalid SSH key fingerprint (too short)"
      else
        bind_ssh_key ~agent_id ~fingerprint

(** Remove SSH key binding (for cleanup) *)
let[@warning "-32"] unbind_ssh_key ~agent_id =
  Mutex.lock ssh_binding_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"ssh_unbind" ~finally:(fun () -> Mutex.unlock ssh_binding_lock) (fun () ->
    let to_remove = Hashtbl.fold (fun fp aid acc ->
      if aid = agent_id then fp :: acc else acc
    ) ssh_key_bindings [] in
    List.iter (Hashtbl.remove ssh_key_bindings) to_remove;
    List.length to_remove
  )

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
  let reg = get_registry () in

  (* Try to find existing identity by MCP session ID *)
  let existing_by_session =
    match mcp_session_id with
    | None -> None
    | Some sid ->
        Mutex.lock session_map_lock;
        let result = Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock session_map_lock) (fun () ->
          match Hashtbl.find_opt session_identity_map sid with
          | Some session_key -> Agent_identity.Registry.find_by_session reg session_key
          | None -> None
        ) in
        result
  in

  match existing_by_session with
  | Some identity ->
      (* Touch to update last_seen and room *)
      let room_id = Yojson.Safe.Util.(
        try Some (params |> member "room" |> to_string)
        with _ -> None
      ) in
      Agent_identity.Registry.touch reg identity.session_key ?room_id ();
      (* Return fresh identity with updated room *)
      (match Agent_identity.Registry.find_by_session reg identity.session_key with
       | Some updated -> updated
       | None -> identity)
  | None ->
      (* Create new identity from params *)
      let identity = Agent_identity.from_mcp_params params in
      let registered = Agent_identity.Registry.register reg identity in

      (* Link MCP session ID to identity session key *)
      (match mcp_session_id with
       | Some sid ->
           Mutex.lock session_map_lock;
           Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock session_map_lock) (fun () ->
             Hashtbl.replace session_identity_map sid registered.session_key
           )
       | None -> ());

      Log.Session.info "[AgentRegistry] New identity: %s (session=%s, mcp=%s)"
        registered.agent_name
        (String.sub registered.session_key 0 8)
        (Option.value mcp_session_id ~default:"none");

      registered

(** Get identity by agent name (for backward compatibility) *)
let get_by_name agent_name =
  let reg = get_registry () in
  Agent_identity.Registry.find_by_name reg agent_name

(** Get identity by session key *)
let get_by_session session_key =
  let reg = get_registry () in
  Agent_identity.Registry.find_by_session reg session_key

(** {1 Statistics} *)

(** Get count of active agents *)
let active_count ?(within_seconds = 300.0) () =
  let reg = get_registry () in
  List.length (Agent_identity.Registry.list_active reg ~within_seconds)

(** Get total registered count *)
let total_count () =
  let reg = get_registry () in
  Agent_identity.Registry.count reg

(** List all active identities *)
let list_active ?(within_seconds = 300.0) () =
  let reg = get_registry () in
  Agent_identity.Registry.list_active reg ~within_seconds

(** {1 Cleanup} *)

(** Clean up stale session mappings *)
let cleanup_stale_sessions () =
  let reg = get_registry () in
  Mutex.lock session_map_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock session_map_lock) (fun () ->
    let to_remove = ref [] in
    Hashtbl.iter (fun sid session_key ->
      match Agent_identity.Registry.find_by_session reg session_key with
      | None -> to_remove := sid :: !to_remove
      | Some _ -> ()
    ) session_identity_map;
    List.iter (fun sid -> Hashtbl.remove session_identity_map sid) !to_remove;
    List.length !to_remove
  )

(** Unregister an identity *)
let unregister session_key =
  let reg = get_registry () in
  Agent_identity.Registry.unregister reg session_key;
  (* Also clean up session map *)
  Mutex.lock session_map_lock;
  Common.protect ~module_name:"agent_registry_eio" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock session_map_lock) (fun () ->
    let to_remove = ref [] in
    Hashtbl.iter (fun sid sk ->
      if sk = session_key then to_remove := sid :: !to_remove
    ) session_identity_map;
    List.iter (fun sid -> Hashtbl.remove session_identity_map sid) !to_remove
  )
