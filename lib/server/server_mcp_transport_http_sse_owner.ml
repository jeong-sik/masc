open Result.Syntax

module Owner_map = Set_util.StringMap
module Store = Server_mcp_transport_session_store

type lease = {
  session_id : string;
  lifecycle_session_id : string;
  owner : Server_transport_admission.identity;
  sse_kind : Sse.session_kind;
  setup_operation : operation_lease;
  lease_released : bool Atomic.t;
}

and operation_lease = {
  operation_session_id : string;
  operation_generation : int;
  operation_released : bool Atomic.t;
}

type active_connection = {
  lease : lease;
  client_id : int;
}

type deletion = {
  session_id : string;
  generation : int;
  owner_at_prepare : Server_transport_admission.identity option;
}

type committed_deletion = {
  deletion : deletion;
  wire_sessions : string list;
  active_connections : (string * int) list;
}

type delete_start =
  | Prepared_delete of deletion
  | Resume_committed_delete of committed_deletion

type retained_delete_authorization =
  | No_retained_delete
  | Retained_delete_authorized
  | Retained_delete_rejected of { message : string }
  | Retained_delete_in_progress

type lifecycle_error =
  | Session_terminating of { session_id : string }
  | Session_unknown of { session_id : string }
  | Session_owner_rejected of { message : string }

type operation_gate =
  | Open of {
      generation : int;
      in_flight : int;
    }
  | Draining of {
      deletion : deletion;
      operation_generation : int option;
      in_flight : int;
      drained : unit Eio.Promise.t;
      resolve_drained : unit Eio.Promise.u;
      retryable : bool;
    }
  | Delete_committed of committed_deletion

type derived_wire_binding = {
  lifecycle_session_id : string;
  owner : Server_transport_admission.identity;
  sse_kind : Sse.session_kind;
}

type connection_claim = {
  lease : lease;
  previous_active : active_connection option;
}

type lease_state =
  | Connecting of connection_claim
  | Active of active_connection
  | Releasing of lease
  | Deleting of deletion

type t = {
  sessions : Store.t;
  owner_by_session : lease_state Owner_map.t Atomic.t;
  operation_gate_by_session : operation_gate Owner_map.t Atomic.t;
  derived_binding_by_wire : derived_wire_binding Owner_map.t Atomic.t;
  deletion_by_wire : deletion Owner_map.t Atomic.t;
  transition_mutex : Stdlib.Mutex.t;
  lifecycle_generation : int Atomic.t;
}

let create ~sessions =
  {
    sessions;
    owner_by_session = Atomic.make Owner_map.empty;
    operation_gate_by_session = Atomic.make Owner_map.empty;
    derived_binding_by_wire = Atomic.make Owner_map.empty;
    deletion_by_wire = Atomic.make Owner_map.empty;
    transition_mutex = Stdlib.Mutex.create ();
    lifecycle_generation = Atomic.make 0;
  }

let sessions t = t.sessions

let next_lifecycle_generation t =
  Atomic.fetch_and_add t.lifecycle_generation 1 + 1

let lifecycle_error_to_string = function
  | Session_terminating { session_id } ->
      Printf.sprintf "MCP session %s termination is in progress." session_id
  | Session_unknown { session_id } ->
      Printf.sprintf
        "Unknown Mcp-Session-Id %s. Retry initialize without the Mcp-Session-Id header."
        session_id
  | Session_owner_rejected { message } -> message

let begin_operation_locked t session_id =
  let gates = Atomic.get t.operation_gate_by_session in
  match Owner_map.find_opt session_id gates with
  | Some (Draining _) | Some (Delete_committed _) ->
      Error (Session_terminating { session_id })
  | Some (Open ({ generation; in_flight } as gate)) ->
      let updated =
        Owner_map.add session_id (Open { gate with in_flight = in_flight + 1 })
          gates
      in
      Atomic.set t.operation_gate_by_session updated;
      Ok
        {
          operation_session_id = session_id;
          operation_generation = generation;
          operation_released = Atomic.make false;
        }
  | None ->
      let generation = next_lifecycle_generation t in
      let updated =
        Owner_map.add session_id (Open { generation; in_flight = 1 }) gates
      in
      Atomic.set t.operation_gate_by_session updated;
      Ok
        {
          operation_session_id = session_id;
          operation_generation = generation;
          operation_released = Atomic.make false;
        }

