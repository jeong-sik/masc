open Result.Syntax

module Owner_map = Set_util.StringMap
module Transport_session = Server_mcp_transport_http_session

type lease = {
  session_id : string;
  owner : Server_transport_admission.identity;
  sse_kind : Sse.session_kind;
}

type connection_claim = {
  lease : lease;
  previous_active : lease option;
}

type lease_state =
  | Connecting of connection_claim
  | Active of lease
  | Releasing of lease

let owner_by_session : lease_state Owner_map.t Atomic.t =
  Atomic.make Owner_map.empty

(** The transport owner and process-local lease intentionally remain separate
    SSOTs.  Serialize only their bounded CAS transitions so initialize, SSE
    claim/activation, and DELETE cannot each observe the wire id as unowned. *)
let transition_mutex = Stdlib.Mutex.create ()

let same_credential_owner
      (left : Server_transport_admission.identity)
      (right : Server_transport_admission.identity) =
  String.equal left.agent_name right.agent_name

let owner_mismatch_message ~session_id =
  Printf.sprintf
    "SSE session %s is not owned by the authenticated credential."
    session_id

let lease_of_state = function
  | Connecting claim -> claim.lease
  | Active lease | Releasing lease -> lease

let validate_connection_owner ~session_id ~requester =
  match Owner_map.find_opt session_id (Atomic.get owner_by_session) with
  | None -> Ok ()
  | Some state
    when same_credential_owner (lease_of_state state).owner requester ->
      Ok ()
  | Some _ -> Error (owner_mismatch_message ~session_id)

let validate_mcp_session_owner_for_request ~session_id ~requester =
  let* () =
    Transport_session.validate_mcp_session_owner_for_request ~session_id
      ~requester
  in
  if Transport_session.is_known_session session_id then Ok ()
  else validate_connection_owner ~session_id ~requester

let bind_mcp_session_owner_if_initialize_succeeded session_id ~requester
      ~request_body ~response_json =
  Stdlib.Mutex.protect transition_mutex (fun () ->
    let* () = validate_mcp_session_owner_for_request ~session_id ~requester in
    Transport_session.bind_mcp_session_owner_if_initialize_succeeded session_id
      ~requester ~request_body ~response_json)

let validate_mcp_sse_session_owner_for_request ~session_id ~sse_kind
      ~requester =
  let* () = validate_mcp_session_owner_for_request ~session_id ~requester in
  match sse_kind with
  | Sse.Agent_stream when not (Transport_session.is_known_session session_id) ->
      Error
        (Printf.sprintf
           "Agent SSE session %s is not initialized; call initialize first."
           session_id)
  | Sse.Agent_stream | Sse.Observer | Sse.Presence -> Ok ()

let connection_in_progress_message ~session_id =
  Printf.sprintf "SSE session %s already has a connection setup in progress."
    session_id

let rec claim_connection ~session_id ~sse_kind ~requester =
  let owners = Atomic.get owner_by_session in
  match Owner_map.find_opt session_id owners with
  | Some state
    when not
           (same_credential_owner (lease_of_state state).owner requester) ->
      Error (owner_mismatch_message ~session_id)
  | Some (Connecting _) -> Error (connection_in_progress_message ~session_id)
  | Some (Releasing _) ->
      Error
        (Printf.sprintf "SSE session %s disconnect cleanup is in progress."
           session_id)
  | Some (Active _) | None ->
      let lease = { session_id; owner = requester; sse_kind } in
      let previous_active =
        match Owner_map.find_opt session_id owners with
        | Some (Active previous) -> Some previous
        | Some (Connecting _) | Some (Releasing _) | None -> None
      in
      let updated =
        Owner_map.add session_id (Connecting { lease; previous_active }) owners
      in
      if Atomic.compare_and_set owner_by_session owners updated then Ok lease
      else claim_connection ~session_id ~sse_kind ~requester

let claim_mcp_sse_session_owner_for_request ~session_id ~sse_kind
      ~requester =
  Stdlib.Mutex.protect transition_mutex (fun () ->
    let* () =
      validate_mcp_sse_session_owner_for_request ~session_id ~sse_kind
        ~requester
    in
    claim_connection ~session_id ~sse_kind ~requester)

let rec activate_claim lease =
  let owners = Atomic.get owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting claim) when claim.lease == lease ->
      let updated = Owner_map.add lease.session_id (Active lease) owners in
      if Atomic.compare_and_set owner_by_session owners updated then Ok ()
      else activate_claim lease
  | Some (Active current) when current == lease -> Ok ()
  | Some _ | None ->
      Error
        (Printf.sprintf "SSE session %s ownership claim is no longer current."
           lease.session_id)

