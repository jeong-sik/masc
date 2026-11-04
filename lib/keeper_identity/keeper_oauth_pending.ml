(** See keeper_oauth_pending.mli for why this is in memory and why nothing
    sweeps it. *)

type in_flight = {
  pending : Keeper_oauth_flow.pending;
  discovered : Keeper_oauth_discovery.t;
  client : Keeper_oauth_client_store.login_client;
}

type completion = Tools_discovered of int | Credentials_published_discovery_failed
type credential_write = Refresh_token | Client | Access_token | Expiry
type credential_publication = {
  completed_writes : credential_write list;
  interrupted_write : credential_write;
}

type status =
  | Awaiting_consent of float
  | Callback_admitted
  | Completed of completion
  | Failed
  | Credential_publication_incomplete of credential_publication
  | Expired
  | Superseded

type admission = int

type stale_start = Newer_start_admitted

type entry = {
  attempt_id : string;
  keeper : string;
  provider_id : string;
  state : string;
  in_flight : in_flight option;
  status : status;
}

type scope_state = {
  latest_start : admission;
  epoch : unit ref;
  credential_revision : unit ref;
  catalog_revision : unit ref;
}

(* Start ordering and publication revisions belong to the same scope owner.
   A start that dies during discovery still outranks earlier starts, without
   changing the credential that was already attached. *)
type t = {
  base_path : string;
  mutex : Mutex.t;
  mutable entries : entry list;
  mutable admitted : admission;
  mutable scopes : ((string * string) * scope_state) list;
}
type scope = { base_path : string; keeper : string; provider_id : string }
type attachment = {
  owner : t;
  scope : scope;
  epoch : unit ref;
  credential_revision : unit ref;
}
type catalog_publication = { attachment : attachment; revision : unit ref }
type 'a publication = Published of 'a | Publication_superseded | Publication_failed of string

let create ~base_path () : t =
  { base_path; mutex = Mutex.create (); entries = []; admitted = 0; scopes = [] }
let with_lock (t : t) f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let changed_observer : (base_path:string -> keeper:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ ~keeper:_ -> ())

let install_change_observer observer = Atomic.set changed_observer observer

(* Called under [t]'s lock, after the change it reports. *)
let notify_changed (t : t) ~keeper = (Atomic.get changed_observer) ~base_path:t.base_path ~keeper

let registry_mutex = Mutex.create ()
let by_workspace = Hashtbl.create 1
let for_base_path base_path =
  Mutex.lock registry_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock registry_mutex) (fun () ->
    match Hashtbl.find_opt by_workspace base_path with
    | Some owner -> owner
    | None ->
        let owner = create ~base_path () in
        Hashtbl.add by_workspace base_path owner;
        owner)

let set_scope_state (t : t) key state =
  t.scopes <- (key, state) :: List.remove_assoc key t.scopes

let state_for_scope (t : t) key =
  match List.assoc_opt key t.scopes with
  | Some state -> state
  | None ->
      let state = {latest_start=0; epoch=ref (); credential_revision=ref (); catalog_revision=ref ()} in
      set_scope_state t key state;
      state

let attachment_for (owner : t) ((keeper, provider_id) as key) =
  let state = state_for_scope owner key in
  {owner; scope={base_path=owner.base_path;keeper;provider_id};
   epoch=state.epoch;credential_revision=state.credential_revision}

let capture_attachment t ~keeper ~provider_id =
  with_lock t (fun () -> attachment_for t (keeper, provider_id))
let attachment_scope attachment = attachment.scope
let catalog_scope publication = publication.attachment.scope

let attachment_current_locked attachment =
  match List.assoc_opt (attachment.scope.keeper, attachment.scope.provider_id) attachment.owner.scopes with
  | None -> false
  | Some state -> state.epoch == attachment.epoch
      && state.credential_revision == attachment.credential_revision

let attachment_current attachment =
  with_lock attachment.owner (fun () -> attachment_current_locked attachment)

