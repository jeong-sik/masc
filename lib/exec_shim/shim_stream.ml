type peer_state =
  | Connected
  | Send_closed
  | Disconnected

external peer_state : Unix.file_descr -> peer_state = "ocaml_shim_stream_peer_state"
external set_nonblock_flags : Unix.file_descr -> int = "ocaml_shim_set_nonblock"
external restore_flags : Unix.file_descr -> int -> unit = "ocaml_shim_restore_flags"

let with_nonblocking fd f =
  let flags = set_nonblock_flags fd in
  Fun.protect ~finally:(fun () ->
    try restore_flags fd flags with Unix.Unix_error _ -> ()) f

let lifecycle_poll_sec = 0.2
let drain_grace_sec = 1.0
