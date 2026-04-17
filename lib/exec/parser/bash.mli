(** A1 parser facade — public entry point.

    [parse_string s] feeds [s] through the Menhir grammar and returns
    a [Shell_ir.t Parsed.t].  The A1-PR-1 skeleton accepts only simple
    commands (bin plus literal args, unquoted).  Anything else — pipe,
    redirect, env prefix, quotes, $(…), heredoc, control flow —
    surfaces as [Parsed.Parse_error] today and is upgraded to a
    [Parsed.Too_complex _] variant in follow-up PRs.

    The parser never raises.  Lexer [Failure], Menhir [Parser.Error],
    and token-budget/depth aborts are all caught and mapped to the
    appropriate [Parsed.t] arm. *)

val parse_string : string -> Masc_exec.Shell_ir.t Masc_exec.Parsed.t
