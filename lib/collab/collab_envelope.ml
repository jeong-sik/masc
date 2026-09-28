let header_length = 4
let broadcast_peer = 0
let max_peer = 0xFFFFFFFF

type pack_error = Peer_id_out_of_range of int

let pack ~peer payload =
  if peer < 0 || peer > max_peer
  then Error (Peer_id_out_of_range peer)
  else (
    let header = Bytes.create header_length in
    Bytes.set_int32_be header 0 (Int32.of_int peer);
    Ok (Bytes.unsafe_to_string header ^ payload))
;;

let unpack bytes =
  let len = String.length bytes in
  if len < header_length
  then None
  else (
    (* The header is an unsigned 32-bit id; Int32.to_int alone would sign it. *)
    let raw = Int32.to_int (String.get_int32_be bytes 0) in
    let peer = if raw < 0 then raw + 0x100000000 else raw in
    let payload = String.sub bytes header_length (len - header_length) in
    Some (peer, payload))
;;