let begin_catalog attachment =
  with_lock attachment.owner (fun () ->
    if not (attachment_current_locked attachment) then None
    else
      let key = attachment.scope.keeper, attachment.scope.provider_id in
      let state = state_for_scope attachment.owner key in
      let revision = ref () in
      set_scope_state attachment.owner key {state with catalog_revision=revision};
      Some {attachment;revision})

let publish_catalog publication ~write =
  let attachment = publication.attachment in
  with_lock attachment.owner (fun () ->
    let state = List.assoc_opt
      (attachment.scope.keeper, attachment.scope.provider_id) attachment.owner.scopes in
    match state with
    | Some state when attachment_current_locked attachment
        && state.catalog_revision == publication.revision ->
        (match write () with Ok () -> Published () | Error detail -> Publication_failed detail)
    | None | Some _ -> Publication_superseded)

let advance_credentials t key =
  let state = state_for_scope t key in
  set_scope_state t key {state with credential_revision=ref (); catalog_revision=ref ()}

let publish_renewal attachment ~write =
  with_lock attachment.owner (fun () ->
    if not (attachment_current_locked attachment) then Publication_superseded
    else
      let key = attachment.scope.keeper, attachment.scope.provider_id in
      advance_credentials attachment.owner key;
      match write () with
      | Ok () -> Published (attachment_for attachment.owner key)
      | Error detail -> Publication_failed detail)

let retire_scope t ~keeper ~provider_id ~local_delete =
  with_lock t (fun () ->
    t.admitted <- t.admitted + 1;
    set_scope_state t (keeper,provider_id)
      {latest_start=t.admitted;epoch=ref ();credential_revision=ref ();catalog_revision=ref ()};
    t.entries <- List.map (fun (entry : entry) ->
      if entry.keeper=keeper && entry.provider_id=provider_id then
        match entry.status with
        | Awaiting_consent _ | Callback_admitted ->
            {entry with in_flight=None;status=Superseded}
        | Completed _ | Failed | Credential_publication_incomplete _ | Expired
        | Superseded -> entry
      else entry) t.entries;
    Fun.protect ~finally:(fun () -> notify_changed t ~keeper) local_delete)

let expire ~now entry = match entry.status with
  | Awaiting_consent deadline when deadline <= now ->
      {entry with in_flight=None; status=Expired}
  | Awaiting_consent _ | Callback_admitted | Completed _ | Failed
  | Credential_publication_incomplete _ | Expired
  | Superseded -> entry

let terminal = function Completed _ | Failed | Credential_publication_incomplete _
  | Expired | Superseded -> true
  | Awaiting_consent _ | Callback_admitted -> false

let admit t ~keeper ~provider_id = with_lock t (fun () ->
  t.admitted <- t.admitted + 1;
  let scope = (keeper, provider_id) in
  let state = state_for_scope t scope in
  set_scope_state t scope {state with latest_start=t.admitted};
  t.admitted)

let remember t admission ~now ~ttl_sec in_flight =
  let flow = in_flight.pending in
  let attempt_id = Random_id.hex ~bytes:16 in
  with_lock t (fun () ->
    let same_scope (entry : entry) = entry.keeper=flow.Keeper_oauth_flow.keeper
      && entry.provider_id=flow.Keeper_oauth_flow.provider_id in
    let entries = List.map (expire ~now) t.entries in
    (* Starts are ordered by the admission issued when they began, not by
       which one's discovery and registration finished first: a later start
       that fails before reaching this table still consumed its admission,
       so the newest admission issued to this Keeper and provider — not only
       the entries that survived to register — decides. A start for another
       scope does not. This earlier one is refused rather than retiring the
       consent its operator was just shown. *)
    let newest_for_scope =
      (state_for_scope t (flow.Keeper_oauth_flow.keeper, flow.Keeper_oauth_flow.provider_id)).latest_start in
    if newest_for_scope > admission then Error Newer_start_admitted
    else begin
      (* A new operator attempt retires the previous consent for the same
         scope, but cannot cancel a callback already admitted to publication.
         Completed metadata lives until that scope starts another attempt. *)
      let entries = entries
        |> List.filter (fun entry -> not (same_scope entry && terminal entry.status))
        |> List.map (fun entry -> match entry.status with
          | Awaiting_consent _ when same_scope entry ->
              {entry with in_flight=None; status=Superseded}
          (* The publication an admitted callback already holds cannot be
             cancelled, but its result must not overwrite the newer attempt's
             tokens: superseding the entry makes the older finish a no-op
             instead of a second writer. *)
          | Callback_admitted when same_scope entry ->
              {entry with in_flight=None; status=Superseded}
          | Awaiting_consent _ | Callback_admitted | Completed _ | Failed
          | Credential_publication_incomplete _
          | Expired | Superseded -> entry) in
      t.entries <- {attempt_id; keeper=flow.Keeper_oauth_flow.keeper;
        provider_id=flow.Keeper_oauth_flow.provider_id; state=flow.Keeper_oauth_flow.state;
        in_flight=Some in_flight; status=Awaiting_consent (now +. ttl_sec)} :: entries;
      notify_changed t ~keeper:flow.Keeper_oauth_flow.keeper;
      Ok attempt_id
    end)