let begin_cleanup_operation_locked t session_id =
  let gates = Atomic.get t.operation_gate_by_session in
  match Owner_map.find_opt session_id gates with
  | Some (Delete_committed _) -> Error (Session_terminating { session_id })
  | Some (Open _) | None -> begin_operation_locked t session_id
  | Some (Draining gate) ->
      let operation_generation =
        match gate.operation_generation with
        | Some generation -> generation
        | None -> next_lifecycle_generation t
      in
      let drained, resolve_drained =
        if gate.in_flight = 0 then Eio.Promise.create ()
        else gate.drained, gate.resolve_drained
      in
      Atomic.set t.operation_gate_by_session
        (Owner_map.add session_id
           (Draining
              { gate with
                operation_generation = Some operation_generation;
                in_flight = gate.in_flight + 1;
                drained;
                resolve_drained;
              })
           gates);
      Ok
        {
          operation_session_id = session_id;
          operation_generation;
          operation_released = Atomic.make false;
        }

type operation_release =
  | Release_complete
  | Resolve_drain of unit Eio.Promise.u
  | Release_state_mismatch

let finish_operation_locked t operation =
  let gates = Atomic.get t.operation_gate_by_session in
  match Owner_map.find_opt operation.operation_session_id gates with
  | Some (Open { generation; in_flight })
    when generation = operation.operation_generation && in_flight > 0 ->
      let updated =
        if in_flight = 1 then
          Owner_map.remove operation.operation_session_id gates
        else
          Owner_map.add operation.operation_session_id
            (Open { generation; in_flight = in_flight - 1 }) gates
      in
      Atomic.set t.operation_gate_by_session updated;
      Release_complete
  | Some
      (Draining
        ({ operation_generation = Some generation; in_flight; _ } as gate))
    when generation = operation.operation_generation && in_flight > 0 ->
      let in_flight = in_flight - 1 in
      let updated =
        Owner_map.add operation.operation_session_id
          (Draining { gate with in_flight }) gates
      in
      Atomic.set t.operation_gate_by_session updated;
      if in_flight = 0 then Resolve_drain gate.resolve_drained
      else Release_complete
  | Some (Draining _) | Some (Delete_committed _) | Some (Open _) | None ->
      Release_state_mismatch

let resolve_operation_release = function
  | Resolve_drain resolver ->
      (* fire-and-forget: resolving an already-completed drain is harmless. *)
      ignore (Eio.Promise.try_resolve resolver () : bool)
  | Release_complete -> ()
  | Release_state_mismatch ->
      Log.Server.error
        "MCP session operation release did not match the active generation"

let finish_operation t operation =
  if Atomic.compare_and_set operation.operation_released false true then
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      finish_operation_locked t operation)
    |> resolve_operation_release

let same_credential_owner
      (left : Server_transport_admission.identity)
      (right : Server_transport_admission.identity) =
  String.equal left.agent_name right.agent_name

let owner_mismatch_message ~session_id =
  Printf.sprintf
    "SSE session %s is not owned by the authenticated credential."
    session_id

let authorize_retained_delete_owner deletion requester =
  match deletion.owner_at_prepare with
  | Some owner when same_credential_owner owner requester -> Ok ()
  | Some _
    when requester.Server_transport_admission.role = Masc_domain.Admin ->
      Ok ()
  | Some _ -> Error (owner_mismatch_message ~session_id:deletion.session_id)
  | None when requester.Server_transport_admission.role = Masc_domain.Admin ->
      Ok ()
  | None ->
      Error
        (Printf.sprintf
           "Session %s has no credential owner metadata; only Admin may resume its deletion cleanup."
           deletion.session_id)

let validate_connection_owner t ~session_id ~requester =
  match Owner_map.find_opt session_id (Atomic.get t.owner_by_session) with
  | None -> Ok ()
  | Some (Deleting _) ->
      Error
        (Printf.sprintf "SSE session %s deletion cleanup is in progress."
           session_id)
  | Some (Connecting claim)
    when same_credential_owner claim.lease.owner requester ->
      Ok ()
  | Some (Active active)
    when same_credential_owner active.lease.owner requester ->
      Ok ()
  | Some (Releasing lease) when same_credential_owner lease.owner requester ->
      Ok ()
  | Some _ -> Error (owner_mismatch_message ~session_id)

let validate_mcp_session_owner_for_request t ~session_id ~requester =
  let* () = validate_connection_owner t ~session_id ~requester in
  match Store.find t.sessions ~session_id with
  | Some (Store.Stable_state (Store.Active session))
    when same_credential_owner session.owner requester ->
      Ok ()
  | Some (Store.Stable_state (Store.Active _)) ->
    Error (owner_mismatch_message ~session_id)
  | Some (Store.Stable_state (Store.Deleted _)) ->
      Error (Printf.sprintf "Session %s has been terminated." session_id)
  | Some (Store.Pending_state _) ->
    Error
      (Printf.sprintf
         "Session %s persistence is indeterminate and is unavailable until repaired."
         session_id)
  | None -> Ok ()

