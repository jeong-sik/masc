(** SSE room-based event filtering *)

(* session_id -> room_id *)
let session_rooms : (string, string) Hashtbl.t = Hashtbl.create 32

(* room_id -> session_id set (for fast room lookups) *)
let room_sessions : (string, (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8

let register ~session_id ~room_id =
  (* Remove from previous room if any *)
  (match Hashtbl.find_opt session_rooms session_id with
   | Some old_room ->
     (match Hashtbl.find_opt room_sessions old_room with
      | Some set -> Hashtbl.remove set session_id
      | None -> ())
   | None -> ());
  (* Add to new room *)
  Hashtbl.replace session_rooms session_id room_id;
  let set = match Hashtbl.find_opt room_sessions room_id with
    | Some s -> s
    | None ->
      let s = Hashtbl.create 8 in
      Hashtbl.replace room_sessions room_id s;
      s
  in
  Hashtbl.replace set session_id ()

let unregister ~session_id =
  (match Hashtbl.find_opt session_rooms session_id with
   | Some room ->
     (match Hashtbl.find_opt room_sessions room with
      | Some set -> Hashtbl.remove set session_id
      | None -> ())
   | None -> ());
  Hashtbl.remove session_rooms session_id

let room_of ~session_id =
  Hashtbl.find_opt session_rooms session_id

let sessions_in_room ~room_id =
  match Hashtbl.find_opt room_sessions room_id with
  | Some set -> Hashtbl.fold (fun sid () acc -> sid :: acc) set []
  | None -> []

let should_receive ~session_id ~event_room_id =
  match event_room_id with
  | None -> true  (* Global event — everyone receives *)
  | Some target_room ->
    match Hashtbl.find_opt session_rooms session_id with
    | None -> false  (* Unregistered session receives nothing *)
    | Some session_room -> String.equal session_room target_room

let broadcast_to_room ~room_id ~send_fn payload =
  let targets = sessions_in_room ~room_id in
  List.iter (fun sid -> send_fn sid payload) targets

let clear () =
  Hashtbl.clear session_rooms;
  Hashtbl.clear room_sessions

let registered_count () =
  Hashtbl.length session_rooms
