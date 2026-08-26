type result =
  { palette : Masc_tui_terminal_palette.t option
  ; theme_mode : Masc_tui_terminal_palette.theme_mode option
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
  | Csi_private
        (** [ESC \[ ?] and onward. Only reached when the bracketed-paste
            matcher has already ruled the sequence out, so the paste path
            keeps the first claim on every byte it wants. *)
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
  ; ansi : Masc_tui_terminal_palette.rgb option array
        (** One slot per SGR colour code. Written once each, by this decoder,
            as the OSC 4 answers arrive. Nothing waits on them: a terminal
            that answers 10 and 11 but not 4 leaves them all [None] and the
            probe still completes. *)
  ; mutable theme_mode : Masc_tui_terminal_palette.theme_mode option
        (** What the terminal last said about its own page. Set by the reply
            to DECSET 996 and again, unasked, by 2031 whenever the reader
            switches theme. Nothing waits on it: a terminal that answers
            neither leaves it [None]. *)
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
  ; ansi =
      Array.make Masc_tui_terminal_palette.ansi_slot_count None
  ; theme_mode = None
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
  | Masc_tui_terminal_palette.Ansi index ->
    if
      index >= 0
      && index < Masc_tui_terminal_palette.ansi_slot_count
      && Option.is_none decoder.ansi.(index)
    then decoder.ansi.(index) <- color
;;

(* [ESC \[] is two bytes, and the paste matcher counts them before it starts
   comparing. A private-parameter reply puts [?] at exactly that point. *)
let csi_introducer_length = 2
let private_parameter_marker = '?'

(* CSI ends at the first byte in 0x40..0x7E. The theme-mode reply ends at [n];
   anything else ending here is a sequence this did not ask for. *)
let is_csi_final byte = byte >= '\x40' && byte <= '\x7e'
let theme_mode_final = 'n'

let finish_csi_private decoder =
  let sequence = Buffer.contents decoder.pending in
  let length = String.length sequence in
  let mode =
    if length > csi_introducer_length && Char.equal sequence.[length - 1] theme_mode_final
    then
      Masc_tui_terminal_palette.parse_theme_mode_parameters
        (String.sub sequence csi_introducer_length
           (length - csi_introducer_length - 1))
    else None
  in
  (match mode with
   | Some mode -> if Option.is_none decoder.theme_mode then decoder.theme_mode <- Some mode
   | None ->
     (* Not the reply. It was held while it might have been, so it goes on
        whole rather than being dropped. *)
     flush_pending decoder);
  Buffer.clear decoder.pending;
  decoder.mode <- Normal
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
    else if
      matched = csi_introducer_length
      && Char.equal byte private_parameter_marker
      && decoder.palette_requested
    then begin
      (* [ESC \[ ?] is not the start of a paste, and it is the start of the
         theme-mode reply. Held rather than replayed so the reply does not
         reach the composer as typed text; a sequence that turns out to be
         something else is replayed whole when its final byte arrives. *)
      Buffer.add_char decoder.pending byte;
      decoder.mode <- Csi_private
    end
    else begin
      flush_pending decoder;
      decoder.mode <- Normal;
      feed decoder byte
    end
  | Csi_private ->
    Buffer.add_char decoder.pending byte;
    if is_csi_final byte then finish_csi_private decoder
    else if Buffer.length decoder.pending > response_max_bytes then begin
      (* No final byte within a reply's worth of bytes. Whatever this is, it
         is not the one being waited for, and holding more of the reader's
         input than that would be worse than passing it on. *)
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

let theme_mode decoder = decoder.theme_mode

let palette decoder =
  Masc_tui_terminal_palette.of_responses ~foreground:decoder.foreground
    ~background:decoder.background ~ansi:decoder.ansi
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
  ; theme_mode = decoder.theme_mode
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
        (* [Escape] alone is a key the reader pressed; every other held
           state is a sequence still arriving, and input running dry is not
           the end of it. [Csi_private] holds with them: the reply's final
           byte may be in the next read. *)
        | Normal | Paste_prefix _ | Paste _ | Osc_candidate _
        | Osc_passthrough _ | Csi_private | Apc_prefix | Apc _
        | Apc_passthrough _ ->
          None)
     | Some byte ->
       feed decoder byte;
       next decoder ~next_raw)
;;

let finish decoder =
  (match decoder.mode with
   (* Nothing is held in these: the passthrough states already replayed each
      byte as it arrived. *)
   | Normal | Paste _ | Osc_passthrough _ | Apc_passthrough _ -> ()
   (* These are holding bytes that turned out not to be the sequence they
      might have been, and the reader typed them. [Csi_private] among them:
      an unfinished reply is the reader's input, not ours to swallow. *)
   | Escape | Paste_prefix _ | Osc_candidate _ | Csi_private | Apc_prefix
   | Apc _ ->
     flush_pending decoder);
  decoder.mode <- Normal;
  snapshot decoder
;;

let decode ~palette_requested text =
  let decoder = create ~palette_requested in
  String.iter (feed decoder) text;
  finish decoder
;;
