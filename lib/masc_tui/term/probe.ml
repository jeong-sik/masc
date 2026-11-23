type graphics_reply =
  | Graphics_supported
  | Graphics_refused of string

let equal_graphics_reply a b =
  match a, b with
  | Graphics_supported, Graphics_supported -> true
  | Graphics_refused x, Graphics_refused y -> String.equal x y
  | Graphics_supported, Graphics_refused _
  | Graphics_refused _, Graphics_supported ->
      false

let graphics_query_id = 31

(* Minimal valid 1x1 RGBA PNG for Kitty graphics protocol support check. *)
let one_pixel_png =
  "\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001\b\006\
   \000\000\000\031\021\196\137\000\000\000\nIDATx\156c\000\001\000\000\005\
   \000\001\r\n-\180\000\000\000\000IEND\174B`\130"

let graphics_query =
  Printf.sprintf "\x1b_Gi=%d,a=q,f=100;%s\x1b\\" graphics_query_id
    (Base64.encode_string one_pixel_png)

let parse_graphics_reply body =
  match String.index_opt body ';' with
  | None -> None
  | Some cut ->
      let keys = String.sub body 0 cut in
      let status = String.sub body (cut + 1) (String.length body - cut - 1) in
      let expected = Printf.sprintf "i=%d" graphics_query_id in
      let matches_id =
        String.split_on_char ',' keys |> List.exists (String.equal expected)
      in
      if not matches_id then None
      else if String.equal status "OK" then Some Graphics_supported
      else Some (Graphics_refused status)

type observation = {
  palette : Palette.t option;
  graphics : graphics_reply option;
  cell_pixels : (int * int) option;
}

let empty_observation = { palette = None; graphics = None; cell_pixels = None }

let equal_cell_pixels (w1, h1) (w2, h2) = Int.equal w1 w2 && Int.equal h1 h2

let equal_observation a b =
  Option.equal Palette.equal a.palette b.palette
  && Option.equal equal_graphics_reply a.graphics b.graphics
  && Option.equal equal_cell_pixels a.cell_pixels b.cell_pixels

let process_observation = Atomic.make empty_observation
let current_observation () = Atomic.get process_observation
let set_current_observation obs = Atomic.set process_observation obs

type result = {
  palette : Palette.t option;
  graphics : graphics_reply option;
  cell_pixels : (int * int) option;
  replay : string;
}

let max_bytes = 64 * 1024
let cell_size_query = "\x1b[16t"

let query ~palette =
  cell_size_query ^ (if palette then Palette.query else "") ^ graphics_query

let escape = '\x1b'
let bell = '\x07'
let paste_start = "\x1b[200~"
let paste_end = "\x1b[201~"
let response_max_bytes = 4096

type mode =
  | Normal
  | Escape
  | Paste_prefix of int
  | Paste of int
  | Osc_candidate of bool * int
  | Osc_passthrough of bool
  | Csi_window
  | Apc_prefix
  | Apc of bool
  | Apc_passthrough of bool

type decoder = {
  palette_requested : bool;
  replay : Buffer.t;
  mutable replay_position : int;
  pending : Buffer.t;
  mutable mode : mode;
  mutable foreground : Palette.rgb option;
  mutable background : Palette.rgb option;
  ansi : Palette.rgb option array;
  mutable observed : observation;
}

let create ~palette_requested =
  {
    palette_requested;
    replay = Buffer.create 128;
    replay_position = 0;
    pending = Buffer.create 64;
    mode = Normal;
    foreground = None;
    background = None;
    ansi = Array.make Palette.ansi_slot_count None;
    observed = { palette = None; graphics = None; cell_pixels = None };
  }

let prepare_replay decoder =
  if decoder.replay_position = Buffer.length decoder.replay then begin
    Buffer.clear decoder.replay;
    decoder.replay_position <- 0
  end

let add_replay_char decoder byte =
  prepare_replay decoder;
  Buffer.add_char decoder.replay byte

let add_replay_string decoder text =
  prepare_replay decoder;
  Buffer.add_string decoder.replay text

let flush_pending decoder =
  add_replay_string decoder (Buffer.contents decoder.pending);
  Buffer.clear decoder.pending

let observe_palette decoder slot color =
  if decoder.palette_requested then begin
    (match slot with
     | Palette.Foreground ->
         if Option.is_none decoder.foreground then decoder.foreground <- color
     | Palette.Background ->
         if Option.is_none decoder.background then decoder.background <- color
     | Palette.Ansi index ->
         if index >= 0 && index < Palette.ansi_slot_count
            && Option.is_none decoder.ansi.(index)
         then decoder.ansi.(index) <- color);
    let palette =
      Palette.of_responses ~foreground:decoder.foreground
        ~background:decoder.background ~ansi:decoder.ansi
    in
    if not (Option.equal Palette.equal palette decoder.observed.palette) then
      decoder.observed <- { decoder.observed with palette }
  end