let begin_operation t ~session_id ~requester ~require_known =
  Stdlib.Mutex.protect t.transition_mutex (fun () ->
    let gates = Atomic.get t.operation_gate_by_session in
    match Owner_map.find_opt session_id gates with
    | Some (Draining _) | Some (Delete_committed _) ->
        Error (Session_terminating { session_id })
    | Some (Open _) | None ->
        if
          require_known
          && Option.is_none (Store.find_active t.sessions ~session_id)
        then Error (Session_unknown { session_id })
        else
          match
            validate_mcp_session_owner_for_request t ~session_id ~requester
          with
          | Error message -> Error (Session_owner_rejected { message })
          | Ok () -> begin_operation_locked t session_id)

let validate_mcp_sse_session_owner_for_request t ~session_id ~sse_kind
      ~requester =
  let* () =
    validate_mcp_session_owner_for_request t ~session_id ~requester
  in
  match sse_kind with
  | Sse.Agent_stream
    when Option.is_none (Store.find_active t.sessions ~session_id) ->
      Error
        (Printf.sprintf
           "Agent SSE session %s is not initialized; call initialize first."
           session_id)
  | Sse.Agent_stream | Sse.Observer | Sse.Presence -> Ok ()

let connection_in_progress_message ~session_id =
  Printf.sprintf "SSE session %s already has a connection setup in progress."
    session_id

let same_sse_kind left right =
  match left, right with
  | Sse.Agent_stream, Sse.Agent_stream
  | Sse.Observer, Sse.Observer
  | Sse.Presence, Sse.Presence ->
      true
  | Sse.Agent_stream, (Sse.Observer | Sse.Presence)
  | Sse.Observer, (Sse.Agent_stream | Sse.Presence)
  | Sse.Presence, (Sse.Agent_stream | Sse.Observer) ->
      false

let same_wire_binding (lease : lease) ~lifecycle_session_id ~sse_kind
      ~requester =
  same_credential_owner lease.owner requester
  && String.equal lease.lifecycle_session_id lifecycle_session_id
  && same_sse_kind lease.sse_kind sse_kind

let wire_binding_mismatch_message ~session_id =
  Printf.sprintf
    "SSE session %s is already bound to a different lifecycle or stream kind."
    session_id

let validate_derived_wire_binding t ~session_id ~lifecycle_session_id ~sse_kind
      ~requester =
  match
    Owner_map.find_opt session_id (Atomic.get t.derived_binding_by_wire)
  with
  | None -> Ok ()
  | Some binding
    when String.equal binding.lifecycle_session_id lifecycle_session_id
         && same_credential_owner binding.owner requester
         && same_sse_kind binding.sse_kind sse_kind ->
      Ok ()
  | Some _ -> Error (wire_binding_mismatch_message ~session_id)

let install_derived_wire_binding t ~session_id ~lifecycle_session_id ~sse_kind
      ~requester =
  if not (String.equal session_id lifecycle_session_id) then
    let bindings = Atomic.get t.derived_binding_by_wire in
    if not (Owner_map.mem session_id bindings) then
      Atomic.set t.derived_binding_by_wire
        (Owner_map.add session_id
           { lifecycle_session_id; owner = requester; sse_kind }
           bindings)

let rec claim_connection t ~session_id ~lifecycle_session_id ~sse_kind
      ~requester ~setup_operation =
  let owners = Atomic.get t.owner_by_session in
  match Owner_map.find_opt session_id owners with
  | Some (Deleting _) ->
      Error
        (Printf.sprintf "SSE session %s deletion cleanup is in progress."
           session_id)
  | Some (Connecting claim)
    when not (same_credential_owner claim.lease.owner requester) ->
      Error (owner_mismatch_message ~session_id)
  | Some (Connecting claim)
    when not
           (same_wire_binding claim.lease ~lifecycle_session_id ~sse_kind
              ~requester) ->
      Error (wire_binding_mismatch_message ~session_id)
  | Some (Active active)
    when not (same_credential_owner active.lease.owner requester) ->
      Error (owner_mismatch_message ~session_id)
  | Some (Active active)
    when not
           (same_wire_binding active.lease ~lifecycle_session_id ~sse_kind
              ~requester) ->
      Error (wire_binding_mismatch_message ~session_id)
  | Some (Releasing lease)
    when not (same_credential_owner lease.owner requester) ->
      Error (owner_mismatch_message ~session_id)
  | Some (Releasing lease)
    when not
           (same_wire_binding lease ~lifecycle_session_id ~sse_kind ~requester)
    ->
      Error (wire_binding_mismatch_message ~session_id)
  | Some (Connecting _) -> Error (connection_in_progress_message ~session_id)
  | Some (Releasing _) ->
      Error
        (Printf.sprintf "SSE session %s disconnect cleanup is in progress."
           session_id)
  | Some (Active _) | None ->
      let lease =
        {
          session_id;
          lifecycle_session_id;
          owner = requester;
          sse_kind;
          setup_operation;
          lease_released = Atomic.make false;
        }
      in
      let previous_active =
        match Owner_map.find_opt session_id owners with
        | Some (Active previous) -> Some previous
        | Some (Connecting _)
        | Some (Releasing _)
        | Some (Deleting _)
        | None ->
            None
      in
      let updated =
        Owner_map.add session_id (Connecting { lease; previous_active }) owners
      in
      if Atomic.compare_and_set t.owner_by_session owners updated then Ok lease
      else
        claim_connection t ~session_id ~lifecycle_session_id ~sse_kind
          ~requester ~setup_operation

