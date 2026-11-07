(** See [tls_stream_socket.mli]. *)

module Socket = struct
  type tag = [ `Generic ]
  type t = Tls_eio.t

  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t dst
  let single_write t bufs = Eio.Flow.single_write t bufs
  let copy t ~src = Eio.Flow.copy src t
  let shutdown t command = Eio.Flow.shutdown t command
  let close t = Eio.Flow.close t
end

let handler = Eio.Net.Pi.stream_socket (module Socket)
let wrap tls = Eio.Resource.T (tls, handler)