let observe_graphics decoder reply =
  if Option.is_none decoder.observed.graphics then
    decoder.observed <- { decoder.observed with graphics = Some reply }

let observe_cell_pixels decoder ((width, height) as size) =
  if width > 0 && height > 0 && Option.is_none decoder.observed.cell_pixels then
    decoder.observed <- { decoder.observed with cell_pixels = Some size }

let observation decoder = decoder.observed
let csi_introducer_length = 2
let is_csi_final byte = byte >= '\x40' && byte <= '\x7e'
let window_report_final = 't'
let cell_size_report_code = "6"

let parse_cell_size body =
  match String.split_on_char ';' body with
  | [ code; height; width ] when String.equal code cell_size_report_code -> (
      match int_of_string_opt width, int_of_string_opt height with
      | Some width, Some height when width > 0 && height > 0 ->
          Some (width, height)
      | _, _ -> None)
  | _ -> None

let finish_csi_window decoder =
  let sequence = Buffer.contents decoder.pending in
  let length = String.length sequence in
  let size =
    if length > csi_introducer_length
       && Char.equal sequence.[length - 1] window_report_final
    then
      parse_cell_size
        (String.sub sequence csi_introducer_length
           (length - csi_introducer_length - 1))
    else None
  in
  (match size with
   | Some sz -> observe_cell_pixels decoder sz
   | None -> flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal

let finish_osc decoder terminator_bytes =
  let sequence = Buffer.contents decoder.pending in
  let body_length = String.length sequence - 2 - terminator_bytes in
  let response =
    Palette.parse_response (String.sub sequence 2 body_length)
  in
  (match response with
   | Palette.Palette_response { slot; color } when decoder.palette_requested ->
       observe_palette decoder slot color
   | Palette.Palette_response _ | Palette.Not_palette_response ->
       flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal

let finish_apc decoder =
  let sequence = Buffer.contents decoder.pending in
  let body_length = String.length sequence - 3 - 2 in
  let reply =
    parse_graphics_reply (String.sub sequence 3 body_length)
  in
  (match reply with
   | Some r -> observe_graphics decoder r
   | None -> flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal

let osc_prefix_match matched byte =
  match matched, byte with
  | 0, '1' -> Some 1
  | 1, ('0' | '1') -> Some 2
  | 0, '4' -> Some 2
  | 2, ';' -> Some 3
  | 3, _ -> Some 3
  | _ -> None

let rec feed decoder byte =
  match decoder.mode with
  | Normal ->
      if byte = escape then begin
        Buffer.add_char decoder.pending byte;
        decoder.mode <- Escape
      end
      else add_replay_char decoder byte
  | Escape -> (
      match byte with
      | ']' ->
          Buffer.add_char decoder.pending byte;
          if decoder.palette_requested then
            decoder.mode <- Osc_candidate (false, 0)
          else begin
            flush_pending decoder;
            decoder.mode <- Osc_passthrough false
          end
      | '[' ->
          Buffer.add_char decoder.pending byte;
          decoder.mode <- Paste_prefix 2
      | '_' ->
          Buffer.add_char decoder.pending byte;
          decoder.mode <- Apc_prefix
      | _ ->
          flush_pending decoder;
          decoder.mode <- Normal;
          feed decoder byte)
  | Paste_prefix matched ->
      if byte = paste_start.[matched] then begin
        Buffer.add_char decoder.pending byte;
        let matched = matched + 1 in
        if matched = String.length paste_start then begin
          flush_pending decoder;
          decoder.mode <- Paste 0
        end
        else decoder.mode <- Paste_prefix matched
      end
      else if
        matched = csi_introducer_length
        && Char.equal byte cell_size_report_code.[0]
        && Option.is_none decoder.observed.cell_pixels
      then begin
        Buffer.add_char decoder.pending byte;
        decoder.mode <- Csi_window
      end
      else begin
        flush_pending decoder;
        decoder.mode <- Normal;
        feed decoder byte
      end
  | Csi_window ->
      Buffer.add_char decoder.pending byte;
      if is_csi_final byte then finish_csi_window decoder
      else if Buffer.length decoder.pending > response_max_bytes then begin
        flush_pending decoder;
        decoder.mode <- Normal
      end
  | Paste matched ->
      add_replay_char decoder byte;
      let matched =
        if byte = paste_end.[matched] then matched + 1
        else if byte = paste_end.[0] then 1
        else 0
      in
      if matched = String.length paste_end then decoder.mode <- Normal
      else decoder.mode <- Paste matched
  | Osc_candidate (previous_was_escape, matched) ->
      Buffer.add_char decoder.pending byte;
      if byte = bell then finish_osc decoder 1
      else if previous_was_escape && byte = '\\' then finish_osc decoder 2
      else (
        match osc_prefix_match matched byte with
        | Some matched when Buffer.length decoder.pending <= response_max_bytes ->
            decoder.mode <- Osc_candidate (byte = escape, matched)
        | Some _ | None ->
            flush_pending decoder;
            decoder.mode <- Osc_passthrough (byte = escape))
  | Osc_passthrough previous_was_escape ->
      add_replay_char decoder byte;
      if byte = bell || (previous_was_escape && byte = '\\') then
        decoder.mode <- Normal
      else decoder.mode <- Osc_passthrough (byte = escape)
  | Apc_prefix ->
      if byte = 'G' then begin
        Buffer.add_char decoder.pending byte;
        decoder.mode <- Apc false
      end
      else begin
        flush_pending decoder;
        decoder.mode <- Normal;
        feed decoder byte
      end
  | Apc previous_was_escape ->
      Buffer.add_char decoder.pending byte;
      if previous_was_escape && byte = '\\' then finish_apc decoder
      else if Buffer.length decoder.pending > response_max_bytes then begin
        flush_pending decoder;
        decoder.mode <- Apc_passthrough (byte = escape)
      end
      else decoder.mode <- Apc (byte = escape)
  | Apc_passthrough previous_was_escape ->
      add_replay_char decoder byte;
      if previous_was_escape && byte = '\\' then decoder.mode <- Normal
      else decoder.mode <- Apc_passthrough (byte = escape)

let palette decoder = decoder.observed.palette

let complete decoder =
  Option.is_some decoder.observed.graphics
  && ((not decoder.palette_requested)
      || (Option.is_some decoder.foreground && Option.is_some decoder.background))

let pending decoder : Input_decoder.pending option =
  match decoder.mode with
  | Escape -> Some Input_decoder.Prefix
  | Paste_prefix _ | Osc_candidate _ | Csi_window | Apc_prefix | Apc _ ->
      Some Input_decoder.Sequence
  | Normal | Paste _ | Osc_passthrough _ | Apc_passthrough _ -> None

let holds_incomplete_sequence decoder =
  match pending decoder with
  | Some Input_decoder.Sequence -> true
  | Some
      ( Input_decoder.Prefix
      | Input_decoder.Character
      | Input_decoder.Pasting
      | Input_decoder.Draining )
  | None ->
      false

let discard_incomplete_sequence decoder =
  if holds_incomplete_sequence decoder then begin
    Buffer.clear decoder.pending;
    decoder.mode <- Normal
  end

let unread_replay decoder =
  let replay = Buffer.contents decoder.replay in
  String.sub replay decoder.replay_position
    (String.length replay - decoder.replay_position)

let snapshot decoder : result =
  {
    palette = palette decoder;
    graphics = decoder.observed.graphics;
    cell_pixels = decoder.observed.cell_pixels;
    replay = unread_replay decoder;
  }

let has_replay decoder = decoder.replay_position < Buffer.length decoder.replay

type startup_status =
  | Awaiting_replies
  | Input_ready
  | Replies_ready

let startup_status decoder =
  if has_replay decoder then Input_ready
  else if complete decoder then Replies_ready
  else Awaiting_replies

let take_replay decoder =
  if not (has_replay decoder) then None
  else begin
    let byte = Buffer.nth decoder.replay decoder.replay_position in
    decoder.replay_position <- decoder.replay_position + 1;
    Some byte
  end

let return_replay decoder =
  decoder.replay_position <- Int.max 0 (decoder.replay_position - 1)

let rec next decoder ~next_raw =
  match take_replay decoder with
  | Some _ as replay -> replay
  | None when complete decoder -> (
      match next_raw () with
      | None -> None
      | Some byte ->
          add_replay_char decoder byte;
          take_replay decoder)
  | None -> (
      match next_raw () with
      | None -> (
          match pending decoder with
          | Some Input_decoder.Prefix ->
              flush_pending decoder;
              decoder.mode <- Normal;
              take_replay decoder
          | Some
              ( Input_decoder.Sequence
              | Input_decoder.Character
              | Input_decoder.Pasting
              | Input_decoder.Draining )
          | None ->
              None)
      | Some byte ->
          feed decoder byte;
          next decoder ~next_raw)

let finish decoder =
  (match decoder.mode with
   | Normal | Paste _ | Osc_passthrough _ | Apc_passthrough _ -> ()
   | Escape
   | Paste_prefix _
   | Osc_candidate _
   | Csi_window
   | Apc_prefix
   | Apc _ ->
       flush_pending decoder);
  decoder.mode <- Normal;
  snapshot decoder

let decode ~palette_requested text =
  let decoder = create ~palette_requested in
  String.iter (feed decoder) text;
  finish decoder
