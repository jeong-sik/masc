let ascii_byte byte = Char.code byte < 0x80

let utf8_scalar_byte_length first =
  let byte = Char.code first in
  if ascii_byte first then Some 1
  else if byte >= 0xC2 && byte <= 0xDF then Some 2
  else if byte >= 0xE0 && byte <= 0xEF then Some 3
  else if byte >= 0xF0 && byte <= 0xF4 then Some 4
  else None

let is_single_utf8_scalar text =
  if String.equal text "" || not (String.is_valid_utf_8 text) then false
  else
    let decoded = String.get_utf_8_uchar text 0 in
    Uchar.utf_decode_is_valid decoded
    && Uchar.utf_decode_length decoded = String.length text

let is_printable_utf8_scalar text =
  if not (is_single_utf8_scalar text) then false
  else
    let code =
      String.get_utf_8_uchar text 0 |> Uchar.utf_decode_uchar |> Uchar.to_int
    in
    code >= 0x20 && code <> 0x7F && not (code >= 0x80 && code <= 0x9F)

let drop_last_utf8_scalar text =
  if String.equal text "" || not (String.is_valid_utf_8 text) then text
  else
    let length = String.length text in
    let rec find_last offset previous =
      if offset >= length then previous
      else
        let scalar_length =
          String.get_utf_8_uchar text offset |> Uchar.utf_decode_length
        in
        find_last (offset + scalar_length) offset
    in
    String.sub text 0 (find_last 0 0)

(* Ctrl-W, and Alt+Backspace where the terminal sends ESC DEL: the last word
   goes, the separator before it stays, and two presses walk two words. The
   separators are the blanks a chat draft can hold -- space, tab, and the
   newline Ctrl-J puts in. A blank is always a whole one-byte scalar, so
   testing the lead byte is the whole test. *)
let drop_last_utf8_word text =
  if String.equal text "" || not (String.is_valid_utf_8 text) then text
  else
    let length = String.length text in
    let blank_at offset =
      match text.[offset] with ' ' | '\t' | '\n' -> true | _ -> false
    in
    let rec collect offset acc =
      if offset >= length then acc
      else
        let scalar_length =
          String.get_utf_8_uchar text offset |> Uchar.utf_decode_length
        in
        collect (offset + scalar_length) ((offset, scalar_length) :: acc)
    in
    (* The span list comes out newest-first: trailing blanks go first, then
       the word run before them. *)
    let rec skip_while blanking spans =
      match spans with
      | (start, _) :: rest when Bool.equal blanking (blank_at start) ->
          skip_while blanking rest
      | _ -> spans
    in
    match collect 0 [] |> skip_while true |> skip_while false with
    | (start, scalar_length) :: _ -> String.sub text 0 (start + scalar_length)
    | [] -> ""

let ansi_csi_end text offset =
  let length = String.length text in
  if offset + 1 >= length || text.[offset] <> '\x1B' || text.[offset + 1] <> '['
  then None
  else
    let rec scan index =
      if index >= length then None
      else
        let byte = Char.code text.[index] in
        if byte >= 0x40 && byte <= 0x7E then Some (index + 1)
        else if byte >= 0x20 && byte <= 0x3F then scan (index + 1)
        else None
    in
    scan (offset + 2)

let printable_ascii byte = byte >= ' ' && byte <= '~'

(* ASCII columns and padding have one cell per byte. A CSI is the same
   zero-cell piece [display_pieces] recognises. Any other byte needs the
   Unicode path, including an ASCII base followed by a combining mark or
   emoji selector: deciding the whole string first keeps that cluster whole. *)
let ascii_display_width text =
  let length = String.length text in
  let rec scan offset cells =
    if offset >= length then Some cells
    else if printable_ascii text.[offset] then scan (offset + 1) (cells + 1)
    else
      match ansi_csi_end text offset with
      | Some next -> scan next cells
      | None -> None
  in
  scan 0 0

let printable_ascii_range text start_offset end_offset =
  let rec scan offset =
    offset >= end_offset
    || (printable_ascii text.[offset] && scan (offset + 1))
  in
  scan start_offset

