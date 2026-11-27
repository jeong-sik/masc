type cluster = {
  start_offset : int;
  end_offset : int;
  cell_width : int;
}

let[@inline] printable_ascii byte = byte >= ' ' && byte <= '~'

let utf8_scalar_byte_length first =
  let byte = Char.code first in
  if byte < 0x80 then Some 1
  else if byte >= 0xC2 && byte <= 0xDF then Some 2
  else if byte >= 0xE0 && byte <= 0xEF then Some 3
  else if byte >= 0xF0 && byte <= 0xF4 then Some 4
  else None

let rec is_all_printable_ascii_loop text len i =
  if i >= len then true
  else if printable_ascii (String.unsafe_get text i) then
    is_all_printable_ascii_loop text len (i + 1)
  else false

let[@inline] is_all_printable_ascii text =
  is_all_printable_ascii_loop text (String.length text) 0

(* True iff (b0, b1) encodes a width-1 non-combining, non-ignorable Latin-1
   Supplement scalar (U+00A0..U+00FF excluding © U+00A9, soft hyphen U+00AD,
   and ® U+00AE). Verified against Uucp: tty_width_hint = 1,
   grapheme_cluster_break = XX, default_ignorable = false, emoji = false. *)
let[@inline] is_simple_latin1_utf8 b0 b1 =
  (b0 = 0xC2 && b1 >= 0xA0 && b1 <= 0xBF && b1 <> 0xA9 && b1 <> 0xAD && b1 <> 0xAE)
  || (b0 = 0xC3 && b1 >= 0x80 && b1 <= 0xBF)

(* True iff [code] (in 0x2000..0x2FFF, UTF-8 lead 0xE2) is a single-width
   non-combining UI/math/box symbol. Verified against Uucp: tty_width_hint = 1,
   grapheme_cluster_break = XX, default_ignorable = false,
   emoji_presentation = false. Strings containing variation selectors or ZWJ
   are rejected by [is_simple_ascii_or_cjk_hangul], so none of these can form
   multi-scalar clusters in the fast path. *)
let[@inline] is_simple_width1_symbol code =
  code = 0x2013
  || code = 0x2014
  || code = 0x2016
  || code = 0x2018
  || code = 0x2019
  || code = 0x201C
  || code = 0x201D
  || code = 0x2022
  || code = 0x2026
  || code = 0x2039
  || code = 0x203A
  || (code >= 0x2190 && code <= 0x2199)
  || code = 0x21B3
  || code = 0x21B5
  || code = 0x21BB
  || code = 0x2212
  || code = 0x2248
  || code = 0x2260
  || code = 0x2264
  || code = 0x2265
  || code = 0x2295
  || code = 0x2298
  || code = 0x22EF
  || (code >= 0x2460 && code <= 0x2473)
  || (code >= 0x2500 && code <= 0x25FC)
  || code = 0x2605
  || code = 0x2606
  || code = 0x270E
  || (code >= 0x2713 && code <= 0x2727)

(* True iff [code] (UTF-8 lead 0xE3..0xED) is a width-2 non-combining CJK/Hangul
   scalar: precomposed Hangul syllable (U+AC00..U+D7A3), CJK Unified Ideograph
   (U+4E00..U+9FFF), or Uucp-verified width-2 CJK punctuation (U+3000..U+3011,
   U+30FB, U+30FC). *)
let[@inline] is_simple_width2_cjk code =
  (code >= 0xAC00 && code <= 0xD7A3)
  || (code >= 0x4E00 && code <= 0x9FFF)
  || (code >= 0x3000 && code <= 0x3011)
  || code = 0x30FB
  || code = 0x30FC

(* True iff every scalar in [text] is printable ASCII (0x20..0x7E),
   a simple Latin-1 symbol, a common width-1 non-combining UI symbol,
   precomposed Hangul syllable, CJK Unified Ideograph, or width-2 CJK
   punctuation. Under UAX #29 none of these combine with each other, so each
   scalar is its own grapheme cluster of width 1 or 2 and requires no control
   sanitization. *)
