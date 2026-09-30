(* The card an issued play invite is drawn as. See the interface for why the
   link is handled as a credential. *)

module Palette = Masc_tui_terminal_palette

(* The blank margin a QR needs on every side to be found (ISO/IEC 18004). *)
let quiet_zone_modules = 4

let dark_pixel = "\000\000\000\255"
let light_pixel = "\255\255\255\255"
let dark = Palette.make_rgb ~red:0 ~green:0 ~blue:0
let light = Palette.make_rgb ~red:255 ~green:255 ~blue:255

let project_for_terminal rgb =
  if Masc_tui_theme.colors_enabled then Palette.best_color rgb else None
;;

type qr =
  | Drawn of { cols : int; rows : string list }
  | Undrawable of string  (** The sentence that says why, drawn in its place. *)

type t =
  { name : string
  ; expires_at : string
  ; link : string
  ; qr : qr
  }

(* The QR as a picture of two colours: one pixel per module, the quiet zone in
   light, drawn by the same half-block mosaic the portraits use so that its
   colours are its own and not the theme's. A terminal that cannot draw both
   colours would turn every cell into the same block, which reads as a QR and
   scans as nothing, so that case draws no QR at all. *)
let qr_of ~project link =
  match project dark, project light with
  | None, _ | _, None ->
    Undrawable "this terminal cannot draw the black and white a QR needs; use the link"
  | Some _, Some _ ->
    (match Qrc.encode link with
     | None -> Undrawable "the link is too long for a QR code; use the link"
     | Some matrix ->
       let modules = Qrc.Matrix.w matrix in
       let side = modules + (2 * quiet_zone_modules) in
       (* A cell stacks two pixel rows, so an odd side gets one more light row. *)
       let pixel_rows = side + (side land 1) in
       let is_dark ~x ~y =
         let module_x = x - quiet_zone_modules
         and module_y = y - quiet_zone_modules in
         module_x >= 0 && module_x < modules && module_y >= 0 && module_y < modules
         && Qrc.Matrix.get matrix ~x:module_x ~y:module_y
       in
       let pixels = Buffer.create (side * pixel_rows * String.length dark_pixel) in
       for y = 0 to pixel_rows - 1 do
         for x = 0 to side - 1 do
           Buffer.add_string pixels (if is_dark ~x ~y then dark_pixel else light_pixel)
         done
       done;
       (match
          Masc_tui_image_mosaic.render_rgba ~project ~cols:side ~rows:pixel_rows
            (Buffer.contents pixels)
        with
        | [] -> Undrawable "the QR could not be drawn; use the link"
        | rows -> Drawn { cols = side; rows }))
;;

(* Printable ASCII past the space, so the link has no blank, no control byte
   and no escape to carry into a terminal, and its bytes are its cells. The
   card is the only way to hold a link, so a link that is not this shape
   cannot reach the screen or the clipboard. *)
let is_plain_http_url link =
  (String.starts_with ~prefix:"https://" link || String.starts_with ~prefix:"http://" link)
  && String.for_all (fun c -> c > ' ' && c < '\127') link
;;

let make ~project ~name ~expires_at ~link =
  if is_plain_http_url link
  then
    Ok
      { name = Masc.Tui_terminal_text.sanitize_terminal_text name
      ; expires_at = Masc.Tui_terminal_text.sanitize_terminal_text expires_at
      ; link
      ; qr = qr_of ~project link
      }
  else Error "the invite link is not a plain http(s) URL of printable ASCII"
;;

let name card = card.name
let link card = card.link

let issued_notice card ~retained =
  let earlier =
    if retained then ". /play link <name> opens an earlier invite" else ""
  in
  Printf.sprintf "Play invite %s issued, expires %s. /play link shows its link again%s"
    card.name card.expires_at earlier
;;

type row =
  | Heading of string
  | Advice of string
  | Link_row of string
  | Qr_row of string
  | Note of string
  | Qr_needs of { columns : int; rows : int }
  | Blank

let advice =
  [ "Send this link to one person."
  ; "The server cannot show it again."
  ; "It opens the shared machine and nothing else."
  ]
;;

(* [make] only lets a link of printable ASCII through, so a byte is a cell and
   a cut never lands inside a character. *)
let cut_to_width ~width text =
  let width = max 1 width in
  let length = String.length text in
  let rec cut at pieces =
    if at >= length
    then List.rev pieces
    else (
      let take = min width (length - at) in
      cut (at + take) (String.sub text at take :: pieces))
  in
  cut 0 []
;;

(* Everything above the QR: what the card is, and the link cut to [width]. *)
let text_rows card ~width =
  let heading = Heading (Printf.sprintf "%s · expires %s" card.name card.expires_at) in
  (heading :: Blank :: List.map (fun line -> Advice line) advice)
  @ (Blank :: List.map (fun piece -> Link_row piece) (cut_to_width ~width card.link))
;;

let draw card ~width ~rows =
  let text = text_rows card ~width in
  match card.qr with
  | Undrawable why -> text @ [ Blank; Note why ]
  | Drawn { cols; rows = qr_rows } ->
    let rows_at width = List.length (text_rows card ~width) + 1 + List.length qr_rows in
    if cols <= width && rows_at width <= rows
    then text @ (Blank :: List.map (fun row -> Qr_row row) qr_rows)
    else (
      (* What is asked for is what is missing: a window already wide enough is
         not asked to grow, and the rows are counted at the width the QR will
         have, because a wider card cuts its link into fewer rows. *)
      let columns = max width cols in
      text @ [ Blank; Qr_needs { columns; rows = rows_at columns } ])
;;
