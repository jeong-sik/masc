(** See [tls_stream_socket.mli]. *)

module Socket = struct
  type tag = [ `Generic ]

  type t =
    { tls : Tls_eio.t
    ; on_send_shutdown : unit -> unit
    }

  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t.tls dst
  let single_write t bufs = Eio.Flow.single_write t.tls bufs
  let copy t ~src = Eio.Flow.copy src t.tls

  let shutdown t command =
    (match command with
     | `Send | `All -> t.on_send_shutdown ()
     | `Receive -> ());
    Eio.Flow.shutdown t.tls command
  ;;

  let close t = Eio.Flow.close t.tls
end

let handler = Eio.Net.Pi.stream_socket (module Socket)
let wrap ~on_send_shutdown tls = Eio.Resource.T ({ Socket.tls; on_send_shutdown }, handler)