let claim_mcp_sse_session_owner_for_request t ~session_id
      ?lifecycle_session_id ~sse_kind ~requester =
  let lifecycle_session_id =
    (* DET-OK: lifecycle id falls back to the authenticated session identity. *)
    Option.value ~default:session_id lifecycle_session_id
  in
  let result, operation_release =
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      match
        validate_mcp_sse_session_owner_for_request t ~session_id ~sse_kind
          ~requester
      with
      | Error msg -> Error msg, None
      | Ok () -> (
          let wire_validation =
            match
              Owner_map.find_opt session_id (Atomic.get t.deletion_by_wire)
            with
            | Some _ ->
                Error
                  (Printf.sprintf
                     "SSE session %s deletion cleanup is in progress."
                     session_id)
            | None ->
                validate_derived_wire_binding t ~session_id
                  ~lifecycle_session_id ~sse_kind ~requester
          in
          match wire_validation with
          | Error msg -> Error msg, None
          | Ok () -> (
          let lifecycle_validation =
            if String.equal lifecycle_session_id session_id then Ok ()
            else
              let* () =
                validate_mcp_session_owner_for_request t
                  ~session_id:lifecycle_session_id ~requester
              in
              if
                Option.is_some
                  (Store.find_active t.sessions
                     ~session_id:lifecycle_session_id)
              then Ok ()
              else
                Error
                  (Printf.sprintf
                     "Related MCP session %s is not initialized; call initialize first."
                     lifecycle_session_id)
          in
          match lifecycle_validation with
          | Error msg -> Error msg, None
          | Ok () -> (
          match begin_operation_locked t lifecycle_session_id with
          | Error lifecycle_error ->
              Error (lifecycle_error_to_string lifecycle_error), None
          | Ok setup_operation -> (
              match
                claim_connection t ~session_id ~lifecycle_session_id ~sse_kind
                  ~requester ~setup_operation
              with
              | Ok lease ->
                  install_derived_wire_binding t ~session_id
                    ~lifecycle_session_id ~sse_kind ~requester;
                  Ok lease, None
              | Error msg ->
                  Atomic.set setup_operation.operation_released true;
                  Error msg, Some (finish_operation_locked t setup_operation)))))
    )
  in
  Option.iter resolve_operation_release operation_release;
  result

let rec activate_claim t (lease : lease) ~client_id =
  let owners = Atomic.get t.owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting claim) when claim.lease == lease ->
      let updated =
        Owner_map.add lease.session_id (Active { lease; client_id }) owners
      in
      if Atomic.compare_and_set t.owner_by_session owners updated then Ok ()
      else activate_claim t lease ~client_id
  | Some (Active current)
    when current.lease == lease && current.client_id = client_id ->
      Ok ()
  | Some _ | None ->
      Error
        (Printf.sprintf "SSE session %s ownership claim is no longer current."
           lease.session_id)

let activate t (lease : lease) ~client_id =
  let result =
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      let* () =
        validate_mcp_sse_session_owner_for_request t
          ~session_id:lease.session_id ~sse_kind:lease.sse_kind
          ~requester:lease.owner
      in
      activate_claim t lease ~client_id)
  in
  (match result with
  | Ok () -> finish_operation t lease.setup_operation
  | Error _ -> ());
  result

let rec commit_previous_retirement_claim t (lease : lease) =
  let owners = Atomic.get t.owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting ({ previous_active = Some previous; _ } as claim))
    when claim.lease == lease ->
      let updated =
        Owner_map.add lease.session_id
          (Connecting { claim with previous_active = None }) owners
      in
      if Atomic.compare_and_set t.owner_by_session owners updated then
        Ok (Some previous.client_id)
      else commit_previous_retirement_claim t lease
  | Some (Connecting claim) when claim.lease == lease -> Ok None
  | Some _ | None ->
      Error
        (Printf.sprintf
           "SSE session %s ownership claim was superseded before reconnect retirement."
           lease.session_id)

let commit_previous_retirement t (lease : lease) =
  Stdlib.Mutex.protect t.transition_mutex (fun () ->
    commit_previous_retirement_claim t lease)