let take t ~now ~state =
  with_lock t (fun () ->
    let found = ref None in
    t.entries <- List.map (fun entry ->
      let entry = expire ~now entry in
      match entry.status, entry.in_flight with
      | Awaiting_consent _, Some held when entry.state=state ->
          found := Some held;
          (* Admission and verifier removal publish in one locked update. *)
          {entry with in_flight=None; status=Callback_admitted}
      | (Awaiting_consent _ | Callback_admitted | Completed _ | Failed
        | Credential_publication_incomplete _
        | Expired | Superseded), (Some _ | None) -> entry) t.entries;
    Option.iter (fun (held : in_flight) ->
      notify_changed t ~keeper:held.pending.Keeper_oauth_flow.keeper) !found;
    !found)

let status t ~now ~attempt_id ~keeper ~provider_id =
  with_lock t (fun () ->
    t.entries <- List.map (expire ~now) t.entries;
    List.find_opt (fun entry -> entry.attempt_id=attempt_id
      && entry.keeper=keeper && entry.provider_id=provider_id) t.entries
    |> Option.map (fun entry -> entry.status))

type settlement = Recorded | Not_admitted

let finish t ~state outcome =
  with_lock t (fun () ->
    let recorded = ref None in
    t.entries <- List.map (fun entry ->
      if entry.state=state && entry.status=Callback_admitted
      then (recorded := Some entry.keeper;
        {entry with status=(match outcome with Ok completion -> Completed completion | Error () -> Failed)})
      else entry) t.entries;
    match !recorded with
    | Some keeper -> notify_changed t ~keeper; Recorded
    | None -> Not_admitted)

let waiting t ~now = with_lock t (fun () ->
  t.entries <- List.map (expire ~now) t.entries;
  List.fold_left (fun count entry -> match entry.status with
    | Awaiting_consent _ -> count+1
    | Callback_admitted | Completed _ | Failed | Credential_publication_incomplete _
    | Expired | Superseded -> count)
    0 t.entries)

let publish_credentials t ~state ~write =
  with_lock t (fun () ->
    match List.find_opt (fun entry -> entry.state=state && entry.status=Callback_admitted)
      t.entries with
    | None -> Publication_superseded
    | Some entry ->
      let key = entry.keeper, entry.provider_id in
      advance_credentials t key;
      let interrupted completed_writes interrupted_write =
        let progress = {completed_writes=List.rev completed_writes; interrupted_write} in
        t.entries <- List.map (fun entry ->
          if entry.state=state && entry.status=Callback_admitted
          then {entry with status=Credential_publication_incomplete progress}
          else entry) t.entries;
        notify_changed t ~keeper:(fst key) in
      let rec publish completed = function
        | [] -> Published (attachment_for t key)
        | stage :: rest ->
            (match write stage with
             | Ok () -> publish (stage :: completed) rest
             | Error detail -> interrupted completed stage; Publication_failed detail
             | exception exn ->
                 let backtrace = Printexc.get_raw_backtrace () in
                 interrupted completed stage;
                 Printexc.raise_with_backtrace exn backtrace) in
      publish [] [Refresh_token; Client; Access_token; Expiry])