let scalar_cell_width scalar =
  let code = Uchar.to_int scalar in
  if code >= 0x20 && code <= 0x7E then 1
  else if Uucp.Func.is_regional_indicator scalar then 1
  else if Uucp.Emoji.is_emoji_presentation scalar then 2
  else Int.max 0 (Uucp.Break.tty_width_hint scalar)

(* A terminal that draws grapheme clusters gives an emoji sequence two cells
   whatever its scalars add up to, and the sum missed in both directions: a
   symbol made emoji by VS16 summed to one cell, a thumb with a skin tone to
   four, a family joined by ZWJ to six. These are the scalars that mark such
   a cluster: the emoji presentation selector (VS16), the zero width joiner
   (ZWJ), the skin tone modifiers, and the tags that spell a subregion flag.
   The text presentation selector (VS15) asks the other way, for one cell.
   Regional indicator pairs are not here: two of them already sum to the two
   cells a flag takes. Both readings apply only to a cluster that opens with
   a scalar carrying the Emoji property, which the keycap digits have and
   letters do not: a ZWJ joining the consonants of a Devanagari conjunct, or
   a VS16 after a plain letter, keeps the summed width. *)
let vs16 = Uchar.of_int 0xFE0F
let vs15 = Uchar.of_int 0xFE0E
let zwj = Uchar.of_int 0x200D
let skin_tone_first = 0x1F3FB
let skin_tone_last = 0x1F3FF
let tag_first = 0xE0020
let tag_last = 0xE007F
let emoji_cluster_cells = 2
let text_presentation_cells = 1

let widens_emoji_cluster scalar =
  let code = Uchar.to_int scalar in
  Uchar.equal scalar vs16
  || Uchar.equal scalar zwj
  || (code >= skin_tone_first && code <= skin_tone_last)
  || (code >= tag_first && code <= tag_last)

let narrows_emoji_cluster scalar = Uchar.equal scalar vs15

type display_piece = {
  start_offset : int;
  end_offset : int;
  cell_width : int;
  ansi : bool;
}

let scalar_pieces text start_offset end_offset reversed =
  let rec loop offset reversed =
    if offset >= end_offset then reversed
    else
      let decoded = String.get_utf_8_uchar text offset in
      let valid = Uchar.utf_decode_is_valid decoded in
      let scalar_length = Int.max 1 (Uchar.utf_decode_length decoded) in
      let next = Int.min end_offset (offset + scalar_length) in
      let width =
        if valid then scalar_cell_width (Uchar.utf_decode_uchar decoded) else 1
      in
      loop next
        ({ start_offset = offset;
           end_offset = next;
           cell_width = width;
           ansi = false;
         }
        :: reversed)
  in
  loop start_offset reversed

(* [String.is_valid_utf_8] wants a string of its own, and taking one meant
   copying the run before a single width was read. This asks the same question
   of the range in place. A scalar that would reach past [end_offset] is the
   truncated tail the copy would have rejected too. *)
let valid_utf_8_range text start_offset end_offset =
  let rec loop offset =
    if offset >= end_offset then true
    else
      let decoded = String.get_utf_8_uchar text offset in
      if not (Uchar.utf_decode_is_valid decoded) then false
      else
        let length = Uchar.utf_decode_length decoded in
        if offset + length > end_offset then false else loop (offset + length)
  in
  loop start_offset

(* What a piece needs is a byte span and a width, and neither needs the cluster
   to exist as a string. Going through [Uuseg_string.fold_utf_8] re-encoded
   every scalar into a buffer and cut a string out of it at each boundary --
   one allocation per character on screen, thrown away as soon as it was
   measured. The segmenter is driven directly here and the spans are read off
   [text]. The width is the same fold [grapheme_cell_width] did over the
   cluster, run as the scalars arrive. *)
