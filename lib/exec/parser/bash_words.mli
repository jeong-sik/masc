(** Quote-aware shell word metadata used by policy surfaces that need
    source-shape information which {!Masc_exec.Shell_ir.Lit} intentionally
    does not carry.

    This module is not an execution parser.  It shares the bash-subset
    lexical boundary and returns ordered pipeline stages so path policy can
    make quote/glob/brace decisions without keeping a private tokenizer in
    caller modules. *)

type word = {
  value : string;
  quoted : bool;
  escaped : bool;
  globbed : bool;
  braced : bool;
}

type error =
  | Unclosed_quote
  | Trailing_escape

val stages : string -> (word list list, error) result
(** Tokenize [source] into non-empty command stages split on unquoted [|].
    Empty stages are omitted so callers can remain fail-closed at their own
    command-shape layer while still reusing successfully recovered words for
    diagnostics and path policy. *)
