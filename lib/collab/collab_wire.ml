let proto_version = 1
let room_id_bytes = 16

type role =
  | Host
  | Guest

let role_of_string = function
  | "host" -> Some Host
  | "guest" -> Some Guest
  | _ -> None
;;

let string_of_role = function
  | Host -> "host"
  | Guest -> "guest"
;;

type control =
  | Peer_joined of { peer : int }
  | Peer_left of { peer : int }
  | Room_closed

let control_json = function
  | Peer_joined { peer } ->
    Yojson.Safe.to_string
      (`Assoc [ "t", `String "peer-joined"; "peer", `Int peer ])
  | Peer_left { peer } ->
    Yojson.Safe.to_string
      (`Assoc [ "t", `String "peer-left"; "peer", `Int peer ])
  | Room_closed -> Yojson.Safe.to_string (`Assoc [ "t", `String "room-closed" ])
;;

let peer_field fields =
  match List.assoc_opt "peer" fields with
  | Some (`Int n) when n >= 1 && n <= Collab_envelope.max_peer -> Some n
  | Some _ | None -> None
;;

let control_of_string s =
  match Yojson.Safe.from_string s with
  | `Assoc fields ->
    (match List.assoc_opt "t" fields with
     | Some (`String "peer-joined") ->
       (match peer_field fields with
        | Some peer -> Some (Peer_joined { peer })
        | None -> None)
     | Some (`String "peer-left") ->
       (match peer_field fields with
        | Some peer -> Some (Peer_left { peer })
        | None -> None)
     | Some (`String "room-closed") -> Some Room_closed
     | Some _ | None -> None)
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _ -> None
  | exception Yojson.Json_error _ -> None
;;

type close_reason =
  | Close_room_closed
  | Close_no_such_room
  | Close_host_conflict
  | Close_room_full

let close_code = function
  | Close_room_closed -> 4001
  | Close_no_such_room -> 4004
  | Close_host_conflict -> 4009
  | Close_room_full -> 4029
;;

let close_message = function
  | Close_room_closed -> "room closed"
  | Close_no_such_room -> "no such room"
  | Close_host_conflict -> "a host is already connected for this room"
  | Close_room_full -> "room is full"
;;

type request_error =
  | Bad_path
  | Bad_room_id
  | Missing_role
  | Bad_role
  | Duplicate_role

let room_prefix = "/r/"
let room_prefix_len = String.length room_prefix

let query_roles query =
  match query with
  | None -> []
  | Some q ->
    List.filter_map
      (fun part ->
        match String.index_opt part '=' with
        | None -> None
        | Some i ->
          let key = String.sub part 0 i in
          if String.equal key "role"
          then (
            let start = i + 1 in
            Some (String.sub part start (String.length part - start)))
          else None)
      (String.split_on_char '&' q)
;;

let parse_request_target ~target =
  let path, query =
    match String.index_opt target '?' with
    | None -> target, None
    | Some i ->
      let path = String.sub target 0 i in
      let start = i + 1 in
      let query = String.sub target start (String.length target - start) in
      path, Some query
  in
  if not (String.starts_with ~prefix:room_prefix path)
  then Error Bad_path
  else (
    let suffix =
      String.sub path room_prefix_len (String.length path - room_prefix_len)
    in
    if String.equal suffix "" || String.contains suffix '/'
    then Error Bad_path
    else (
      match
        Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet suffix
      with
      | Error (`Msg _) -> Error Bad_room_id
      | Ok room when String.length room <> room_id_bytes -> Error Bad_room_id
      | Ok room ->
        (match query_roles query with
         | [] -> Error Missing_role
         | [ value ] ->
           (match role_of_string value with
            | Some role -> Ok (room, role)
            | None -> Error Bad_role)
         | _ :: _ :: _ -> Error Duplicate_role)))
;;