let cleanup_backing_session t (lease : lease) =
  if Option.is_none (Store.find_active t.sessions ~session_id:lease.session_id)
  then
    match Session.McpSessionStore.peek lease.session_id with
    | Some { agent_name = Some agent_name; _ }
      when String.equal
             lease.owner.Server_transport_admission.agent_name agent_name ->
        (* fire-and-forget: stale backing cleanup cannot change the owner state. *)
        ignore (Session.McpSessionStore.remove lease.session_id)
    | Some _ | None -> ()

let rec remove_releasing t (lease : lease) =
  let owners = Atomic.get t.owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Releasing current) when current == lease ->
      let updated = Owner_map.remove lease.session_id owners in
      if not (Atomic.compare_and_set t.owner_by_session owners updated) then
        remove_releasing t lease
  | Some _ | None -> ()

let finish_release t (lease : lease) =
  Fun.protect ~finally:(fun () -> remove_releasing t lease) (fun () ->
    (* Disconnect hooks commonly run while their connection switch is being
       cancelled.  Backing cleanup awaits the McpSessionStore actor, so defer
       cancellation until that ownership record is removed; otherwise the
       lease map would be released while a stale credential owner remained. *)
    Eio.Cancel.protect (fun () -> cleanup_backing_session t lease))

type release_plan =
  | Release_without_cleanup
  | Release_with_cleanup of operation_lease option

let prepare_release_locked t (lease : lease) =
  let owners = Atomic.get t.owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting { lease = current; previous_active = Some previous })
    when current == lease ->
      let updated = Owner_map.add lease.session_id (Active previous) owners in
      Atomic.set t.owner_by_session updated;
      Release_without_cleanup
  | Some (Connecting claim) when claim.lease == lease ->
      let updated = Owner_map.add lease.session_id (Releasing lease) owners in
      Atomic.set t.owner_by_session updated;
      (* The still-open setup operation already protects this cleanup from a
         concurrent DELETE, so a second lifecycle operation is unnecessary. *)
      Release_with_cleanup None
  | Some (Connecting ({ previous_active = Some previous; _ } as claim))
    when previous.lease == lease ->
      let updated =
        Owner_map.add lease.session_id
          (Connecting { claim with previous_active = None }) owners
      in
      Atomic.set t.owner_by_session updated;
      Release_without_cleanup
  | Some (Active current) when current.lease == lease ->
      (* Activation has already released the setup operation. Open a new
         lifecycle operation at the same linearization point as Active ->
         Releasing. DELETE therefore either snapshots the Active connection
         first, or waits until disconnect/backing cleanup is complete. *)
      (match begin_cleanup_operation_locked t lease.lifecycle_session_id with
      | Ok cleanup_operation ->
          Atomic.set t.owner_by_session
            (Owner_map.add lease.session_id (Releasing lease) owners);
          Release_with_cleanup (Some cleanup_operation)
      | Error (Session_terminating _) ->
          (* DELETE won the transition mutex. Its frozen wire reservation and
             tombstone own the remaining cleanup; this stale callback must not
             remove a backing session after deletion finishes. *)
          Release_without_cleanup
      | Error (Session_unknown _ | Session_owner_rejected _) ->
          Log.Server.error
            "SSE release could not open its lifecycle cleanup operation: wire_session=%s lifecycle_session=%s"
            lease.session_id lease.lifecycle_session_id;
          Release_without_cleanup)
  | Some (Releasing current) when current == lease -> Release_without_cleanup
  | Some _ -> Release_without_cleanup
  | None ->
      (* DELETE may invalidate an in-flight claim while its backing-session
         creation is awaiting the actor.  If no newer claim owns the id, take
         a temporary Releasing slot and remove any backing that the invalidated
         request created after DELETE's cleanup.  A newer claim makes this CAS
         fail and is never disturbed by the stale release. *)
      let updated = Owner_map.add lease.session_id (Releasing lease) owners in
      Atomic.set t.owner_by_session updated;
      Release_with_cleanup None

let release t (lease : lease) =
  if Atomic.compare_and_set lease.lease_released false true then
    Fun.protect
      ~finally:(fun () -> finish_operation t lease.setup_operation)
      (fun () ->
        match
          Stdlib.Mutex.protect t.transition_mutex (fun () ->
            prepare_release_locked t lease)
        with
        | Release_without_cleanup -> ()
        | Release_with_cleanup cleanup_operation ->
            Fun.protect
              ~finally:(fun () ->
                Option.iter (finish_operation t) cleanup_operation)
              (fun () -> finish_release t lease))

