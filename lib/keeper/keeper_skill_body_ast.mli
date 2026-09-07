(** Minimal, source-located Markdown block AST for Skill runtime semantics.

    Agent Skills deliberately leave Markdown body syntax open.  MASC only
    assigns runtime meaning to top-level fenced code blocks, so this module
    parses exactly that structural boundary instead of pretending the body is
    an opaque string or implementing a second Markdown renderer. *)

type span = private
  { start_line : int
  ; end_line : int
  }

type fenced_code_block = private
  { info : string
  ; body : string
  ; span : span
  ; terminated : bool
  }

type block =
  | Text of span
  | Fenced_code of fenced_code_block

type t = private block list

val parse : string -> t
val fenced_code_blocks : t -> fenced_code_block list
