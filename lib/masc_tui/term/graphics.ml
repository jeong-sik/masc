type placement = {
  columns : int;
  rows : int;
}

let fit_rows ~cell_pixels ~image_pixels ~columns ~rows =
  match cell_pixels, image_pixels with
  | Some (cw, ch), Some (iw, ih) when cw > 0 && ch > 0 && iw > 0 && ih > 0 ->
      let allowed =
        float_of_int (max 1 columns)
        *. float_of_int cw
        *. float_of_int ih
        /. float_of_int iw
        /. float_of_int ch
      in
      max 1 (int_of_float (min (float_of_int (max 1 rows)) allowed))
  | Some _, Some _ | Some _, None | None, Some _ | None, None -> max 1 rows

let fit_cells ~cell_pixels ~image_pixels ~columns ~rows =
  let max_cols = max 1 columns in
  let max_rows = max 1 rows in
  match image_pixels with
  | Some (iw, ih) when iw > 0 && ih > 0 ->
      let cw, ch =
        match cell_pixels with
        | Some (w, h) when w > 0 && h > 0 -> (w, h)
        | Some _ | None -> (8, 16)
      in
      let box_w_px = float_of_int max_cols *. float_of_int cw in
      let box_h_px = float_of_int max_rows *. float_of_int ch in
      let scale =
        Float.min (box_w_px /. float_of_int iw) (box_h_px /. float_of_int ih)
      in
      let scaled_cols =
        int_of_float
          (Float.floor ((float_of_int iw *. scale /. float_of_int cw) +. 1e-9))
      in
      let scaled_rows =
        int_of_float
          (Float.floor ((float_of_int ih *. scale /. float_of_int ch) +. 1e-9))
      in
      (max 1 (min max_cols scaled_cols), max 1 (min max_rows scaled_rows))
  | Some _ | None -> (max_cols, max_rows)

type query_reply =
  | Supported
  | Refused of string

let equal_query_reply a b =
  match a, b with
  | Supported, Supported -> true
  | Refused x, Refused y -> String.equal x y
  | Supported, Refused _ | Refused _, Supported -> false

let apc = "\x1b_G"
let st = "\x1b\\"

type image =
  | Graphics_query
  | Msx_screen
  | Mascot
  | Keeper_portrait
  | About_keeper_1
  | About_keeper_2
  | About_keeper_3
  | About_keeper_4
  | Evidence_image_1
  | Evidence_image_2
  | Evidence_image_3
  | Evidence_image_4
  | Image_inspection
  | Memory_diagram

let all_of_image =
  [
    Graphics_query;
    Msx_screen;
    Mascot;
    Keeper_portrait;
    About_keeper_1;
    About_keeper_2;
    About_keeper_3;
    About_keeper_4;
    Evidence_image_1;
    Evidence_image_2;
    Evidence_image_3;
    Evidence_image_4;
    Image_inspection;
    Memory_diagram;
  ]

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
  | Memory_diagram -> 56

let evidence_images =
  [ Evidence_image_1; Evidence_image_2; Evidence_image_3; Evidence_image_4 ]

let resource_image_id index = 0x10000 + max 0 index
let query_id = image_id Graphics_query

let one_pixel_png =
  "\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001\b\006\
   \000\000\000\031\021\196\137\000\000\000\nIDATx\156c\000\001\000\000\005\
   \000\001\r\n-\180\000\000\000\000IEND\174B`\130"

let query =
  Printf.sprintf "%si=%d,a=q,f=100;%s%s" apc query_id
    (Base64.encode_string one_pixel_png)
    st

let parse_query_reply body =
  match String.index_opt body ';' with
  | None -> None
  | Some cut ->
      let keys = String.sub body 0 cut in
      let status = String.sub body (cut + 1) (String.length body - cut - 1) in
      let expected = Printf.sprintf "i=%d" query_id in
      let answers_the_query =
        String.split_on_char ',' keys |> List.exists (String.equal expected)
      in
      if not answers_the_query then None
      else if String.equal status "OK" then Some Supported
      else Some (Refused status)

let chunk_bytes = 4096
let payload_media_type = "image/png"