let activate lease =
  Stdlib.Mutex.protect transition_mutex (fun () ->
    let* () =
      validate_mcp_sse_session_owner_for_request
        ~session_id:lease.session_id ~sse_kind:lease.sse_kind
        ~requester:lease.owner
    in
    activate_claim lease)

let rec discard_previous lease =
  let owners = Atomic.get owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting claim)
    when claim.lease == lease && Option.is_some claim.previous_active ->
      let updated =
        Owner_map.add lease.session_id
          (Connecting { claim with previous_active = None }) owners
      in
      if not (Atomic.compare_and_set owner_by_session owners updated) then
        discard_previous lease
  | Some (Connecting claim) when claim.lease == lease -> ()
  | Some (Active current) when current == lease -> ()
  | Some (Releasing current) when current == lease -> ()
  | Some _ | None -> ()

let cleanup_backing_session lease =
  if not (Transport_session.is_known_session lease.session_id) then
    match Session.McpSessionStore.peek lease.session_id with
    | Some { agent_name = Some agent_name; _ }
      when String.equal
             lease.owner.Server_transport_admission.agent_name agent_name ->
        ignore (Session.McpSessionStore.remove lease.session_id)
    | Some _ | None -> ()

let rec remove_releasing lease =
  let owners = Atomic.get owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Releasing current) when current == lease ->
      let updated = Owner_map.remove lease.session_id owners in
      if not (Atomic.compare_and_set owner_by_session owners updated) then
        remove_releasing lease
  | Some _ | None -> ()

let finish_release lease =
  Fun.protect ~finally:(fun () -> remove_releasing lease) (fun () ->
    (* Disconnect hooks commonly run while their connection switch is being
       cancelled.  Backing cleanup awaits the McpSessionStore actor, so defer
       cancellation until that ownership record is removed; otherwise the
       lease map would be released while a stale credential owner remained. *)
    Eio.Cancel.protect (fun () -> cleanup_backing_session lease))

let rec release lease =
  let owners = Atomic.get owner_by_session in
  match Owner_map.find_opt lease.session_id owners with
  | Some (Connecting { lease = current; previous_active = Some previous })
    when current == lease ->
      let updated = Owner_map.add lease.session_id (Active previous) owners in
      if not (Atomic.compare_and_set owner_by_session owners updated) then
        release lease
  | Some (Connecting claim) when claim.lease == lease ->
      let updated = Owner_map.add lease.session_id (Releasing lease) owners in
      if Atomic.compare_and_set owner_by_session owners updated then
        finish_release lease
      else release lease
  | Some (Connecting ({ previous_active = Some previous; _ } as claim))
    when previous == lease ->
      let updated =
        Owner_map.add lease.session_id
          (Connecting { claim with previous_active = None }) owners
      in
      if not (Atomic.compare_and_set owner_by_session owners updated) then
        release lease
  | Some (Active current) when current == lease ->
      let updated = Owner_map.add lease.session_id (Releasing lease) owners in
      if Atomic.compare_and_set owner_by_session owners updated then
        finish_release lease
      else release lease
  | Some (Releasing current) when current == lease -> ()
  | Some _ -> ()
  | None ->
      (* DELETE may invalidate an in-flight claim while its backing-session
         creation is awaiting the actor.  If no newer claim owns the id, take
         a temporary Releasing slot and remove any backing that the invalidated
         request created after DELETE's cleanup.  A newer claim makes this CAS
         fail and is never disturbed by the stale release. *)
      let updated = Owner_map.add lease.session_id (Releasing lease) owners in
      if Atomic.compare_and_set owner_by_session owners updated then
        finish_release lease
      else release lease

let ensure_backing_session_for_owner ~session_id ~requester =
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
         && Transport_session.is_known_session session_id ->
      (* Old initialized GETs created ownerless backing entries.  The caller's
         immutable transport owner has already been verified. *)
      ignore (Session.McpSessionStore.remove session_id);
      create_or_validate ()
  | Some _ -> Error (owner_mismatch_message ~session_id)

let rec invalidate_connection_lease session_id =
  let owners = Atomic.get owner_by_session in
  let updated = Owner_map.remove session_id owners in
  if not (Atomic.compare_and_set owner_by_session owners updated) then
    invalidate_connection_lease session_id

let forget_mcp_session session_id =
  Stdlib.Mutex.protect transition_mutex (fun () ->
    invalidate_connection_lease session_id;
    Transport_session.forget_mcp_session session_id)
