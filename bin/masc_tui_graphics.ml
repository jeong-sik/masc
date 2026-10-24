type placement = {
  columns : int;
  rows : int;
}

let fit_rows ~cell_pixels ~image_pixels ~columns ~rows =
  match cell_pixels, image_pixels with
  | Some (cw, ch), Some (iw, ih) when cw > 0 && ch > 0 && iw > 0 && ih > 0 ->
      let allowed = float_of_int (max 1 columns) *. float_of_int cw
        *. float_of_int ih /. float_of_int iw /. float_of_int ch in
      max 1 (int_of_float (min (float_of_int (max 1 rows)) allowed))
  | _ -> max 1 rows

type query_reply =
  | Supported
  | Refused of string

(* APC introducer and terminator. Everything the protocol says travels
   between them. *)
let apc = "\x1b_G"
let st = "\x1b\\"

type image =
  | Graphics_query
  | Msx_screen
  | Mascot
  | Keeper_portrait
  | About_keeper_1 | About_keeper_2 | About_keeper_3 | About_keeper_4
  | Evidence_image_1 | Evidence_image_2 | Evidence_image_3 | Evidence_image_4
  | Image_inspection
[@@deriving enumerate]

(* Fixed, so a query reply arriving late -- after the deadline, into the key
   stream -- is still recognisable as an answer rather than typed as text. *)
let image_id = function
  | Graphics_query -> 31
  | Msx_screen -> 32
  | Mascot -> 41
  | Keeper_portrait -> 42
  | About_keeper_1 -> 43
  | About_keeper_2 -> 44
  | About_keeper_3 -> 45
  | About_keeper_4 -> 46
  | Evidence_image_1 -> 51
  | Evidence_image_2 -> 52
  | Evidence_image_3 -> 53
  | Evidence_image_4 -> 54
  | Image_inspection -> 55

let evidence_images =
  [ Evidence_image_1; Evidence_image_2; Evidence_image_3; Evidence_image_4 ]

let resource_image_id index = 0x10000 + index

let query_id = image_id Graphics_query

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