let encode_rgb ~identity ~data ~pixel_width ~pixel_height ~rows =
  let max_rgb_pixels = max_int / 3 in
  if
    String.length data = 0
    || pixel_width <= 0
    || pixel_height <= 0
    || pixel_width > max_rgb_pixels
    || pixel_height > max_rgb_pixels / pixel_width
    || String.length data <> pixel_width * pixel_height * 3
  then ""
  else
    let encoded = Base64.encode_string data in
    let length = String.length encoded in
    let out = Buffer.create (length + (length / chunk_bytes * 32) + 64) in
    let rec emit offset =
      let remaining = length - offset in
      let size = min chunk_bytes remaining in
      let more = if remaining > size then 1 else 0 in
      if offset = 0 then
        Buffer.add_string out
          (Printf.sprintf "%sf=24,s=%d,v=%d,a=T%s,r=%d,q=2,m=%d;%s%s" apc
             pixel_width pixel_height identity (max 1 rows) more
             (String.sub encoded offset size)
             st)
      else
        Buffer.add_string out
          (Printf.sprintf "%sm=%d;%s%s" apc more
             (String.sub encoded offset size)
             st);
      if more = 1 then emit (offset + size)
    in
    emit 0;
    Buffer.contents out

let identity ~image_id ~placement_id =
  Printf.sprintf ",i=%d,p=%d,C=1" image_id placement_id

let replace_rgb ~image_id ~placement_id =
  encode_rgb ~identity:(identity ~image_id ~placement_id)

let put ~image_id ~placement_id ~rows =
  Printf.sprintf "%sa=p%s,r=%d,q=2%s" apc
    (identity ~image_id ~placement_id)
    (max 1 rows) st

type crop = {
  top_px : int;
  height_px : int;
}

let extent ~rows ~cols ~crop =
  Printf.sprintf ",r=%d,c=%d%s" (max 1 rows) (max 1 cols)
    (match crop with
     | None -> ""
     | Some { top_px; height_px } ->
         Printf.sprintf ",y=%d,h=%d" (max 0 top_px) (max 1 height_px))

let put_png ~image_id ~placement_id ~rows ~cols ~crop =
  Printf.sprintf "%sa=p%s%s,q=2%s" apc
    (identity ~image_id ~placement_id)
    (extent ~rows ~cols ~crop) st

let delete_placement ~image_id ~placement_id =
  Printf.sprintf "%sa=d,d=i,i=%d,p=%d,q=2%s" apc image_id placement_id st

let delete_image ~image_id =
  Printf.sprintf "%sa=d,d=I,i=%d,q=2%s" apc image_id st

let place_png ~identity ~extent ~data =
  let encoded = Base64.encode_string data in
  let length = String.length encoded in
  if length = 0 then ""
  else
    let out = Buffer.create (length + (length / chunk_bytes * 32) + 64) in
    let rec emit offset =
      let remaining = length - offset in
      let size = min chunk_bytes remaining in
      let more = if remaining > size then 1 else 0 in
      if offset = 0 then
        Buffer.add_string out
          (Printf.sprintf "%sf=100,a=T%s%s,q=2,m=%d;%s%s" apc identity extent
             more
             (String.sub encoded offset size)
             st)
      else
        Buffer.add_string out
          (Printf.sprintf "%sm=%d;%s%s" apc more
             (String.sub encoded offset size)
             st);
      if more = 1 then emit (offset + size)
    in
    emit 0;
    Buffer.contents out

let place ~data ~rows =
  place_png ~identity:"" ~extent:(Printf.sprintf ",r=%d" (max 1 rows)) ~data

let replace_rgba ~image_id ~placement_id ~data ~pixel_width ~pixel_height ~rows =
  match
    Rgb_png.encode_rgba ~width:pixel_width ~height:pixel_height ~rgba:data
  with
  | Error _ -> ""
  | Ok png ->
      place_png
        ~identity:(identity ~image_id ~placement_id)
        ~extent:(Printf.sprintf ",r=%d" (max 1 rows))
        ~data:png

let replace_png ~image_id ~placement_id ~data ~rows ~cols ~crop =
  place_png
    ~identity:(identity ~image_id ~placement_id)
    ~extent:(extent ~rows ~cols ~crop)
    ~data

type viewport_window = {
  x : int;
  y : int;
  width : int;
  height : int;
  columns : int;
  rows : int;
}