let rec is_simple_ascii_or_cjk_hangul_loop text len i =
  if i >= len then true
  else
    let b0 = Char.code (String.unsafe_get text i) in
    if b0 >= 0x20 && b0 <= 0x7E then
      is_simple_ascii_or_cjk_hangul_loop text len (i + 1)
    else if (b0 = 0xC2 || b0 = 0xC3) && i + 1 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      if is_simple_latin1_utf8 b0 b1 then
        is_simple_ascii_or_cjk_hangul_loop text len (i + 2)
      else false
    else if b0 >= 0xE2 && b0 <= 0xED && i + 2 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      let b2 = Char.code (String.unsafe_get text (i + 2)) in
      if (b1 land 0xC0) = 0x80 && (b2 land 0xC0) = 0x80 then
        let code =
          ((b0 land 0x0F) lsl 12) lor ((b1 land 0x3F) lsl 6) lor (b2 land 0x3F)
        in
        if (if b0 = 0xE2 then is_simple_width1_symbol code
            else is_simple_width2_cjk code)
        then is_simple_ascii_or_cjk_hangul_loop text len (i + 3)
        else false
      else false
    else false

let is_simple_ascii_or_cjk_hangul text =
  is_simple_ascii_or_cjk_hangul_loop text (String.length text) 0

let vs16 = Uchar.of_int 0xFE0F
let vs15 = Uchar.of_int 0xFE0E
let zwj = Uchar.of_int 0x200D
let skin_tone_first = 0x1F3FB
let skin_tone_last = 0x1F3FF
let tag_first = 0xE0020
let tag_last = 0xE007F

let scalar_width scalar =
  let code = Uchar.to_int scalar in
  if code >= 0x20 && code <= 0x7E then 1
  else if code < 0x20 || (code >= 0x7F && code <= 0x9F) then 0
  else if (code >= 0xAC00 && code <= 0xD7A3) || (code >= 0x4E00 && code <= 0x9FFF)
  then 2
  else if Uucp.Func.is_regional_indicator scalar then 1
  else if Uucp.Emoji.is_emoji_presentation scalar then 2
  else Int.max 0 (Uucp.Break.tty_width_hint scalar)

let widens_emoji_cluster scalar =
  let code = Uchar.to_int scalar in
  Uchar.equal scalar vs16
  || Uchar.equal scalar zwj
  || (code >= skin_tone_first && code <= skin_tone_last)
  || (code >= tag_first && code <= tag_last)

let narrows_emoji_cluster scalar = Uchar.equal scalar vs15

(* Skip an ANSI CSI (ESC [ ... final) or OSC (ESC ] ... BEL/ST) sequence if
   present at [offset], so untrusted escape payloads are stripped cleanly. *)
let skip_ansi_escape text offset =
  let len = String.length text in
  if offset + 1 >= len || text.[offset] <> '\x1b' then offset + 1
  else
    match text.[offset + 1] with
    | '[' ->
        let rec scan i =
          if i >= len then len
          else
            let b = Char.code text.[i] in
            if b >= 0x40 && b <= 0x7E then i + 1
            else if b >= 0x20 && b <= 0x3F then scan (i + 1)
            else i
        in
        scan (offset + 2)
    | ']' | '_' ->
        let rec scan i =
          if i >= len then len
          else if text.[i] = '\x07' then i + 1
          else if text.[i] = '\x1b' && i + 1 < len && text.[i + 1] = '\\' then
            i + 2
          else scan (i + 1)
        in
        scan (offset + 2)
    | _ -> offset + 1

let continues_pictograph scalar =
  Uchar.equal scalar vs15
  || Uchar.equal scalar vs16
  || Uucp.Emoji.is_emoji_modifier scalar

let opens_pictograph text offset =
  if offset >= String.length text then false
  else
    let decoded = String.get_utf_8_uchar text offset in
    Uchar.utf_decode_is_valid decoded
    && Uucp.Emoji.is_extended_pictographic (Uchar.utf_decode_uchar decoded)

let keeps_selector ~base scalar =
  (Uchar.equal scalar vs15 || Uchar.equal scalar vs16)
  && Uucp.Emoji.is_emoji base
  && not (Uucp.Emoji.is_emoji_presentation base)