(* Raw pixels, for a caller that holds a frame rather than a file. A raw
   format has no container, so the escape has to state the pixel dimensions
   the PNG header would otherwise carry -- [s=] and [v=] -- and the terminal
   scales that into the cell box like any other image.

   Kept beside [place] rather than folded into it: the two need different
   keys, and a single function taking any format would let a caller send RGB
   bytes under [f=100], which is exactly the silent drop the comment above
   warns about. A caller holding a frame reaches for this one because it is
   the one that asks for the frame's dimensions. *)
let encode_rgb ~identity ~data ~pixel_width ~pixel_height ~rows =
  let encoded = Base64.encode_string data in
  let length = String.length encoded in
  let out = Buffer.create (length + (length / chunk_bytes * 32) + 64) in
  let rec emit offset =
    let remaining = length - offset in
    let size = min chunk_bytes remaining in
    let more = if remaining > size then 1 else 0 in
    if offset = 0
    then
      Buffer.add_string out
        (Printf.sprintf "%sf=24,s=%d,v=%d,a=T%s,r=%d,q=2,m=%d;%s%s" apc
           (max 1 pixel_width) (max 1 pixel_height) identity
           (max 1 rows) more
           (String.sub encoded offset size)
           st)
    else
      Buffer.add_string out
        (Printf.sprintf "%sm=%d;%s%s" apc more (String.sub encoded offset size) st);
    if more = 1 then emit (offset + size)
  in
  (* A frame whose bytes do not match its stated dimensions would be drawn as
     whatever the terminal makes of the mismatch, so refuse instead. *)
  if String.length data = 0
     || String.length data <> pixel_width * pixel_height * 3
  then ""
  else begin
    emit 0;
    Buffer.contents out
  end
;;

let place_rgb = encode_rgb ~identity:""

let identity ~image_id ~placement_id =
  Printf.sprintf ",i=%d,p=%d,C=1" image_id placement_id

let replace_rgb ~image_id ~placement_id =
  encode_rgb ~identity:(identity ~image_id ~placement_id)

(* No payload and no format key: a=p names pixels the terminal already
   holds, so there is nothing to decode. *)
let put ~image_id ~placement_id ~rows =
  Printf.sprintf "%sa=p%s,r=%d,q=2%s" apc (identity ~image_id ~placement_id) (max 1 rows) st

type crop = { top_px : int; height_px : int }

(* The cells a picture covers and the part of it that shows. Both c and r are
   sent: with one of them the terminal derives the other from the whole
   image's shape, and a cropped picture is not that shape. y and h are source
   pixels; w stays unset, which is the full width. *)
let extent ~rows ~cols ~crop =
  Printf.sprintf ",r=%d,c=%d%s" (max 1 rows) (max 1 cols)
    (match crop with
     | None -> ""
     | Some { top_px; height_px } ->
         Printf.sprintf ",y=%d,h=%d" (max 0 top_px) (max 1 height_px))

let put_png ~image_id ~placement_id ~rows ~cols ~crop =
  Printf.sprintf "%sa=p%s%s,q=2%s" apc (identity ~image_id ~placement_id)
    (extent ~rows ~cols ~crop) st

let delete_placement ~image_id ~placement_id =
  Printf.sprintf "%sa=d,d=i,i=%d,p=%d,q=2%s" apc image_id placement_id st

let delete_image ~image_id =
  Printf.sprintf "%sa=d,d=I,i=%d,q=2%s" apc image_id st

let place_png ~identity ~extent ~data =
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
        (Printf.sprintf "%sf=100,a=T%s%s,q=2,m=%d;%s%s" apc identity extent
           more
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

let place ~data ~rows = place_png ~identity:"" ~extent:(Printf.sprintf ",r=%d" (max 1 rows)) ~data

(* Ghostty 1.3.1 crashes in its Kitty o=z inflater for portrait-sized data
   (compress.flate.Decompress.streamInner -> Io.Writer.unreachableRebase).
   PNG keeps alpha and compact transfers while using the terminal's PNG
   decoder, the same path the capability query already exercised. *)
let replace_rgba ~image_id ~placement_id ~data ~pixel_width ~pixel_height ~rows =
  match Rgb_png.encode_rgba ~width:pixel_width ~height:pixel_height ~rgba:data with
  | Error _ -> ""
  | Ok png ->
      place_png ~identity:(identity ~image_id ~placement_id)
        ~extent:(Printf.sprintf ",r=%d" (max 1 rows)) ~data:png

(* [data] is a PNG file's bytes, sent as they are. The caller identifies the
   bytes first ([payload_media_type]): a terminal drops what it cannot decode
   and says nothing. *)
let replace_png ~image_id ~placement_id ~data ~rows ~cols ~crop =
  place_png ~identity:(identity ~image_id ~placement_id)
    ~extent:(extent ~rows ~cols ~crop) ~data

let viewport_extent (view : Masc_tui_image_viewport.window) =
  Printf.sprintf ",x=%d,y=%d,w=%d,h=%d,c=%d,r=%d"
    view.x view.y view.width view.height view.columns view.rows

let place_viewport ~data view =
  place_png ~identity:(identity ~image_id:(image_id Image_inspection) ~placement_id:1)
    ~extent:(viewport_extent view) ~data

let put_viewport view =
  Printf.sprintf "%sa=p%s%s,q=2%s" apc
    (identity ~image_id:(image_id Image_inspection) ~placement_id:1)
    (viewport_extent view) st

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

type image_region = { top : int; left : int; width_cells : float; height_cells : float }
let image_point region ~row ~column =
  let x = (float_of_int (column - region.left) +. 0.5) /. region.width_cells in
  let y = (float_of_int (row - region.top) +. 0.5) /. region.height_cells in
  if Float.is_finite x && Float.is_finite y && x >= 0. && x < 1. && y >= 0. && y < 1.
  then Some (x,y) else None
