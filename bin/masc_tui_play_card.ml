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

type undrawable_reason =
  | Terminal_no_bw
  | Link_too_long
  | Render_failed

type qr =
  | Drawn of { cols : int; rows : string list }
  | Undrawable of undrawable_reason

type t =
  { name : string
  ; expires_at : string
  ; link : string
  ; qr : qr
  }

let undrawable_text ~ko = function
  | Terminal_no_bw ->
      if ko then "이 터미널은 QR에 필요한 흑백 표시를 지원하지 않습니다. 링크를 사용하세요."
      else "this terminal cannot draw the black and white a QR needs; use the link"
  | Link_too_long ->
      if ko then "링크가 너무 길어 QR 코드로 만들 수 없습니다. 링크를 사용하세요."
      else "the link is too long for a QR code; use the link"
  | Render_failed ->
      if ko then "QR 코드를 그릴 수 없습니다. 링크를 사용하세요."
      else "the QR could not be drawn; use the link"

(* The QR as a picture of two colours: one pixel per module, the quiet zone in
   light, drawn by the same half-block mosaic the portraits use so that its
   colours are its own and not the theme's. A terminal that cannot draw both
   colours would turn every cell into the same block, which reads as a QR and
   scans as nothing, so that case draws no QR at all. *)
let qr_of ~project link =
  match project dark, project light with
  | None, _ | _, None -> Undrawable Terminal_no_bw
  | Some _, Some _ ->
    (match Qrc.encode link with
     | None -> Undrawable Link_too_long
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
        | [] -> Undrawable Render_failed
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

let make_for ~ko ~project ~name ~expires_at ~link =
  if is_plain_http_url link
  then
    Ok
      { name = Masc.Tui_terminal_text.sanitize_terminal_text name
      ; expires_at = Masc.Tui_terminal_text.sanitize_terminal_text expires_at
      ; link
      ; qr = qr_of ~project link
      }
  else
    Error
      (if ko then "초대 링크가 출력 가능한 ASCII 형식의 http(s) URL이 아닙니다"
       else "the invite link is not a plain http(s) URL of printable ASCII")
;;

let make ~project ~name ~expires_at ~link =
  make_for ~ko:false ~project ~name ~expires_at ~link
;;

let name card = card.name
let link card = card.link

let issued_notice ?(ko = false) card ~retained =
  if ko then
    let earlier =
      if retained then " · /play link <이름>으로 이전 초대를 다시 엽니다" else ""
    in
    Printf.sprintf "플레이 초대 %s 발급됨 (만료 %s) · /play link로 링크를 다시 볼 수 있습니다%s"
      card.name card.expires_at earlier
  else
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

let advice ~ko =
  if ko then
    [ "이 링크는 한 사람에게만 공유하세요."
    ; "서버는 이 링크를 다시 보여 주지 않습니다."
    ; "공유 머신 화면만 열리며 다른 기능에는 접근하지 않습니다."
    ]
  else
    [ "Send this link to one person."
    ; "The server cannot show it again."
    ; "It opens the shared machine and nothing else."
    ]
;;

type address_class = Reachable | Local_only | Wildcard_bind

let classify_address card =
  match Uri.host (Uri.of_string card.link) with
  | Some host when Masc_network_defaults.is_unspecified_host host -> Wildcard_bind
  | Some host when Masc_network_defaults.is_loopback_host host -> Local_only
  | Some _ | None -> Reachable

let address_advice ~ko card =
  match classify_address card with
  | Wildcard_bind ->
    if ko then
      [ Note "이 링크는 외부에서 접속할 수 없는 와일드카드 바인드 주소를 가리킵니다."
      ; Note "게스트 링크를 발급하기 전에 MASC_HTTP_BASE_URL을 접속 가능한 서버 주소로 설정하세요."
      ]
    else
      [ Note "This link names a wildcard bind address, not a reachable destination."
      ; Note "Set MASC_HTTP_BASE_URL to the server's reachable address before issuing a guest link."
      ]
  | Local_only ->
    if ko then
      [ Note "이 링크는 현재 컴퓨터에서만 열리며 휴대폰 QR 스캔으로는 접속할 수 없습니다."
      ; Note "외부 게스트용으로는 MASC_HTTP_BASE_URL을 접속 가능한 주소로 설정한 뒤 발급하세요."
      ]
    else
      [ Note "This link works on this computer only; a phone's QR scan cannot reach it."
      ; Note "For guests, set the server's MASC_HTTP_BASE_URL to its reachable address before issuing a link."
      ]
  | Reachable -> []

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
let text_rows ~ko card ~width =
  let heading =
    Heading
      (Printf.sprintf
         (if ko then "%s · 만료 %s" else "%s · expires %s")
         card.name card.expires_at)
  in
  (heading :: Blank :: List.map (fun line -> Advice line) (advice ~ko))
  @ address_advice ~ko card
  @ (Blank :: List.map (fun piece -> Link_row piece) (cut_to_width ~width card.link))
;;

let draw ?(ko = false) card ~width ~rows =
  let text = text_rows ~ko card ~width in
  match card.qr with
  | Undrawable reason -> text @ [ Blank; Note (undrawable_text ~ko reason) ]
  | Drawn { cols; rows = qr_rows } ->
    let rows_at width = List.length (text_rows ~ko card ~width) + 1 + List.length qr_rows in
    if cols <= width && rows_at width <= rows
    then text @ (Blank :: List.map (fun row -> Qr_row row) qr_rows)
    else (
      (* What is asked for is what is missing: a window already wide enough is
         not asked to grow, and the rows are counted at the width the QR will
         have, because a wider card cuts its link into fewer rows. *)
      let columns = max width cols in
      text @ [ Blank; Qr_needs { columns; rows = rows_at columns } ])
;;
