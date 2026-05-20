(** Source-word metadata for keeper command path validation.

    The word splitter lives with the Bash parser so worker-side path
    validation does not keep a private shell tokenizer. *)

type t = Masc_exec_bash_parser.Bash_words.word =
  { value : string
  ; quoted : bool
  ; escaped : bool
  ; globbed : bool
  ; braced : bool
  }

let has_unsafe_rewrite_syntax word = word.quoted || word.escaped || word.braced

let of_literal value =
  { value; quoted = false; escaped = false; globbed = false; braced = false }
;;

let stages = Masc_exec_bash_parser.Bash_words.stages
