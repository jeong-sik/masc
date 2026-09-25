(** See [server_h2_frame_tap.mli]. *)

(* RFC 9113 §3.4 client connection preface and §4.1 frame layout. *)
let client_preface_length = String.length "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
let frame_header_length = 9
let end_stream_flag = 0x1

type frame_kind =
  | Data
  | Headers
  | Rst_stream
  | Continuation
  | Other_frame

let frame_kind_of_code = function
  | 0x0 -> Data
  | 0x1 -> Headers
  | 0x3 -> Rst_stream
  | 0x9 -> Continuation
  | _ -> Other_frame

type frame =
  { kind : frame_kind
  ; flags : int
  ; stream_id : int
  ; payload_length : int
  }

let decode_frame_header header =
  { payload_length =
      (Cstruct.get_uint8 header 0 lsl 16)
      lor (Cstruct.get_uint8 header 1 lsl 8)
      lor Cstruct.get_uint8 header 2
  ; kind = frame_kind_of_code (Cstruct.get_uint8 header 3)
  ; flags = Cstruct.get_uint8 header 4
  ; stream_id = Int32.to_int (Int32.logand (Cstruct.BE.get_uint32 header 5) 0x7fff_ffffl)
  }
;;

(* Where the next byte of one direction falls inside the frame sequence. *)
type cursor =
  | Preface of { remaining : int }
  | Header of { filled : int }
  | Payload of
      { frame : frame
      ; remaining : int
      }

type direction =
  { mutable cursor : cursor
  ; mutable last_complete : frame option
  ; header : Cstruct.t
  ; on_frame_complete : frame -> unit
  }

let direction ~cursor ~on_frame_complete =
  { cursor
  ; last_complete = None
  ; header = Cstruct.create frame_header_length
  ; on_frame_complete
  }
;;

(* Bytes until the current preface, header or payload ends. *)
let bytes_until_boundary direction =
  match direction.cursor with
  | Preface { remaining } -> remaining
  | Header { filled } -> frame_header_length - filled
  | Payload { remaining; _ } -> remaining
;;

let complete direction frame =
  direction.cursor <- Header { filled = 0 };
  direction.last_complete <- Some frame;
  direction.on_frame_complete frame
;;

(* [bytes] never crosses the boundary reported by [bytes_until_boundary]. *)
let advance_within_boundary direction bytes =
  let length = Cstruct.length bytes in
  match direction.cursor with
  | Preface { remaining } ->
    direction.cursor <-
      (if remaining = length
       then Header { filled = 0 }
       else Preface { remaining = remaining - length })
  | Header { filled } ->
    Cstruct.blit bytes 0 direction.header filled length;
    let filled = filled + length in
    if filled < frame_header_length
    then direction.cursor <- Header { filled }
    else (
      let frame = decode_frame_header direction.header in
      if frame.payload_length = 0
      then complete direction frame
      else direction.cursor <- Payload { frame; remaining = frame.payload_length })
  | Payload { frame; remaining } ->
    if remaining = length
    then complete direction frame
    else direction.cursor <- Payload { frame; remaining = remaining - length }
;;

let rec advance direction bytes =
  if Cstruct.length bytes > 0
  then (
    let step = min (Cstruct.length bytes) (bytes_until_boundary direction) in
    advance_within_boundary direction (Cstruct.sub bytes 0 step);
    advance direction (Cstruct.shift bytes step))
;;

module Socket = struct
  type tag = [ `Generic ]

  type t =
    { flow : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
    ; read_buffer : Cstruct.t
    ; mutable buffered : Cstruct.t
    ; inbound : direction
    ; outbound : direction
    }

  let read_methods = []

  (* Serve at most one preface, frame header or frame payload per read. h2
     parses each read synchronously, so a request callback always runs while
     the inbound [last_complete] names the frame that completed its header
     block. *)
  let single_read t dst =
    if Cstruct.length t.buffered = 0
    then (
      let n = Eio.Flow.single_read t.flow t.read_buffer in
      t.buffered <- Cstruct.sub t.read_buffer 0 n);
    let n =
      min
        (Cstruct.length dst)
        (min (Cstruct.length t.buffered) (bytes_until_boundary t.inbound))
    in
    Cstruct.blit t.buffered 0 dst 0 n;
    let served = Cstruct.sub t.buffered 0 n in
    t.buffered <- Cstruct.shift t.buffered n;
    advance_within_boundary t.inbound served;
    n
  ;;

  let single_write t bufs =
    let written = Eio.Flow.single_write t.flow bufs in
    let rec observe remaining = function
      | [] -> ()
      | buf :: rest ->
        let step = min remaining (Cstruct.length buf) in
        advance t.outbound (Cstruct.sub buf 0 step);
        if remaining > step then observe (remaining - step) rest
    in
    observe written bufs;
    written
  ;;

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t command =
    (match command with
     | `Receive | `All -> t.buffered <- Cstruct.empty
     | `Send -> ());
    Eio.Flow.shutdown t.flow command
  ;;

  let close t =
    t.buffered <- Cstruct.empty;
    Eio.Flow.close t.flow
  ;;
end

let socket_handler = Eio.Net.Pi.stream_socket (module Socket)

type t =
  { state : Socket.t
  ; socket : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
  }

let wrap ~on_peer_reset ~on_response_end (flow : _ Eio.Net.stream_socket) =
  let state =
    { Socket.flow = (flow :> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t)
    ; read_buffer = Cstruct.create H2.Config.default.read_buffer_size
    ; buffered = Cstruct.empty
    ; inbound =
        direction
          ~cursor:(Preface { remaining = client_preface_length })
          ~on_frame_complete:(fun frame ->
            match frame.kind with
            | Rst_stream -> on_peer_reset frame.stream_id
            | Data | Headers | Continuation | Other_frame -> ())
    ; outbound =
        direction
          ~cursor:(Header { filled = 0 })
          ~on_frame_complete:(fun frame ->
            match frame.kind with
            | Rst_stream -> on_response_end frame.stream_id
            | (Data | Headers) when frame.flags land end_stream_flag <> 0 ->
              on_response_end frame.stream_id
            | Data | Headers | Continuation | Other_frame -> ())
    }
  in
  { state; socket = Eio.Resource.T (state, socket_handler) }
;;

let socket t = t.socket

let request_stream t =
  match t.state.inbound.last_complete with
  | Some { kind = Headers | Continuation; stream_id; _ } -> Some stream_id
  | Some { kind = Data | Rst_stream | Other_frame; _ } | None -> None
;;
