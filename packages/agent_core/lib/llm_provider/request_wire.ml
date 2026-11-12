type t =
  { eof_seen : bool ref
  ; mutable write_began : bool
  ; mutable write_failure : exn option
  ; mutable response_bytes : int
  }

let create () =
  { eof_seen = ref false; write_began = false; write_failure = None; response_bytes = 0 }
;;

let eof_seen t = t.eof_seen
let write_began t = t.write_began <- true

let write_raised t exn =
  match t.write_failure with
  | None -> t.write_failure <- Some exn
  | Some _ -> ()
;;

let bytes_read t count = if t.write_began then t.response_bytes <- t.response_bytes + count

type delivery =
  | Not_delivered
  | Possibly_delivered

let delivery ~names_peer_close t =
  match t.write_failure with
  | Some exn when t.response_bytes = 0 && names_peer_close exn -> Not_delivered
  | Some _ | None -> Possibly_delivered
;;
