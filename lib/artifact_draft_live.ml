module Draft = Artifact_draft
module Engine = Artifact_document_engine
module Rooms = Map.Make (struct type t = string * string * string let compare = Stdlib.compare end)
module Peers = Map.Make (String)
type source = Dashboard_connection | Keeper_turn of Ids.Turn_ref.t
type session = { source : source; id : string; base_path : string; actor : string; target : Draft.target }
type peer =
  { session : session; position : Engine.selection option; observed_at : string
  ; announced_sequence : int option }
type room =
  { mutable document : (Draft.t * string) option; mutable peers : peer Peers.t
  ; mutable pulse : unit Eio.Promise.t; mutable wake : unit Eio.Promise.u }
type error = Missing_session | Owner_mismatch
let mutex = Mutex.create ()
let rooms = ref Rooms.empty
let key session = session.base_path, session.target.artifact_id, session.target.generation
let id session = session.id
let notify room =
  let previous = room.wake in
  let pulse, wake = Eio.Promise.create () in room.pulse <- pulse; room.wake <- wake;
  Eio.Promise.resolve previous ()
let join ~base_path ~actor ~source ~target = Mutex.protect mutex (fun () ->
  let session = { id = Random_id.uuid_v7 (); source; base_path; actor; target } in
  let room = match Rooms.find_opt (key session) !rooms with
    | Some room -> room
    | None -> let pulse, wake = Eio.Promise.create () in
      let room = { document = None; peers = Peers.empty; pulse; wake } in
      rooms := Rooms.add (key session) room !rooms; room in
  room.peers <- Peers.add session.id
    { session; position = None; observed_at = Types_core.now_iso (); announced_sequence = None } room.peers;
  notify room; session)
let leave session = Mutex.protect mutex (fun () ->
  match Rooms.find_opt (key session) !rooms with
  | None -> ()
  | Some room when not (Peers.mem session.id room.peers) -> ()
  | Some room ->
    room.peers <- Peers.remove session.id room.peers;
    if Peers.is_empty room.peers then rooms := Rooms.remove (key session) !rooms;
    notify room)
let find ~base_path ~actor ~target ~session_id = Mutex.protect mutex (fun () ->
  match Rooms.find_opt (base_path, target.Draft.artifact_id, target.generation) !rooms with
  | None -> Error Missing_session
  | Some room -> match Peers.find_opt session_id room.peers with
    | None -> Error Missing_session
    | Some peer when peer.session.source <> Dashboard_connection || not (String.equal peer.session.actor actor) -> Error Owner_mismatch
    | Some peer -> Ok peer.session)
let position session position = Mutex.protect mutex (fun () ->
  match Rooms.find_opt (key session) !rooms with
  | None -> Error Missing_session
  | Some room -> match Peers.find_opt session.id room.peers with
    | None -> Error Missing_session
    | Some peer when peer.position = position -> Ok ()
    | Some peer ->
      room.peers <- Peers.add session.id { peer with position; observed_at = Types_core.now_iso () } room.peers;
      notify room; Ok ())
let publish ~base_path ~draft ~content = Mutex.protect mutex (fun () ->
  match Rooms.find_opt (base_path, draft.Draft.target.artifact_id, draft.target.generation) !rooms with
  | None -> ()
  | Some room ->
    match room.document with
    | Some (previous, _) when previous.sequence >= draft.sequence -> ()
    | None | Some _ -> room.document <- Some (draft, content); notify room)
let observe session = Mutex.protect mutex (fun () ->
  match Rooms.find_opt (key session) !rooms with
  | None -> None
  | Some room ->
    match Peers.find_opt session.id room.peers with
    | None -> None
    | Some peer ->
    let document = match room.document with
      | None -> `Null
      | Some (draft, _) when Option.fold ~none:false
          ~some:(fun sequence -> sequence >= draft.sequence) peer.announced_sequence -> `Null
      | Some (draft, content) ->
        room.peers <- Peers.add session.id
          { peer with announced_sequence = Some draft.sequence } room.peers;
        Draft.document_to_json ~draft ~content ~selection:None in
    let peers = Peers.bindings room.peers |> List.map (fun (_, peer) -> `Assoc
      ["session_id", `String peer.session.id; "actor", `String peer.session.actor;
       "source", (match peer.session.source with
         | Dashboard_connection -> `Assoc ["kind", `String "dashboard_connection"]
         | Keeper_turn turn_ref -> `Assoc ["kind", `String "keeper_turn"; "turn_ref", Ids.Turn_ref.to_yojson turn_ref]);
       "position", Option.fold ~none:`Null ~some:Engine.selection_to_json peer.position;
       "observed_at", `String peer.observed_at]) in
    Some (`Assoc ["schema", `String "masc.artifact_draft_live.v1"; "session_id", `String session.id;
      "target", Draft.target_to_json session.target; "peers", `List peers;
      "document", document], room.pulse))