let sanitize_controls text =
  if is_simple_ascii_or_cjk_hangul text then text
  else
    let len = String.length text in
    let buf = Buffer.create len in
    let rec walk offset ~after_pictograph ~base =
      if offset < len then
        let byte = Char.code text.[offset] in
        if byte = 0x1B then
          walk (skip_ansi_escape text offset) ~after_pictograph:false ~base:None
        else if byte < 0x20 || byte = 0x7F then
          walk (offset + 1) ~after_pictograph:false ~base:None
        else if byte < 0x80 then begin
          Buffer.add_char buf text.[offset];
          walk (offset + 1) ~after_pictograph:false
            ~base:(Some (Uchar.of_int byte))
        end
        else
          let decoded = String.get_utf_8_uchar text offset in
          let step = Int.max 1 (Uchar.utf_decode_length decoded) in
          if not (Uchar.utf_decode_is_valid decoded) then
            walk (offset + step) ~after_pictograph:false ~base:None
          else
            let scalar = Uchar.utf_decode_uchar decoded in
            let code = Uchar.to_int scalar in
            if code >= 0x80 && code <= 0x9F then
              (* C1 control character: strip *)
              walk (offset + step) ~after_pictograph:false ~base:None
            else if (code >= 0xAC00 && code <= 0xD7A3) || (code >= 0x4E00 && code <= 0x9FFF) then begin
              Buffer.add_substring buf text offset step;
              walk (offset + step) ~after_pictograph:false ~base:(Some scalar)
            end
            else
              let is_ignorable = Uucp.Gen.is_default_ignorable scalar in
              let joins_pictographs =
                Uchar.equal scalar zwj
                && after_pictograph
                && opens_pictograph text (offset + step)
              in
              let selects_base =
                Uucp.Gen.is_variation_selector scalar
                &&
                match base with
                | Some b -> keeps_selector ~base:b scalar
                | None -> false
              in
              if is_ignorable && not (joins_pictographs || selects_base) then
                walk (offset + step) ~after_pictograph:false ~base:None
              else begin
                Buffer.add_substring buf text offset step;
                let next_base = if not is_ignorable then Some scalar else None in
                let next_pic =
                  if Uucp.Emoji.is_extended_pictographic scalar then true
                  else if continues_pictograph scalar || joins_pictographs then
                    after_pictograph
                  else false
                in
                walk (offset + step) ~after_pictograph:next_pic ~base:next_base
              end
    in
    walk 0 ~after_pictograph:false ~base:None;
    Buffer.contents buf

let iter_sanitized_clusters text f =
  let len = String.length text in
  if len = 0 then ()
  else if is_all_printable_ascii text then
    for i = 0 to len - 1 do
      f ~start_offset:i ~end_offset:(i + 1) ~cell_width:1
    done
  else if is_simple_ascii_or_cjk_hangul text then
    let rec loop i =
      if i < len then
        let b0 = Char.code (String.unsafe_get text i) in
        if b0 < 0x80 then begin
          f ~start_offset:i ~end_offset:(i + 1) ~cell_width:1;
          loop (i + 1)
        end
        else if b0 = 0xC2 || b0 = 0xC3 then begin
          f ~start_offset:i ~end_offset:(i + 2) ~cell_width:1;
          loop (i + 2)
        end
        else if b0 = 0xE2 then begin
          f ~start_offset:i ~end_offset:(i + 3) ~cell_width:1;
          loop (i + 3)
        end
        else begin
          f ~start_offset:i ~end_offset:(i + 3) ~cell_width:2;
          loop (i + 3)
        end
    in
    loop 0
  else
    let segmenter = Uuseg.create `Grapheme_cluster in
    let cluster_start = ref 0 in
    let cluster_end = ref 0 in
    let width = ref 0 in
    let widest = ref 0 in
    let hangul_l = ref false in
    let hangul_vt = ref false in
    let emoji_base = ref false in
    let emoji_wide = ref false in
    let emoji_text = ref false in
    let close_cluster () =
      if !cluster_end > !cluster_start then begin
        let cells =
          if !emoji_base && !emoji_wide then 2
          else if !emoji_base && !emoji_text then 1
          else if !hangul_l && !hangul_vt then !widest
          else Int.min 2 !width
        in
        if cells > 0 then
          f ~start_offset:!cluster_start ~end_offset:!cluster_end ~cell_width:cells;
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
      let sw = scalar_width scalar in
      width := !width + sw;
      widest := Int.max !widest sw;
      let ht = Uucp.Hangul.syllable_type scalar in
      hangul_l := !hangul_l || ht = `L;
      hangul_vt := !hangul_vt || ht = `V || ht = `T;
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
    let rec feed offset =
      if offset >= len then begin
        drain `End;
        close_cluster ()
      end
      else
        let decoded = String.get_utf_8_uchar text offset in
        let step = Int.max 1 (Uchar.utf_decode_length decoded) in
        if Uchar.utf_decode_is_valid decoded then begin
          drain (`Uchar (Uchar.utf_decode_uchar decoded));
          feed (offset + step)
        end
        else begin
          close_cluster ();
          cluster_start := offset + step;
          cluster_end := offset + step;
          feed (offset + step)
        end
    in
    feed 0

