type result =
  { palette : Masc_tui_terminal_palette.t option
  ; graphics : Masc_tui_graphics.query_reply option
  ; replay : string
  }

let max_bytes = 64 * 1024

let query ~palette =
  (if palette then Masc_tui_terminal_palette.query else "")
  ^ Masc_tui_graphics.query
;;

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
  | Apc_prefix
  | Apc of bool
  | Apc_passthrough of bool

type decoder =
  { palette_requested : bool
  ; replay : Buffer.t
  ; mutable replay_position : int
  ; pending : Buffer.t
  ; mutable mode : mode
  ; mutable foreground : Masc_tui_terminal_palette.rgb option
  ; mutable background : Masc_tui_terminal_palette.rgb option
  ; mutable graphics : Masc_tui_graphics.query_reply option
  }

let create ~palette_requested =
  { palette_requested
  ; replay = Buffer.create 128
  ; replay_position = 0
  ; pending = Buffer.create 64
  ; mode = Normal
  ; foreground = None
  ; background = None
  ; graphics = None
  }
;;

let prepare_replay decoder =
  if decoder.replay_position = Buffer.length decoder.replay then begin
    Buffer.clear decoder.replay;
    decoder.replay_position <- 0
  end
;;

let add_replay_char decoder byte =
  prepare_replay decoder;
  Buffer.add_char decoder.replay byte
;;

let add_replay_string decoder text =
  prepare_replay decoder;
  Buffer.add_string decoder.replay text
;;

let flush_pending decoder =
  add_replay_string decoder (Buffer.contents decoder.pending);
  Buffer.clear decoder.pending
;;

let record_palette decoder slot color =
  match slot with
  | Masc_tui_terminal_palette.Foreground ->
    if Option.is_none decoder.foreground then decoder.foreground <- color
  | Masc_tui_terminal_palette.Background ->
    if Option.is_none decoder.background then decoder.background <- color
;;

let finish_osc decoder terminator_bytes =
  let sequence = Buffer.contents decoder.pending in
  let body_length = String.length sequence - 2 - terminator_bytes in
  let response =
    Masc_tui_terminal_palette.parse_response
      (String.sub sequence 2 body_length)
  in
  (match response with
   | Masc_tui_terminal_palette.Palette_response { slot; color }
     when decoder.palette_requested -> record_palette decoder slot color
   | Masc_tui_terminal_palette.Palette_response _
   | Masc_tui_terminal_palette.Not_palette_response -> flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal
;;

let finish_apc decoder =
  let sequence = Buffer.contents decoder.pending in
  let body_length = String.length sequence - 3 - 2 in
  let reply =
    Masc_tui_graphics.parse_query_reply (String.sub sequence 3 body_length)
  in
  (match reply with
   | Some reply ->
     if Option.is_none decoder.graphics then decoder.graphics <- Some reply
   | None -> flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal
;;

let osc_prefix_match matched byte =
  match matched, byte with
  | 0, '1' -> Some 1
  | 1, ('0' | '1') -> Some 2
  | 2, ';' -> Some 3
  | 3, _ -> Some 3
  | _ -> None
;;

let rec feed decoder byte =
  match decoder.mode with
  | Normal ->
    if byte = escape then begin
      Buffer.add_char decoder.pending byte;
      decoder.mode <- Escape
    end
    else add_replay_char decoder byte
  | Escape ->
    (match byte with
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
    else begin
      flush_pending decoder;
      decoder.mode <- Normal;
      feed decoder byte
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
    else
      (match osc_prefix_match matched byte with
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
;;

let palette decoder =
  Masc_tui_terminal_palette.of_responses ~foreground:decoder.foreground
    ~background:decoder.background
;;

let complete decoder =
  Option.is_some decoder.graphics
  && ((not decoder.palette_requested)
      || (Option.is_some decoder.foreground
          && Option.is_some decoder.background))
;;

let unread_replay decoder =
  let replay = Buffer.contents decoder.replay in
  String.sub replay decoder.replay_position
    (String.length replay - decoder.replay_position)
;;

let snapshot decoder =
  { palette = palette decoder
  ; graphics = decoder.graphics
  ; replay = unread_replay decoder
  }
;;

let has_replay decoder = decoder.replay_position < Buffer.length decoder.replay

let take_replay decoder =
  if not (has_replay decoder) then None
  else begin
    let byte = Buffer.nth decoder.replay decoder.replay_position in
    decoder.replay_position <- decoder.replay_position + 1;
    Some byte
  end
;;

let return_replay decoder =
  decoder.replay_position <- max 0 (decoder.replay_position - 1)
;;

let rec next decoder ~next_raw =
  match take_replay decoder with
  | Some _ as replay -> replay
  | None when complete decoder ->
    (match next_raw () with
     | None -> None
     | Some byte ->
       add_replay_char decoder byte;
       take_replay decoder)
  | None ->
    (match next_raw () with
     | None ->
       (match decoder.mode with
        | Escape ->
          flush_pending decoder;
          decoder.mode <- Normal;
          take_replay decoder
        | Normal | Paste_prefix _ | Paste _ | Osc_candidate _
        | Osc_passthrough _ | Apc_prefix | Apc _ | Apc_passthrough _ -> None)
     | Some byte ->
       feed decoder byte;
       next decoder ~next_raw)
;;

let finish decoder =
  (match decoder.mode with
   | Normal | Paste _ | Osc_passthrough _ | Apc_passthrough _ -> ()
   | Escape | Paste_prefix _ | Osc_candidate _ | Apc_prefix | Apc _ ->
     flush_pending decoder);
  decoder.mode <- Normal;
  snapshot decoder
;;

let decode ~palette_requested text =
  let decoder = create ~palette_requested in
  String.iter (feed decoder) text;
  finish decoder
;;
