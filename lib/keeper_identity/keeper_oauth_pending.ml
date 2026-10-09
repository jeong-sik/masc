(** See keeper_oauth_pending.mli for why this is in memory and why nothing
    sweeps it. *)

type in_flight = {
  pending : Keeper_oauth_flow.pending;
  discovered : Keeper_oauth_discovery.t;
  client_id : string;
  client_secret : string option;
}

type completion = Tools_discovered of int | Credentials_published_discovery_failed

type status =
  | Awaiting_consent of float
  | Callback_admitted
  | Completed of completion
  | Failed
  | Expired
  | Superseded

type admission = int

type stale_start = Newer_start_admitted

type entry = {
  attempt_id : string;
  admission : admission;
  keeper : string;
  provider_id : string;
  state : string;
  in_flight : in_flight option;
  status : status;
}

type t = { mutex : Mutex.t; mutable entries : entry list; mutable admitted : admission }
let create () = { mutex = Mutex.create (); entries = []; admitted = 0 }
let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let expire ~now entry = match entry.status with
  | Awaiting_consent deadline when deadline <= now ->
      {entry with in_flight=None; status=Expired}
  | Awaiting_consent _ | Callback_admitted | Completed _ | Failed | Expired
  | Superseded -> entry

let terminal = function Completed _ | Failed | Expired | Superseded -> true
  | Awaiting_consent _ | Callback_admitted -> false

let admit t = with_lock t (fun () ->
  t.admitted <- t.admitted + 1;
  t.admitted)

let remember t admission ~now ~ttl_sec in_flight =
  let flow = in_flight.pending in
  let attempt_id = Random_id.hex ~bytes:16 in
  with_lock t (fun () ->
    let same_scope entry = entry.keeper=flow.Keeper_oauth_flow.keeper
      && entry.provider_id=flow.Keeper_oauth_flow.provider_id in
    let entries = List.map (expire ~now) t.entries in
    (* Starts are ordered by admission, not by which one's discovery and
       registration finished first. A later start that is already held
       stays the scope's attempt; this earlier one is refused rather than
       retiring the consent its operator was just shown. *)
    if List.exists (fun entry -> same_scope entry && entry.admission > admission) entries
    then Error Newer_start_admitted
    else begin
      (* A new operator attempt retires the previous consent for the same
         scope, but cannot cancel a callback already admitted to publication.
         Completed metadata lives until that scope starts another attempt. *)
      let entries = entries
        |> List.filter (fun entry -> not (same_scope entry && terminal entry.status))
        |> List.map (fun entry -> match entry.status with
          | Awaiting_consent _ when same_scope entry ->
              {entry with in_flight=None; status=Superseded}
          | Awaiting_consent _ | Callback_admitted | Completed _ | Failed
          | Expired | Superseded -> entry) in
      t.entries <- {attempt_id; admission; keeper=flow.Keeper_oauth_flow.keeper;
        provider_id=flow.Keeper_oauth_flow.provider_id; state=flow.Keeper_oauth_flow.state;
        in_flight=Some in_flight; status=Awaiting_consent (now +. ttl_sec)} :: entries;
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
        | Expired | Superseded), (Some _ | None) -> entry) t.entries;
    !found)

let status t ~now ~attempt_id ~keeper ~provider_id =
  with_lock t (fun () ->
    t.entries <- List.map (expire ~now) t.entries;
    List.find_opt (fun entry -> entry.attempt_id=attempt_id
      && entry.keeper=keeper && entry.provider_id=provider_id) t.entries
    |> Option.map (fun entry -> entry.status))

let finish t ~state outcome =
  with_lock t (fun () ->
    t.entries <- List.map (fun entry ->
      if entry.state=state && entry.status=Callback_admitted
      then {entry with status=(match outcome with Ok completion -> Completed completion | Error () -> Failed)}
      else entry) t.entries)

let waiting t ~now = with_lock t (fun () ->
  t.entries <- List.map (expire ~now) t.entries;
  List.fold_left (fun count entry -> match entry.status with
    | Awaiting_consent _ -> count+1
    | Callback_admitted | Completed _ | Failed | Expired | Superseded -> count)
    0 t.entries)
