(* Recovered verbatim from oas 902c45d2 lib/llm_provider/text_estimate.ml
   (dropped in OAS 0.212.0). CJK-aware token estimation:

   ASCII: ~4 chars per token (standard "1 token ≈ 4 characters" rule for
   English/Latin text).
   Multi-byte (CJK, emoji, Cyrillic, ...): ~2/3 token per character
   (tuned against real tokenizers — Hangul and CJK ideographs typically
   tokenize to 1-2 tokens per visible character).

   Walks the input byte-by-byte, classifying each UTF-8 lead byte by its
   high bits; continuation bytes are skipped via the lead byte's width.
   O(n), no allocation. Returns >= 1 for any input; the empty string
   returns 1 (avoid zero in downstream divisions). *)
let estimate_char_tokens (s : string) : int =
  let len = String.length s in
  let rec loop i ascii multi =
    if i >= len
    then max 1 (((ascii + 3) / 4) + (((multi * 2) + 2) / 3))
    else (
      let byte = Char.code (String.unsafe_get s i) in
      if byte < 0x80
      then loop (i + 1) (ascii + 1) multi
      else (
        let skip = if byte >= 0xF0 then 4 else if byte >= 0xE0 then 3 else 2 in
        loop (i + skip) ascii (multi + 1)))
  in
  if len = 0 then 1 else loop 0 0 0
;;
