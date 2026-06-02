(** Parsed — four-way result of the bash subset parser.

    [Too_complex] is deliberately a polymorphic variant so the corpus
    tap can aggregate frequencies per construct type after the
    observation window (e.g. "Cmd_subst > 30% -> promote in Phase B"). *)

type reason_aborted =
  [ `Timeout_50ms | `Depth_limit | `Token_limit_50k ]

type reason_too_complex =
  [ `Heredoc
  | `Here_string
  | `Cmd_subst
  | `Proc_subst
  | `Subshell
  | `Arith_expansion
  | `Control_flow
  | `Logic_op
  | `Function_def
  | `Glob_brace
  | `Background
  | `Redirect
  | `Unknown_construct of string
  ]

type parse_error = {
  pos : Lexing.position;
  token : string;
  expected : string list;
}

type 'a t =
  | Parsed of 'a
  | Parse_error of parse_error
  | Parse_aborted of reason_aborted
  | Too_complex of reason_too_complex
