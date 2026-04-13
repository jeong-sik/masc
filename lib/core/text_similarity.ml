module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(** Text_similarity — pure text similarity functions.

    Lowercase + strip, word tokenization, byte-level n-gram extraction,
    and combined word + n-gram Jaccard similarity.

    These functions have no external dependencies beyond Stdlib. *)

(** Strip non-alphanumeric ASCII, keep multibyte (CJK, etc.) and digits.
    Returns a cleaned lowercase string for tokenization. *)
let clean_for_similarity (s : string) : string =
  let s = String.lowercase_ascii s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let code = Char.code c in
    let keep =
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      code >= 128
    in
    if not keep then Bytes.set b i ' '
  done;
  Bytes.to_string b

(** Extract unique word tokens (space-split, length >= 2). *)
let normalize_for_similarity (s : string) : string list =
  let cleaned = clean_for_similarity s in
  let words =
    cleaned
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w >= 2)
  in
  let seen = ref StringSet.empty in
  List.filter (fun w ->
    if StringSet.mem w !seen then false
    else (seen := StringSet.add w !seen; true)
  ) words

(** Extract character n-grams from a cleaned string.
    For multibyte strings (Korean, CJK), each "character" may be multiple bytes.
    We use byte-level n-grams which naturally captures morpheme overlap
    for UTF-8 encoded text (Korean 3 bytes/char → 3-byte-gram captures
    individual syllables, 6-byte-gram captures 2-syllable morphemes).

    Returns a deduplicated list of n-grams. *)
let char_ngrams ~(n : int) (s : string) : string list =
  let cleaned = clean_for_similarity s in
  (* Remove spaces for n-gram extraction *)
  let buf = Buffer.create (String.length cleaned) in
  String.iter (fun c -> if c <> ' ' then Buffer.add_char buf c) cleaned;
  let compact = Buffer.contents buf in
  let len = String.length compact in
  if len < n then (if len > 0 then [compact] else [])
  else
    let seen = ref StringSet.empty in
    let acc = ref [] in
    for i = 0 to len - n do
      let gram = String.sub compact i n in
      if not (StringSet.mem gram !seen) then begin
        seen := StringSet.add gram !seen;
        acc := gram :: !acc
      end
    done;
    List.rev !acc

(** Jaccard similarity over a combined feature set: word tokens + character n-grams.
    Word tokens capture exact matches; n-grams capture partial/morphological overlap.
    This is effective for Korean where "기억해" and "기억나" share the morpheme "기억"
    but would score 0 on word-level Jaccard.

    Uses 3-byte grams (captures Korean syllables) and 6-byte grams (captures
    2-syllable Korean morphemes) alongside word tokens. *)
let jaccard_similarity (a : string) (b : string) : float =
  let words_a = normalize_for_similarity a in
  let words_b = normalize_for_similarity b in
  let ngrams_a = char_ngrams ~n:3 a @ char_ngrams ~n:6 a in
  let ngrams_b = char_ngrams ~n:3 b @ char_ngrams ~n:6 b in
  let ta = words_a @ ngrams_a in
  let tb = words_b @ ngrams_b in
  if ta = [] && tb = [] then 1.0
  else if ta = [] || tb = [] then 0.0
  else
    let h = List.fold_left (fun m w -> StringMap.add w false m) StringMap.empty ta in
    let inter, uniq_b =
      List.fold_left (fun (inter, uniq_b) w ->
        match StringMap.find_opt w h with
        | Some false -> (inter + 1, uniq_b)
        | Some true -> (inter, uniq_b)
        | None -> (inter, uniq_b + 1)
      ) (0, 0) tb in
    let union = (List.length ta) + uniq_b in
    if union = 0 then 0.0 else float_of_int inter /. float_of_int union