let viewport_extent (view : viewport_window) =
  Printf.sprintf ",x=%d,y=%d,w=%d,h=%d,c=%d,r=%d" (max 0 view.x) (max 0 view.y)
    (max 1 view.width) (max 1 view.height) (max 1 view.columns)
    (max 1 view.rows)

let place_viewport ?(image_id = image_id Image_inspection) ?(placement_id = 1)
    ~data view =
  place_png
    ~identity:(identity ~image_id ~placement_id)
    ~extent:(viewport_extent view) ~data

let put_viewport ?(image_id = image_id Image_inspection) ?(placement_id = 1)
    view =
  Printf.sprintf "%sa=p%s%s,q=2%s" apc
    (identity ~image_id ~placement_id)
    (viewport_extent view) st

let delete_all = Printf.sprintf "%sa=d%s" apc st

type graphics_protocol =
  | Kitty_protocol
  | ITerm2_protocol
  | Unsupported_protocol

let equal_graphics_protocol a b =
  match a, b with
  | Kitty_protocol, Kitty_protocol
  | ITerm2_protocol, ITerm2_protocol
  | Unsupported_protocol, Unsupported_protocol ->
      true
  | Kitty_protocol, (ITerm2_protocol | Unsupported_protocol)
  | ITerm2_protocol, (Kitty_protocol | Unsupported_protocol)
  | Unsupported_protocol, (Kitty_protocol | ITerm2_protocol) ->
      false

let non_empty_env ~getenv key =
  match getenv key with
  | Some value -> not (String.equal (String.trim value) "")
  | None -> false

let in_multiplexer ~getenv =
  non_empty_env ~getenv "TMUX" || non_empty_env ~getenv "STY"

let effective_term_program ~getenv =
  let term_lc =
    match getenv "TERM" with
    | Some term ->
        let trimmed = String.lowercase_ascii (String.trim term) in
        if String.length trimmed > 0 && not (String.equal trimmed "dumb") then
          Some trimmed
        else None
    | None -> None
  in
  match term_lc with
  | None -> None
  | Some term ->
      if in_multiplexer ~getenv then None
      else
        match getenv "TERM_PROGRAM" with
        | Some tp when not (String.equal (String.trim tp) "") -> Some tp
        | Some _ | None -> (
            match term with
            | "xterm-kitty" -> Some "kitty"
            | "xterm-ghostty" -> Some "ghostty"
            | _ -> None)

let normalized_term_program = function
  | Some value ->
      let trimmed = String.lowercase_ascii (String.trim value) in
      if String.equal trimmed "" then None else Some trimmed
  | None -> None

let protocol_of_probe ~graphics ~term_program =
  match graphics with
  | Some Probe.Graphics_supported -> Kitty_protocol
  | Some (Probe.Graphics_refused _) -> (
      match normalized_term_program term_program with
      | Some "iterm.app" -> ITerm2_protocol
      | Some _ | None -> Unsupported_protocol)
  | None -> (
      match normalized_term_program term_program with
      | Some ("ghostty" | "wezterm" | "kitty") -> Kitty_protocol
      | Some "iterm.app" -> ITerm2_protocol
      | Some _ | None -> Unsupported_protocol)

let iterm2_place ~data ({ columns; rows } : placement) =
  let encoded = Base64.encode_string data in
  if String.length encoded = 0 then ""
  else
    Printf.sprintf
      "\x1b]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\x07"
      (max 1 columns) (max 1 rows) encoded

let tmux_wrapped payload =
  if String.length payload = 0 then ""
  else
    let escaped =
      String.concat "\x1b\x1b" (String.split_on_char '\x1b' payload)
    in
    "\x1bPtmux;" ^ escaped ^ "\x1b\\"

type image_region = {
  top : int;
  left : int;
  width_cells : float;
  height_cells : float;
}

let image_point region ~row ~column =
  if
    not
      (Float.is_finite region.width_cells
       && Float.is_finite region.height_cells
       && region.width_cells > 0.
       && region.height_cells > 0.)
  then None
  else
    let x = (float_of_int (column - region.left) +. 0.5) /. region.width_cells in
    let y = (float_of_int (row - region.top) +. 0.5) /. region.height_cells in
    if
      Float.is_finite x
      && Float.is_finite y
      && x >= 0.
      && x < 1.
      && y >= 0.
      && y < 1.
    then Some (x, y)
    else None
