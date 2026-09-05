type placement = {
  columns : int;
  rows : int;
}

type query_reply =
  | Supported
  | Refused of string

(* APC introducer and terminator. Everything the protocol says travels
   between them. *)
let apc = "\x1b_G"
let st = "\x1b\\"

(* Chosen high so it cannot collide with an image this process places, and
   fixed so a reply arriving late -- after the deadline, into the key stream --
   is still recognisable as an answer rather than typed as text. *)
let query_id = 31

(* f=100 says the payload is a PNG file's bytes. The query sends the smallest
   PNG that exists rather than a made-up one: a terminal that decodes it
   proves it can decode the real thing, and one that only pattern-matches the
   escape answers either way. a=q asks the terminal to answer without
   drawing. *)
let one_pixel_png =
  "\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001\b\006\
   \000\000\000\031\021\196\137\000\000\000\nIDATx\156c\000\001\000\000\005\
   \000\001\r\n-\180\000\000\000\000IEND\174B`\130"

let query =
  Printf.sprintf "%si=%d,a=q,f=100;%s%s" apc query_id
    (Base64.encode_string one_pixel_png)
    st

let parse_query_reply body =
  (* A reply is "<key=value,…>;<status>". The keys before the semicolon say
     which image is being answered about. *)
  match String.index_opt body ';' with
  | None -> None
  | Some cut ->
      let keys = String.sub body 0 cut in
      let status = String.sub body (cut + 1) (String.length body - cut - 1) in
      let answers_the_query =
        String.split_on_char ',' keys
        |> List.exists (fun pair ->
               String.equal pair (Printf.sprintf "i=%d" query_id))
      in
      if not answers_the_query then None
      else if String.equal status "OK" then Some Supported
      else Some (Refused status)

(* q=2 asks the terminal not to answer. A placement's reply would arrive on
   stdin, and stdin here is the key stream: an unread APC reply is typed into
   whatever the operator was writing. The query below is the one request that
   does want an answer, and it is the one the reader knows how to consume.

   The protocol asks that a payload be split across escapes, and terminals do
   drop an escape past a length of their own choosing. 4096 is what the
   protocol's own documentation uses, so it is the size terminals are known to
   accept. *)
let chunk_bytes = 4096

(* What [place] encodes its payload as. It says f=100 -- a PNG file's bytes --
   and q=2, which tells the terminal not to answer, so bytes of any other
   format are encoded, sent, dropped by the decoder, and nothing on the wire
   says so: the screen clears, no picture arrives, and the only text on it is
   how to leave.

   Named rather than left inside the escape so a caller holding bytes can ask
   whatever already knows how to identify them whether they are this, before
   placing. This module does not identify bytes itself -- it speaks a terminal
   protocol, and a sniffer here would be a second answer to a question the
   composer's already answers. *)
let payload_media_type = "image/png"

let place ~data { columns; rows } =
  let encoded = Base64.encode_string data in
  let length = String.length encoded in
  let out = Buffer.create (length + (length / chunk_bytes * 32) + 64) in
  let rec emit offset =
    let remaining = length - offset in
    let size = min chunk_bytes remaining in
    let more = if remaining > size then 1 else 0 in
    (* Only the first escape carries the image's keys; the rest carry m=
       alone. The final chunk's m=0 is what tells the terminal the image is
       complete and may be drawn. *)
    if offset = 0 then
      Buffer.add_string out
        (Printf.sprintf "%sf=100,a=T,c=%d,r=%d,q=2,m=%d;%s%s" apc
           (max 1 columns) (max 1 rows) more
           (String.sub encoded offset size)
           st)
    else
      Buffer.add_string out
        (Printf.sprintf "%sm=%d;%s%s" apc more (String.sub encoded offset size)
           st);
    if more = 1 then emit (offset + size)
  in
  if length = 0 then "" (* nothing to place, and no escape to say so *)
  else begin
    emit 0;
    Buffer.contents out
  end

let delete_all = Printf.sprintf "%sa=d%s" apc st

type graphics_protocol =
  | Kitty_protocol
  | ITerm2_protocol
  | Unsupported_protocol

let iterm2_place ~data { columns; rows } =
  let encoded = Base64.encode_string data in
  if String.length encoded = 0 then ""
  else
    Printf.sprintf "\x1b]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\x07"
      (max 1 columns) (max 1 rows) encoded

(* tmux forwards a wrapped escape to the terminal underneath, and requires
   every ESC inside the payload to be doubled so its own parser does not stop
   at the first one. *)
let tmux_wrapped payload =
  let escaped =
    String.concat "\x1b\x1b" (String.split_on_char '\x1b' payload)
  in
  "\x1bPtmux;" ^ escaped ^ "\x1b\\"
