(** See [server_connection_socket.mli]. *)

let write_piece_bytes = 4 * 1024 * 1024
let write_bound_s = Server_mcp_transport_http_headers.sse_stalled_after_s
let preparation_bound_s = 30.0

type state =
  | Open
  | Cut

type t =
  { flow : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
  ; fd : Eio_unix.Fd.t
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; listener_tag : string
  ; client_addr : Eio.Net.Sockaddr.stream
  ; write_turn : Eio.Mutex.t
  ; mutable state : state
  ; mutable writing_since : float option
        (** When the piece in flight started, as the clock read then. *)
  ; mutable watched : bool  (** A fiber watches the piece in flight. *)
  ; mutable peer_close_awaited : bool
  }

let peer t = Format.asprintf "%a" Eio.Net.Sockaddr.pp t.client_addr

(* With [SO_LINGER] zero the close that follows resets the connection and
   drops what the peer did not take. macOS answers EINVAL when the peer has
   already reset or closed the connection (setsockopt(2): "The socket has
   been shut down"): nothing is kept for such a peer. *)
let reset_on_close t =
  Eio_unix.Fd.use_exn "setsockopt" t.fd (fun fd ->
    match Unix.setsockopt_optint fd Unix.SO_LINGER (Some 0) with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINVAL, _, _) -> ())
;;

(* Each direction is shut down by itself. A shutdown of both at once is one
   call, and macOS fails it as a whole with ENOTCONN once the peer has sent
   its FIN: the sending side stays open and its writer asleep (measured on
   macOS 27.2, TCP loopback and socket pair). Eio drops the ENOTCONN of a
   direction that is already closed.

   This runs in the fibers that watch the bounds. What they raise fails the
   connection's switch and, through the accept loop's fiber, the listener's. *)
let cut t =
  match t.state with
  | Cut -> ()
  | Open ->
    t.state <- Cut;
    reset_on_close t;
    Eio.Flow.shutdown t.flow `Send;
    Eio.Flow.shutdown t.flow `Receive
;;

(* One fiber watches a connection's writes while a piece is in flight, and a
   connection that writes nothing has none: a timer for every piece costs
   more than the piece's bookkeeping (measured: about 5 us of CPU a write,
   against 11 us for the write and its read). The fiber sleeps to the end of
   the bound of the piece it found. When it wakes that piece is still in
   flight and is cut, or a later one is and has the rest of its own bound, or
   none is and the fiber ends: the next piece starts another. *)
let rec watch t =
  match t.writing_since with
  | None -> t.watched <- false
  | Some since ->
    (* [since] is a reading of the wall clock. A clock set back since then
       reads as no time waited instead of a negative time, so the piece is
       cut one bound after this look at the latest. *)
    let waited = Float.max 0.0 (Eio.Time.now t.clock -. since) in
    if waited >= write_bound_s
    then (
      t.watched <- false;
      (match t.state with
       | Cut -> ()
       | Open ->
         Log.Http.warn
           "[%s] %s took no write for %.0fs: connection closed"
           t.listener_tag
           (peer t)
           write_bound_s);
      cut t)
    else (
      Eio.Time.sleep t.clock (write_bound_s -. waited);
      watch t)
;;

(* Called with the write turn held. *)
let write_piece t piece =
  match t.state with
  | Cut -> raise End_of_file
  | Open ->
    t.writing_since <- Some (Eio.Time.now t.clock);
    if not t.watched
    then (
      t.watched <- true;
      Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        watch t;
        `Stop_daemon));
    (match
       Fun.protect
         ~finally:(fun () -> t.writing_since <- None)
         (fun () -> Eio.Flow.write t.flow piece)
     with
     | () -> ()
     | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> raise End_of_file)
;;

(* The longest run of bytes at the head of [bufs] that fits in [room]. *)
let rec head_within ~room = function
  | [] -> []
  | buf :: rest ->
    let length = Cstruct.length buf in
    if length >= room
    then [ Cstruct.sub buf 0 room ]
    else buf :: head_within ~room:(room - length) rest
;;

let await_peer_close t =
  if not t.peer_close_awaited
  then (
    t.peer_close_awaited <- true;
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      Eio.Time.sleep t.clock write_bound_s;
      (match t.state with
       | Cut -> ()
       | Open ->
         Log.Http.info
           "[%s] %s kept the connection open %.0fs after the server closed its side: \
            connection closed"
           t.listener_tag
           (peer t)
           write_bound_s;
         cut t);
      `Stop_daemon))
;;

module Socket = struct
  type tag = [ `Generic ]
  type nonrec t = t

  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t.flow dst

  (* Called with the write turn held. *)
  let rec write_pieces t = function
    | [] -> ()
    | bufs ->
      let piece = head_within ~room:write_piece_bytes bufs in
      write_piece t piece;
      write_pieces t (Cstruct.shiftv bufs (Cstruct.lenv piece))
  ;;

  (* All of [bufs] goes out in one turn. [Eio.Flow.write] asks again for what
     a call left unwritten, and a turn given up between two pieces would let
     another writer's bytes land inside this one's. *)
  let single_write t bufs =
    Eio.Mutex.use_ro t.write_turn (fun () -> write_pieces t bufs);
    Cstruct.lenv bufs
  ;;

  (* The turn is kept for the whole source, as for a write. Nothing in the
     server copies into this socket: the pinned tls-eio writes its ciphertext
     (scripts/opam-pin-external-deps.sh, RFC-0518 D8). *)
  let copy t ~src =
    Eio.Mutex.use_ro t.write_turn (fun () ->
      Eio.Flow.Pi.simple_copy t ~src ~single_write:(fun t bufs ->
        write_pieces t bufs;
        Cstruct.lenv bufs))
  ;;

  let shutdown t command =
    match t.state with
    | Cut -> ()
    | Open ->
      (match command with
       | `Send -> await_peer_close t
       | `Receive | `All -> ());
      Eio.Flow.shutdown t.flow command
  ;;

  let close t = Eio.Flow.close t.flow
end

let handler = Eio.Net.Pi.stream_socket (module Socket)
let socket t = Eio.Resource.T (t, handler)

let wrap ~sw ~clock ~listener_tag client_addr flow =
  { flow = (flow :> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t)
  ; fd = Eio_unix.Net.fd flow
  ; sw
  ; clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
  ; listener_tag
  ; client_addr
  ; write_turn = Eio.Mutex.create ()
  ; state = Open
  ; writing_since = None
  ; watched = false
  ; peer_close_awaited = false
  }
;;

let prepare t step =
  match
    Eio.Fiber.first
      (fun () -> Some (step ()))
      (fun () ->
        Eio.Time.sleep t.clock preparation_bound_s;
        None)
  with
  | Some _ as prepared -> prepared
  | None ->
    cut t;
    None
;;

let await_first_bytes t = Eio_unix.Fd.use_exn "await_readable" t.fd Eio_unix.await_readable
let send_side_closed = await_peer_close