let grapheme_pieces text start_offset end_offset reversed =
  if start_offset >= end_offset then reversed
  else if printable_ascii_range text start_offset end_offset then
    scalar_pieces text start_offset end_offset reversed
  else if not (valid_utf_8_range text start_offset end_offset) then
    scalar_pieces text start_offset end_offset reversed
  else begin
    let segmenter = Uuseg.create `Grapheme_cluster in
    let pieces = ref reversed in
    let cluster_start = ref start_offset in
    let cluster_end = ref start_offset in
    let width = ref 0 in
    let widest = ref 0 in
    let hangul_l = ref false in
    let hangul_vt = ref false in
    let emoji_base = ref false in
    let emoji_wide = ref false in
    let emoji_text = ref false in
    let close_cluster () =
      if !cluster_end > !cluster_start then begin
        (* A cluster carrying both selectors is malformed; the wide reading
           wins because a cell left blank is harmless and a cell overflowed
           breaks the border. *)
        let cells =
          if !emoji_base && !emoji_wide then emoji_cluster_cells
          else if !emoji_base && !emoji_text then text_presentation_cells
          else if !hangul_l && !hangul_vt then !widest
          else !width
        in
        pieces :=
          { start_offset = !cluster_start;
            end_offset = !cluster_end;
            cell_width = cells;
            ansi = false;
          }
          :: !pieces;
        cluster_start := !cluster_end;
        width := 0;
        widest := 0;
        hangul_l := false;
        hangul_vt := false;
        emoji_base := false;
        emoji_wide := false;
        emoji_text := false
      end
    in
    let take_scalar scalar =
      if !cluster_end = !cluster_start then
        emoji_base := Uucp.Emoji.is_emoji scalar;
      cluster_end := !cluster_end + Uchar.utf_8_byte_length scalar;
      let scalar_width = scalar_cell_width scalar in
      width := !width + scalar_width;
      widest := Int.max !widest scalar_width;
      let hangul_type = Uucp.Hangul.syllable_type scalar in
      hangul_l := !hangul_l || hangul_type = `L;
      hangul_vt := !hangul_vt || hangul_type = `V || hangul_type = `T;
      emoji_wide := !emoji_wide || widens_emoji_cluster scalar;
      emoji_text := !emoji_text || narrows_emoji_cluster scalar
    in
    let rec drain event =
      match Uuseg.add segmenter event with
      | `Uchar scalar ->
          take_scalar scalar;
          drain `Await
      | `Boundary ->
          close_cluster ();
          drain `Await
      | `Await | `End -> ()
    in
    let rec after_ascii offset =
      if offset < end_offset && printable_ascii text.[offset] then
        after_ascii (offset + 1)
      else offset
    in
    let rec feed offset =
      if offset >= end_offset then begin
        drain `End;
        close_cluster ()
      end
      else
        let decoded = String.get_utf_8_uchar text offset in
        let next = offset + Uchar.utf_decode_length decoded in
        drain (`Uchar (Uchar.utf_decode_uchar decoded));
        if printable_ascii text.[offset] then begin
          (* GB999 separates adjacent printable ASCII. Feed the first scalar
             normally for a preceding Prepend and retain the last for a
             following Extend, SpacingMark, ZWJ or keycap selector.

             Uuseg 17's grapheme update_left resets RI, emoji and Indic
             context after any printable ASCII (GCB=Other, InCB=None).
             [drain] has returned it to Await, so skipping more of that same
             state preserves the boundary before the last scalar. Keep one
             segmenter for the range, including runs with only one interior
             byte; no new segmenter is allocated at either boundary. *)
          let last = after_ascii next - 1 in
          if next < last then begin
            close_cluster ();
            pieces := scalar_pieces text next last !pieces;
            cluster_start := last;
            cluster_end := last;
            feed last
          end
          else feed next
        end
        else feed next
    in
    feed start_offset;
    !pieces
  end

let segment_display_pieces text =
  let length = String.length text in
  (* Only an escape can open a sequence, so the scan jumps to the next escape
     rather than asking at every byte of every rendered line. *)
  let rec find_ansi offset =
    if offset >= length then None
    else
      match String.index_from_opt text offset '\x1B' with
      | None -> None
      | Some escape -> (
          match ansi_csi_end text escape with
          | Some next -> Some (escape, next)
          | None -> find_ansi (escape + 1))
  in
  let rec loop offset reversed =
    match find_ansi offset with
    | None -> List.rev (grapheme_pieces text offset length reversed)
    | Some (ansi_start, ansi_end) ->
        let reversed =
          grapheme_pieces text offset ansi_start reversed
        in
        loop ansi_end
          ({ start_offset = ansi_start;
             end_offset = ansi_end;
             cell_width = 0;
             ansi = true;
           }
          :: reversed)
  in
  loop 0 []
