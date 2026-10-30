(** Relevance order for wiki search. Pure: texts go in, numbers come out.

    Which pages match a query is decided elsewhere, by substring containment
    ({!Tool_wiki}). This module only orders the pages that matched, so a page
    that is mostly about the query comes before one that mentions it once.

    The score is Okapi BM25 (Robertson and Zaragoza, "The Probabilistic
    Relevance Framework: BM25 and Beyond", 2009) over the pages of one wiki. It
    is computed on the spot from the texts it is given. There is no stored
    index, so nothing can disagree with the pages.

    Words are cut without a dictionary. A run of ASCII letters and digits is one
    word, lowercased. A run of other letters, Hangul among them, becomes
    two-character pieces, so a two-character Korean word is a term of its own
    and a suffix such as the particle in "박자가" does not hide its stem. *)

val terms : string -> string list
(** [terms text] is the words of [text] in reading order, repeats kept. It is
    total: bytes that are not valid UTF-8 separate words and are dropped. A run
    of one non-ASCII letter is that letter; a longer run is each pair of
    neighbouring letters. Punctuation and spaces, ASCII or not, separate. *)

val scores : query:string -> string list -> float list
(** [scores ~query texts] is one BM25 score per text, in the order of [texts].
    The texts are the whole corpus: document frequency and average length are
    taken over them. A text holding none of the query's terms scores [0.0], and
    so does every text when the query has no term or the corpus has no word.
    Higher is closer. *)
