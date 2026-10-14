(* Wiki_rank: BM25 over the pages of one wiki. See the interface. *)

(* Robertson and Zaragoza (2009), section 3.2: k1 between 1.2 and 2.0 and
   b = 0.75 are the usual starting values. Pages are short and of one author,
   so neither is tuned here. *)
let term_frequency_saturation = 1.2
let length_normalization = 0.75

(* Code points that separate words instead of belonging to one. *)
let separator_ranges =
  [ 0x0080, 0x00BF (* C1 controls, no-break space, Latin-1 punctuation *)
  ; 0x2000, 0x206F (* general punctuation, em dash among it *)
  ; 0x3000, 0x303F (* CJK symbols and punctuation, ideographic space *)
  ; 0xFF00, 0xFF0F (* full-width forms up to the full-width slash *)
  ]

let is_separator code_point =
  List.exists (fun (low, high) -> code_point >= low && code_point <= high) separator_ranges

let is_ascii_word_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | _ -> false

(* Length of the UTF-8 sequence a lead byte opens; 0 when it opens none. *)
let utf8_length lead =
  let code = Char.code lead in
  if code >= 0xC2 && code <= 0xDF
  then 2
  else if code >= 0xE0 && code <= 0xEF
  then 3
  else if code >= 0xF0 && code <= 0xF4
  then 4
  else 0

let is_continuation byte = Char.code byte land 0xC0 = 0x80

(* The code point of the [length]-byte sequence at [at]. The caller has checked
   that the lead byte and the continuation bytes are all there. *)
let decode text at length =
  let lead_mask =
    match length with
    | 2 -> 0x1F
    | 3 -> 0x0F
    | _ -> 0x07
  in
  let rec go code_point offset =
    if offset = length
    then code_point
    else go ((code_point lsl 6) lor (Char.code text.[at + offset] land 0x3F)) (offset + 1)
  in
  go (Char.code text.[at] land lead_mask) 1

type piece =
  | Word_char of char (* an ASCII letter or digit, lowercased *)
  | Wide_char of string (* one non-ASCII letter, its UTF-8 bytes *)
  | Break

let pieces text =
  let length = String.length text in
  let rec go at acc =
    if at >= length
    then List.rev acc
    else (
      let byte = text.[at] in
      if Char.code byte < 0x80
      then (
        let piece =
          if is_ascii_word_char byte then Word_char (Char.lowercase_ascii byte) else Break
        in
        go (at + 1) (piece :: acc))
      else (
        let size = utf8_length byte in
        let rec continuations k = k >= size || (is_continuation text.[at + k] && continuations (k + 1)) in
        if size = 0 || at + size > length || not (continuations 1)
        then go (at + 1) (Break :: acc)
        else (
          let piece =
            if is_separator (decode text at size)
            then Break
            else Wide_char (String.sub text at size)
          in
          go (at + size) (piece :: acc))))
  in
  go 0 []

let terms text =
  let word = Buffer.create 16 in
  let wide = ref [] in
  let out = ref [] in
  let end_word () =
    if Buffer.length word > 0
    then (
      out := Buffer.contents word :: !out;
      Buffer.clear word)
  in
  let end_wide () =
    (match List.rev !wide with
     | [] -> ()
     | [ one ] -> out := one :: !out
     | letters ->
       let rec pairs = function
         | first :: (second :: _ as rest) ->
           out := (first ^ second) :: !out;
           pairs rest
         | _ -> ()
       in
       pairs letters);
    wide := []
  in
  List.iter
    (function
      | Word_char c ->
        end_wide ();
        Buffer.add_char word c
      | Wide_char letter ->
        end_word ();
        wide := letter :: !wide
      | Break ->
        end_word ();
        end_wide ())
    (pieces text);
  end_word ();
  end_wide ();
  List.rev !out

let counts_of terms =
  let table = Hashtbl.create 64 in
  List.iter
    (fun term ->
       Hashtbl.replace table term (1 + Option.value ~default:0 (Hashtbl.find_opt table term)))
    terms;
  table

let scores ~query texts =
  let documents = List.map terms texts in
  let lengths = List.map List.length documents in
  let corpus_size = List.length documents in
  let total_length = List.fold_left ( + ) 0 lengths in
  let query_terms = List.sort_uniq String.compare (terms query) in
  match query_terms with
  | _ when corpus_size = 0 || total_length = 0 -> List.map (fun _ -> 0.0) texts
  | [] -> List.map (fun _ -> 0.0) texts
  | _ :: _ ->
    let average_length = float_of_int total_length /. float_of_int corpus_size in
    let tables = List.map counts_of documents in
    let document_frequency term =
      List.fold_left
        (fun seen table -> if Hashtbl.mem table term then seen + 1 else seen)
        0
        tables
    in
    (* The non-negative form of the inverse document frequency (Lucene's), so a
       term found in every page weighs little instead of less than nothing. *)
    let inverse_document_frequency term =
      let seen = float_of_int (document_frequency term) in
      log (1.0 +. ((float_of_int corpus_size -. seen +. 0.5) /. (seen +. 0.5)))
    in
    let weighted = List.map (fun term -> term, inverse_document_frequency term) query_terms in
    List.map2
      (fun table length ->
         let normalization =
           term_frequency_saturation
           *. (1.0
               -. length_normalization
               +. (length_normalization *. float_of_int length /. average_length))
         in
         List.fold_left
           (fun score (term, weight) ->
              match Hashtbl.find_opt table term with
              | None -> score
              | Some count ->
                let count = float_of_int count in
                score
                +. (weight *. ((term_frequency_saturation +. 1.0) *. count) /. (count +. normalization)))
           0.0
           weighted)
      tables
      lengths
