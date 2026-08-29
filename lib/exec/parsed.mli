(** Parsed — four-way result of the bash subset parser.

    [Too_complex] is deliberately a polymorphic variant so the corpus
    tap can aggregate frequencies per construct type after the
    observation window (e.g. ["Cmd_subst > 30%"] -> promote in
    Phase B). Pure type-SSOT module; no value surface.

    A [Too_complex] arm is an observation, not a guess: each one is raised by
    the lexer rule that matched the offending lexeme, so the reason names the
    construct the input actually contains. Text that is not a command line at
    all — an unterminated quote, a stray character — is [Parse_error] instead,
    which carries where rather than naming a feature that is not there.

    Three arms have no rule and so no producer. [`Control_flow] and
    [`Function_def] need grammar: [if] and [f()] lex as ordinary words, so a
    script using either is reported by whichever excluded lexeme it does
    reach. [`Unknown_construct] is the refusal RFC execute-subset-dispositions
    §7 holds open. All three are gaps in the rules, visible as gaps, rather
    than tags that quietly mean something else. *)

type reason_aborted =
  [ `Timeout_50ms | `Depth_limit | `Token_limit_50k ]

type reason_too_complex =
  [ `Heredoc
  | `Here_string
  | `Cmd_subst
  | `Proc_subst
  | `Subshell
  | `Arith_expansion
  | `Param_expansion
  | `Control_flow
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
