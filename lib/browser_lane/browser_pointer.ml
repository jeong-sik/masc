type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
let ( let* ) = Result.bind
let fields allowed = function
  | `Assoc fields when List.length fields = List.length allowed
      && List.sort String.compare (List.map fst fields) = List.sort String.compare allowed -> Ok fields
  | _ -> Error "pointer geometry has missing, duplicate or unknown fields"
let number key fields = match List.assoc_opt key fields with
  | Some (`Int value) -> Ok (float_of_int value)
  | Some (`Float value) when Float.is_finite value -> Ok value
  | _ -> Error ("pointer geometry requires finite " ^ key)
let point_of_json json =
  let* fields = fields ["x"; "y"] json in
  let* x = number "x" fields in let* y = number "y" fields in
  if x >= 0. && x < 1. && y >= 0. && y < 1. then Ok {x;y}
  else Error "pointer coordinates must be viewport fractions in [0,1)"
let viewport_of_json json =
  let* fields = fields ["documentId"; "width"; "height"; "scrollX"; "scrollY"] json in
  let* document_id = match List.assoc_opt "documentId" fields with
    | Some (`String id) when id <> "" -> Ok id | _ -> Error "viewport requires documentId" in
  let* width = number "width" fields in let* height = number "height" fields in
  let* scroll_x = number "scrollX" fields in let* scroll_y = number "scrollY" fields in
  if width > 0. && height > 0. then Ok {document_id;width;height;scroll_x;scroll_y}
  else Error "viewport dimensions must be positive"
let point_to_json point = `Assoc ["x",`Float point.x;"y",`Float point.y]
let viewport_to_json viewport = `Assoc ["documentId",`String viewport.document_id;
  "width",`Float viewport.width;"height",`Float viewport.height;
  "scrollX",`Float viewport.scroll_x;"scrollY",`Float viewport.scroll_y]

type button = Primary | Middle | Secondary

let button_to_string = function
  | Primary -> "primary"
  | Middle -> "middle"
  | Secondary -> "secondary"

let button_of_string = function
  | "primary" -> Some Primary
  | "middle" -> Some Middle
  | "secondary" -> Some Secondary
  | _ -> None

(* The WebDriver pointer button numbers: 0 left, 1 middle, 2 right. *)
let button_number = function
  | Primary -> 0
  | Middle -> 1
  | Secondary -> 2

type gesture =
  | Hover
  | Click of button
  | Double_click
  | Drag of { via : point list; destination : point; duration_ms : int }
  | Wheel of { x : int; y : int }
  | Tap
  | Swipe of { via : point list; destination : point; duration_ms : int }

let input_sources ~pointer_id ~wheel_id ~viewport ~start gesture =
  let coords (point : point) =
    [ "x", `Int (int_of_float (point.x *. viewport.width))
    ; "y", `Int (int_of_float (point.y *. viewport.height)) ] in
  let move ~duration_ms point = `Assoc
    ([ "type", `String "pointerMove"; "origin", `String "viewport"
     ; "duration", `Int duration_ms ] @ coords point) in
  let button ?(which = Primary) kind =
    `Assoc ["type", `String kind; "button", `Int (button_number which)] in
  let pointer ?(pointer_type = "mouse") actions = `Assoc
    [ "type", `String "pointer"; "id", `String pointer_id
    ; "parameters", `Assoc ["pointerType", `String pointer_type]
    ; "actions", `List actions ] in
  (* A press, the moves while it is held, and the release. A drag and a swipe are the same sequence; only
     the pointer that makes it differs. *)
  let held ?pointer_type ~start ~via ~destination ~duration_ms () =
    let via = match via with
      | [] -> [{x=(start.x +. destination.x) /. 2.; y=(start.y +. destination.y) /. 2.}]
      | _::_ -> via in
    pointer ?pointer_type
      ([move ~duration_ms:0 start; button "pointerDown"]
       @ List.map (move ~duration_ms) (via @ [destination])
       @ [move ~duration_ms:0 destination; button "pointerUp"]) in
  let source = match gesture with
    | Hover -> pointer [move ~duration_ms:0 start]
    | Click which ->
        pointer [move ~duration_ms:0 start; button ~which "pointerDown"; button ~which "pointerUp"]
    | Double_click -> pointer [move ~duration_ms:0 start; button "pointerDown"; button "pointerUp";
        button "pointerDown"; button "pointerUp"]
    | Drag {via;destination;duration_ms} -> held ~start ~via ~destination ~duration_ms ()
    | Swipe {via;destination;duration_ms} -> held ~pointer_type:"touch" ~start ~via ~destination ~duration_ms ()
    | Tap -> pointer ~pointer_type:"touch" [move ~duration_ms:0 start; button "pointerDown"; button "pointerUp"]
    | Wheel {x;y} -> `Assoc
        [ "type", `String "wheel"; "id", `String wheel_id
        ; "actions", `List [`Assoc
            ([ "type", `String "scroll"; "duration", `Int 0
             ; "origin", `String "viewport"; "deltaX", `Int x; "deltaY", `Int y ]
             @ coords start)] ] in
  `List [source]