let iter_clusters text f =
  let clean = sanitize_controls text in
  iter_sanitized_clusters clean (fun ~start_offset ~end_offset ~cell_width ->
      f ~text:clean ~start_offset ~end_offset ~cell_width)

let segment text =
  let clean = sanitize_controls text in
  let acc = ref [] in
  iter_sanitized_clusters clean (fun ~start_offset ~end_offset ~cell_width ->
      acc := { start_offset; end_offset; cell_width } :: !acc);
  (clean, List.rev !acc)

let split_clusters text =
  let clean = sanitize_controls text in
  let acc = ref [] in
  iter_sanitized_clusters clean (fun ~start_offset ~end_offset ~cell_width ->
      let s = String.sub clean start_offset (end_offset - start_offset) in
      acc := (s, cell_width) :: !acc);
  List.rev !acc

let rec fast_display_width_loop text len i w =
  if i >= len then w
  else
    let b0 = Char.code (String.unsafe_get text i) in
    if b0 >= 0x20 && b0 <= 0x7E then fast_display_width_loop text len (i + 1) (w + 1)
    else if (b0 = 0xC2 || b0 = 0xC3) && i + 1 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      if is_simple_latin1_utf8 b0 b1 then
        fast_display_width_loop text len (i + 2) (w + 1)
      else -1
    else if b0 >= 0xE2 && b0 <= 0xED && i + 2 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      let b2 = Char.code (String.unsafe_get text (i + 2)) in
      if (b1 land 0xC0) = 0x80 && (b2 land 0xC0) = 0x80 then
        let code =
          ((b0 land 0x0F) lsl 12) lor ((b1 land 0x3F) lsl 6) lor (b2 land 0x3F)
        in
        if b0 = 0xE2 then
          if is_simple_width1_symbol code then
            fast_display_width_loop text len (i + 3) (w + 1)
          else -1
        else if is_simple_width2_cjk code then
          fast_display_width_loop text len (i + 3) (w + 2)
        else -1
      else -1
    else -1

let display_width text =
  let len = String.length text in
  if len = 0 then 0
  else
    let w = fast_display_width_loop text len 0 0 in
    if w >= 0 then w
    else
      let clean = sanitize_controls text in
      let total = ref 0 in
      iter_sanitized_clusters clean (fun ~start_offset:_ ~end_offset:_ ~cell_width ->
          total := !total + cell_width);
      !total

let default_ellipsis = "…"

let[@inline] resolve_ellipsis ellipsis =
  if ellipsis == default_ellipsis || String.equal ellipsis default_ellipsis then
    (default_ellipsis, 1)
  else if String.length ellipsis = 0 then ("", 0)
  else
    let ell = sanitize_controls ellipsis in
    (ell, display_width ell)

(* Fast single-pass scan for simple ASCII / UI-symbol / Hangul / CJK strings.
   Returns:
     -1 : entire string is simple and fits within [max_width] (return [text] as-is)
     -2 : non-simple byte encountered before exceeding [max_width] (use fallback)
     >= 0 : byte offset [cut_off] where [text] exceeded [max_width] *)
