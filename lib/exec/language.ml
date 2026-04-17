(** Language — functor boundary between Layer 1 (parser) and Layer 2
    (capability extraction).

    A0 ships the signature only.  Bash is the first and currently only
    instantiation; a second language (e.g. Python or SQL for
    cross-language injection) can be plugged in Phase B without
    touching the capability check layer. *)

module type LANGUAGE = sig
  (** Source-language name for diagnostics. *)
  val name : string

  (** Frontend output type for this language.  For bash this is
      [Shell_ir.t]; other languages would expose their own subset AST. *)
  type ast

  (** Parse a source string.  [`Parse_error], [`Parse_aborted] and
      [`Too_complex] follow [Parsed.t] conventions. *)
  val parse_string : string -> ast Parsed.t
end