let ensure_backing_session_for_owner t ~session_id ~requester =
  let owner_matches = function
    | Some agent_name ->
        String.equal agent_name requester.Server_transport_admission.agent_name
    | None -> false
  in
  let create_or_validate () =
    let session =
      Session.McpSessionStore.get_or_create ~id:session_id
        ~agent_name:requester.agent_name ()
    in
    if owner_matches session.agent_name then Ok ()
    else Error (owner_mismatch_message ~session_id)
  in
  match Session.McpSessionStore.peek session_id with
  | None -> create_or_validate ()
  | Some session when owner_matches session.agent_name -> Ok ()
  | Some session
    when Option.is_none session.agent_name
         && Option.is_some (Store.find_active t.sessions ~session_id) ->
      (* Old initialized GETs created ownerless backing entries.  The caller's
         immutable transport owner has already been verified. *)
      (* fire-and-forget: removing the obsolete ownerless backing entry is cleanup only. *)
      ignore (Session.McpSessionStore.remove session_id);
      create_or_validate ()
  | Some _ -> Error (owner_mismatch_message ~session_id)

let reserve_deletion_wires t deletion =
  let wire_sessions =
    Owner_map.fold
      (fun wire_session_id binding wire_sessions ->
        if String.equal binding.lifecycle_session_id deletion.session_id then
          wire_session_id :: wire_sessions
        else wire_sessions)
      (Atomic.get t.derived_binding_by_wire)
      [ deletion.session_id ]
  in
  let reservations = Atomic.get t.deletion_by_wire in
  let reservations =
    List.fold_left
      (fun current wire_session_id ->
        Owner_map.add wire_session_id deletion current)
      reservations wire_sessions
  in
  Atomic.set t.deletion_by_wire reservations

let remove_deletion_wire_reservations t deletion =
  let reservations = Atomic.get t.deletion_by_wire in
  let retained =
    Owner_map.filter
      (fun _ current -> current.generation <> deletion.generation)
      reservations
  in
  Atomic.set t.deletion_by_wire retained

let retained_delete_authorization t ~session_id ~requester =
  Stdlib.Mutex.protect t.transition_mutex (fun () ->
    match
      Owner_map.find_opt session_id (Atomic.get t.operation_gate_by_session)
    with
    | Some (Delete_committed committed) ->
        (match
           authorize_retained_delete_owner committed.deletion requester
         with
        | Ok () -> Retained_delete_authorized
        | Error message -> Retained_delete_rejected { message })
    | Some (Draining { deletion; retryable = true; _ }) ->
      (match authorize_retained_delete_owner deletion requester with
       | Ok () -> Retained_delete_authorized
       | Error message -> Retained_delete_rejected { message })
    | Some (Draining { retryable = false; _ }) -> Retained_delete_in_progress
    | Some (Open _) | None -> No_retained_delete)

let authorize_mcp_session_delete t ~session_id ~requester =
  match Store.find t.sessions ~session_id with
  | Some (Store.Stable_state (Store.Active session))
    when same_credential_owner session.owner requester ->
      Ok ()
  | Some (Store.Stable_state (Store.Active _))
    when requester.Server_transport_admission.role = Masc_domain.Admin ->
      Ok ()
  | Some (Store.Stable_state (Store.Active _)) ->
    Error (owner_mismatch_message ~session_id)
  | Some (Store.Stable_state (Store.Deleted _)) ->
      Error (Printf.sprintf "Session %s has already been terminated." session_id)
  | Some (Store.Pending_state _) ->
    Error
      (Printf.sprintf
         "Session %s persistence is indeterminate; retry requires its retained deletion generation."
         session_id)
  | None -> Error (Printf.sprintf "Unknown MCP session %s." session_id)