let rec truncate_fast_scan text len max_width budget i w cut_off =
  if i >= len then -1
  else
    let b0 = Char.code (String.unsafe_get text i) in
    if b0 >= 0x20 && b0 <= 0x7E then
      let next_w = w + 1 in
      if next_w > max_width then cut_off
      else
        let next_cut = if next_w <= budget then i + 1 else cut_off in
        truncate_fast_scan text len max_width budget (i + 1) next_w next_cut
    else if (b0 = 0xC2 || b0 = 0xC3) && i + 1 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      if is_simple_latin1_utf8 b0 b1 then
        let next_w = w + 1 in
        if next_w > max_width then cut_off
        else
          let next_cut = if next_w <= budget then i + 2 else cut_off in
          truncate_fast_scan text len max_width budget (i + 2) next_w next_cut
      else -2
    else if b0 >= 0xE2 && b0 <= 0xED && i + 2 < len then
      let b1 = Char.code (String.unsafe_get text (i + 1)) in
      let b2 = Char.code (String.unsafe_get text (i + 2)) in
      if (b1 land 0xC0) = 0x80 && (b2 land 0xC0) = 0x80 then
        let code =
          ((b0 land 0x0F) lsl 12)
          lor ((b1 land 0x3F) lsl 6)
          lor (b2 land 0x3F)
        in
        if b0 = 0xE2 then
          if is_simple_width1_symbol code then
            let next_w = w + 1 in
            if next_w > max_width then cut_off
            else
              let next_cut = if next_w <= budget then i + 3 else cut_off in
              truncate_fast_scan text len max_width budget (i + 3) next_w next_cut
          else -2
        else if is_simple_width2_cjk code then
          let next_w = w + 2 in
          if next_w > max_width then cut_off
          else
            let next_cut = if next_w <= budget then i + 3 else cut_off in
            truncate_fast_scan text len max_width budget (i + 3) next_w next_cut
        else -2
      else -2
    else -2

let truncate_to_width ~max_width ?(ellipsis = default_ellipsis) text =
  if max_width <= 0 then ""
  else
    let len = String.length text in
    if len = 0 then ""
    else
      let ell, ell_w =
        if ellipsis == default_ellipsis then (default_ellipsis, 1)
        else resolve_ellipsis ellipsis
      in
      let budget = max_width - ell_w in
      let res = truncate_fast_scan text len max_width budget 0 0 0 in
      if res = -1 then text
      else if res >= 0 then
        if ell_w > max_width then ""
        else if res = 0 then ell
        else if String.length ell = 0 then String.sub text 0 res
        else String.sub text 0 res ^ ell
      else
        let clean = sanitize_controls text in
        if is_all_printable_ascii clean then
          if String.length clean <= max_width then clean
          else if ell_w > max_width then ""
          else if String.length ell = 0 then String.sub clean 0 budget
          else String.sub clean 0 budget ^ ell
        else
          let total_w =
            let w = ref 0 in
            iter_sanitized_clusters clean
              (fun ~start_offset:_ ~end_offset:_ ~cell_width -> w := !w + cell_width);
            !w
          in
          if total_w <= max_width then clean
          else if ell_w > max_width then ""
          else
            let cut_offset = ref 0 in
            let used = ref 0 in
            let exception Stop_trunc in
            (try
               iter_sanitized_clusters clean
                 (fun ~start_offset:_ ~end_offset ~cell_width ->
                   if !used + cell_width <= budget then begin
                     used := !used + cell_width;
                     cut_offset := end_offset
                   end
                   else raise_notrace Stop_trunc)
             with Stop_trunc -> ());
            if !cut_offset = 0 then ell
            else if String.length ell = 0 then String.sub clean 0 !cut_offset
            else String.sub clean 0 !cut_offset ^ ell

let pad_right ~width text =
  if width <= 0 then ""
  else
    let fitted = truncate_to_width ~max_width:width text in
    let w = display_width fitted in
    if w >= width then fitted else fitted ^ String.make (width - w) ' '
