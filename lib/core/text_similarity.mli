(** Text_similarity — pure text similarity functions.

    Lowercase + strip, word tokenization, byte-level n-gram extraction,
    and combined word + n-gram Jaccard similarity.

    These functions have no external dependencies beyond Stdlib. *)

(** Strip non-alphanumeric ASCII, keep multibyte (CJK, etc.) and digits.
    Returns a cleaned lowercase string for tokenization. *)
val clean_for_similarity : string -> string

(** Extract unique word tokens (space-split, length >= 2). *)
val normalize_for_similarity : string -> string list

(** Extract character n-grams from a cleaned string.
    Byte-level n-grams capture morpheme overlap for UTF-8 text
    (Korean 3 bytes/char, CJK 3 bytes/char).
    Returns a deduplicated list of n-grams. *)
val char_ngrams : n:int -> string -> string list

(** Jaccard similarity over combined word tokens + character n-grams.
    Uses 3-byte and 6-byte grams alongside word tokens. *)
val jaccard_similarity : string -> string -> float