let begin_mcp_session_delete_or_resume t ~session_id ~requester =
  let result, resolve_drained =
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      let gates = Atomic.get t.operation_gate_by_session in
      match Owner_map.find_opt session_id gates with
      | Some (Delete_committed committed) ->
          (match authorize_retained_delete_owner committed.deletion requester with
          | Ok () -> Ok (Resume_committed_delete committed), None
          | Error msg -> Error msg, None)
      | Some (Draining ({ deletion; retryable = true; _ } as gate)) ->
        (match authorize_retained_delete_owner deletion requester with
         | Error msg -> Error msg, None
         | Ok () ->
           Atomic.set t.operation_gate_by_session
             (Owner_map.add session_id
                (Draining { gate with retryable = false }) gates);
           Ok (Prepared_delete deletion), None)
      | Some (Draining { retryable = false; _ }) ->
        ( Error
            (Printf.sprintf
               "MCP session %s deletion is already in progress." session_id),
          None )
      | Some (Open _) | None ->
          (match
             authorize_mcp_session_delete t ~session_id ~requester
           with
          | Error msg -> Error msg, None
          | Ok () ->
              let owner_at_prepare =
                Option.map
                  (fun session -> session.Store.owner)
                  (Store.find_active t.sessions ~session_id)
              in
              (match Owner_map.find_opt session_id gates with
              | Some (Draining _) | Some (Delete_committed _) ->
              ( Error
                  (Printf.sprintf
                     "MCP session %s deletion is already in progress."
                     session_id),
                None )
              | Some (Open { generation; in_flight }) ->
              let drained, resolve_drained = Eio.Promise.create () in
              let deletion =
                {
                  session_id;
                  generation = next_lifecycle_generation t;
                  owner_at_prepare;
                }
              in
              reserve_deletion_wires t deletion;
              Atomic.set t.operation_gate_by_session
                (Owner_map.add session_id
                   (Draining
                      {
                        deletion;
                        operation_generation = Some generation;
                        in_flight;
                        drained;
                        resolve_drained;
                        retryable = false;
                      })
                   gates);
              ( Ok (Prepared_delete deletion),
                if in_flight = 0 then Some resolve_drained else None )
              | None ->
              let drained, resolve_drained = Eio.Promise.create () in
              let deletion =
                {
                  session_id;
                  generation = next_lifecycle_generation t;
                  owner_at_prepare;
                }
              in
              reserve_deletion_wires t deletion;
              Atomic.set t.operation_gate_by_session
                (Owner_map.add session_id
                   (Draining
                      {
                        deletion;
                        operation_generation = None;
                        in_flight = 0;
                        drained;
                        resolve_drained;
                        retryable = false;
                      })
                   gates);
              Ok (Prepared_delete deletion), Some resolve_drained)))
  in
  Option.iter
    (fun resolver -> ignore (Eio.Promise.try_resolve resolver () : bool))
    resolve_drained;
  result

let begin_mcp_session_delete t ~session_id ~requester =
  match begin_mcp_session_delete_or_resume t ~session_id ~requester with
  | Ok (Prepared_delete deletion) -> Ok deletion
  | Ok (Resume_committed_delete _) ->
      Error
        (Printf.sprintf
           "MCP session %s deletion cleanup is already committed." session_id)
  | Error msg -> Error msg

let rec await_mcp_session_delete_drain t deletion =
  let pending =
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      match
        Owner_map.find_opt deletion.session_id
          (Atomic.get t.operation_gate_by_session)
      with
      | Some (Draining { deletion = current; in_flight; drained; _ })
        when current.generation = deletion.generation ->
          if in_flight = 0 then None else Some drained
      | Some (Delete_committed committed)
        when committed.deletion.generation = deletion.generation ->
          None
      | Some (Open _) | Some (Draining _) | Some (Delete_committed _) | None ->
          None)
  in
  match pending with
  | None -> ()
  | Some drained ->
      Eio.Promise.await drained;
      await_mcp_session_delete_drain t deletion

let retain_mcp_session_delete_for_retry t deletion =
  Stdlib.Mutex.protect t.transition_mutex (fun () ->
    let gates = Atomic.get t.operation_gate_by_session in
    match Owner_map.find_opt deletion.session_id gates with
    | Some (Draining ({ deletion = current; in_flight = 0; _ } as gate))
      when current.generation = deletion.generation ->
      Atomic.set t.operation_gate_by_session
        (Owner_map.add deletion.session_id
           (Draining { gate with retryable = true }) gates);
      Ok ()
    | Some (Draining { deletion = current; in_flight; _ })
      when current.generation = deletion.generation && in_flight > 0 ->
      Error
        (Printf.sprintf
           "MCP session %s cannot expose a persistence retry while %d operations remain in flight."
           deletion.session_id in_flight)
    | Some (Open _) | Some (Draining _) | Some (Delete_committed _) | None ->
      Error
        (Printf.sprintf
           "MCP session %s deletion generation is no longer available for persistence retry."
           deletion.session_id))

let reserved_wire_sessions t deletion =
  Owner_map.fold
    (fun wire_session_id current wire_sessions ->
      if current.generation = deletion.generation then
        wire_session_id :: wire_sessions
      else wire_sessions)
    (Atomic.get t.deletion_by_wire)
    []

let rec commit_owner_tombstones t deletion wire_sessions =
  let owners = Atomic.get t.owner_by_session in
  let conflicting_deletion =
    List.find_opt
      (fun wire_session_id ->
        match Owner_map.find_opt wire_session_id owners with
        | Some (Deleting current) ->
            current.generation <> deletion.generation
        | Some (Connecting _) | Some (Active _) | Some (Releasing _) | None ->
            false)
      wire_sessions
  in
  match conflicting_deletion with
  | Some wire_session_id ->
      Error
        (Printf.sprintf
           "SSE wire session %s belongs to another deletion generation."
           wire_session_id)
  | None ->
      let active_connections =
        List.filter_map
          (fun wire_session_id ->
            match Owner_map.find_opt wire_session_id owners with
            | Some (Active { client_id; _ }) ->
                Some (wire_session_id, client_id)
            | Some (Connecting _)
            | Some (Releasing _)
            | Some (Deleting _)
            | None ->
                None)
          wire_sessions
      in
      let updated =
        List.fold_left
          (fun current wire_session_id ->
            Owner_map.add wire_session_id (Deleting deletion) current)
          owners wire_sessions
      in
      if Atomic.compare_and_set t.owner_by_session owners updated then
        Ok { deletion; wire_sessions; active_connections }
      else commit_owner_tombstones t deletion wire_sessions

