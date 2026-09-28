type room_id = string
type peer = int

let max_guests_per_room = 16

type room_state = {
  guests : (peer, unit) Hashtbl.t;
  mutable next_peer : peer;
}

type t = { rooms : (room_id, room_state) Hashtbl.t }

let create () = { rooms = Hashtbl.create 16 }

let room_exists t ~room = Hashtbl.mem t.rooms room

type join_error =
  | Join_no_such_room
  | Host_already_connected
  | Room_full

type join_outcome =
  | Host_accepted
  | Guest_accepted of { peer : peer }

let new_room () = { guests = Hashtbl.create 8; next_peer = 1 }

let join t ~room ~role =
  match role with
  | Collab_wire.Host ->
    (match Hashtbl.find_opt t.rooms room with
     | Some _ -> Error Host_already_connected
     | None ->
       Hashtbl.replace t.rooms room (new_room ());
       Ok Host_accepted)
  | Collab_wire.Guest ->
    (match Hashtbl.find_opt t.rooms room with
     | None -> Error Join_no_such_room
     | Some rs ->
       if Hashtbl.length rs.guests >= max_guests_per_room
       then Error Room_full
       else (
         let peer = rs.next_peer in
         rs.next_peer <- peer + 1;
         Hashtbl.replace rs.guests peer ();
         Ok (Guest_accepted { peer })))
;;

type guest_departure =
  | Guest_departed
  | Leave_no_such_room
  | Leave_no_such_guest

let sorted_guests rs =
  Hashtbl.fold (fun peer () acc -> peer :: acc) rs.guests []
  |> List.sort Int.compare
;;

let host_left t ~room =
  match Hashtbl.find_opt t.rooms room with
  | None -> []
  | Some rs ->
    Hashtbl.remove t.rooms room;
    sorted_guests rs
;;

let guest_left t ~room ~peer =
  match Hashtbl.find_opt t.rooms room with
  | None -> Leave_no_such_room
  | Some rs ->
    if Hashtbl.mem rs.guests peer
    then (
      Hashtbl.remove rs.guests peer;
      Guest_departed)
    else Leave_no_such_guest
;;

type sender =
  | Host
  | Guest of peer

type drop_reason =
  | Malformed_envelope
  | Route_no_such_room
  | Route_guest_not_in_room of { peer : int }
  | Sender_id_out_of_range of { peer : int }

type delivery =
  | To_guests of { peers : peer list; envelope : string }
  | To_host of { envelope : string }
  | Drop of { reason : drop_reason }

let route t ~room ~sender ~envelope =
  match Collab_envelope.unpack envelope with
  | None -> Drop { reason = Malformed_envelope }
  | Some (target, payload) ->
    (match Hashtbl.find_opt t.rooms room with
     | None -> Drop { reason = Route_no_such_room }
     | Some rs ->
       (match sender with
        | Host ->
          if target = Collab_envelope.broadcast_peer
          then To_guests { peers = sorted_guests rs; envelope }
          else if Hashtbl.mem rs.guests target
          then To_guests { peers = [ target ]; envelope }
          else Drop { reason = Route_guest_not_in_room { peer = target } }
        | Guest sender_peer ->
          if not (Hashtbl.mem rs.guests sender_peer)
          then Drop { reason = Route_guest_not_in_room { peer = sender_peer } }
          else (
            match Collab_envelope.pack ~peer:sender_peer payload with
            | Ok rewritten -> To_host { envelope = rewritten }
            | Error (Collab_envelope.Peer_id_out_of_range _) ->
              Drop { reason = Sender_id_out_of_range { peer = sender_peer } })))
;;
