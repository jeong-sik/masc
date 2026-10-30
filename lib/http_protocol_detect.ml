(** See [http_protocol_detect.mli]. *)

type protocol =
  | Http1
  | Http2

(* This prefix distinguishes H2 from valid HTTP/1 request lines. *)
let h2_preface_prefix = "PRI * HTTP/2.0"
let h2_preface_len = String.length h2_preface_prefix

module Replay = struct
  type tag = [`Generic]
  type t =
    { flow : [`Generic] Eio.Net.stream_socket_ty Eio.Resource.t
    ; mutable prefix : Cstruct.t
    }

  let read_methods = []

  let single_read t dst =
    if Cstruct.length t.prefix = 0 then Eio.Flow.single_read t.flow dst
    else (
      let n = min (Cstruct.length t.prefix) (Cstruct.length dst) in
      Cstruct.blit t.prefix 0 dst 0 n;
      t.prefix <- Cstruct.shift t.prefix n;
      n)

  let single_write t bufs = Eio.Flow.single_write t.flow bufs
  let copy t ~src = Eio.Flow.copy src t.flow

  let shutdown t command =
    (match command with
     | `Receive | `All -> t.prefix <- Cstruct.empty
     | `Send -> ());
    Eio.Flow.shutdown t.flow command

  let close t =
    t.prefix <- Cstruct.empty;
    Eio.Flow.close t.flow
end

let replay_handler = Eio.Net.Pi.stream_socket (module Replay)

let detect flow =
  let buffer = Cstruct.create h2_preface_len in
  let rec read matched =
    (* Consume only the prefix still needed. An Eio read suspends on delayed
       input; consuming partial bytes avoids re-peeking a readable prefix in
       a busy loop. The returned socket restores all consumed bytes. *)
    let n = Eio.Flow.single_read flow (Cstruct.shift buffer matched) in
    let available = matched + n in
    let rec compare i =
      if i = available then
        if available = h2_preface_len then Http2, available else read available
      else if Cstruct.get_char buffer i <> h2_preface_prefix.[i] then
        Http1, available
      else compare (i + 1)
    in
    compare matched
  in
  match read 0 with
  | protocol, length ->
    let state = Replay.{ flow = (flow :> [`Generic] Eio.Net.stream_socket_ty Eio.Resource.t)
                       ; prefix = Cstruct.sub buffer 0 length } in
    Ok (protocol, Eio.Resource.T (state, replay_handler))
  | exception End_of_file -> Error "connection closed before protocol detection"

let protocol_to_string = function
  | Http1 -> "HTTP/1.1"
  | Http2 -> "HTTP/2"