type 'a drain_transition =
  | Drain_transition_retry
  | Drain_transition_complete of 'a

let rec commit_mcp_session_delete t deletion =
  await_mcp_session_delete_drain t deletion;
  match
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      let gates = Atomic.get t.operation_gate_by_session in
      match Owner_map.find_opt deletion.session_id gates with
      | Some (Draining { deletion = current; in_flight = 0; _ })
        when current.generation = deletion.generation ->
          let wire_sessions = reserved_wire_sessions t deletion in
          let result =
            let* committed = commit_owner_tombstones t deletion wire_sessions in
            Atomic.set t.operation_gate_by_session
              (Owner_map.add deletion.session_id (Delete_committed committed)
                 gates);
            Ok committed
          in
          Drain_transition_complete result
      | Some (Draining { deletion = current; in_flight; _ })
        when current.generation = deletion.generation && in_flight > 0 ->
          Drain_transition_retry
      | Some (Delete_committed committed)
        when committed.deletion.generation = deletion.generation ->
          Drain_transition_complete (Ok committed)
      | Some (Open _) | Some (Draining _) | Some (Delete_committed _) | None ->
          Drain_transition_complete
            (Error
               (Printf.sprintf
                  "MCP session %s deletion generation is no longer current."
                  deletion.session_id)))
  with
  | Drain_transition_retry -> commit_mcp_session_delete t deletion
  | Drain_transition_complete result -> result

let committed_deletion_active_connections committed =
  committed.active_connections

let committed_deletion_wire_sessions committed = committed.wire_sessions

let rec abort_mcp_session_delete t deletion =
  await_mcp_session_delete_drain t deletion;
  match
    Stdlib.Mutex.protect t.transition_mutex (fun () ->
      let gates = Atomic.get t.operation_gate_by_session in
      match Owner_map.find_opt deletion.session_id gates with
      | Some (Draining { deletion = current; in_flight = 0; _ })
        when current.generation = deletion.generation ->
          remove_deletion_wire_reservations t deletion;
          Atomic.set t.operation_gate_by_session
            (Owner_map.remove deletion.session_id gates);
          Drain_transition_complete (Ok ())
      | Some (Draining { deletion = current; in_flight; _ })
        when current.generation = deletion.generation && in_flight > 0 ->
          Drain_transition_retry
      | Some (Open _) | Some (Draining _) | Some (Delete_committed _) | None ->
          Drain_transition_complete
            (Error
               (Printf.sprintf
                  "MCP session %s deletion cannot be aborted after commit or supersession."
                  deletion.session_id)))
  with
  | Drain_transition_retry -> abort_mcp_session_delete t deletion
  | Drain_transition_complete result -> result

let rec remove_deletion_tombstones t deletion wire_sessions =
  let owners = Atomic.get t.owner_by_session in
  let updated =
    List.fold_left
      (fun current wire_session_id ->
        match Owner_map.find_opt wire_session_id current with
        | Some (Deleting active)
          when active.generation = deletion.generation ->
            Owner_map.remove wire_session_id current
        | Some (Connecting _)
        | Some (Active _)
        | Some (Releasing _)
        | Some (Deleting _)
        | None ->
            current)
      owners wire_sessions
  in
  if not (Atomic.compare_and_set t.owner_by_session owners updated) then
    remove_deletion_tombstones t deletion wire_sessions

let finish_mcp_session_delete t committed =
  let deletion = committed.deletion in
  Stdlib.Mutex.protect t.transition_mutex (fun () ->
    let gates = Atomic.get t.operation_gate_by_session in
    match Owner_map.find_opt deletion.session_id gates with
    | Some (Delete_committed current)
      when current.deletion.generation = deletion.generation ->
        remove_deletion_tombstones t deletion committed.wire_sessions;
        remove_deletion_wire_reservations t deletion;
        let bindings = Atomic.get t.derived_binding_by_wire in
        Atomic.set t.derived_binding_by_wire
          (Owner_map.filter
             (fun _ binding ->
               not
                 (String.equal binding.lifecycle_session_id deletion.session_id))
             bindings);
        Atomic.set t.operation_gate_by_session
          (Owner_map.remove deletion.session_id gates)
    | Some (Open _) | Some (Draining _) | Some (Delete_committed _) | None ->
        Log.Server.error
          "MCP session deletion finish ignored a non-current generation: session=%s generation=%d"
          deletion.session_id deletion.generation)
