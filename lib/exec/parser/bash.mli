(** A1 parser facade — public entry point.

    [parse_string s] feeds [s] through the Menhir grammar and returns
    a [Shell_ir.t Parsed.t]. The current subset accepts simple
    commands, literal argv quoting, pipelines, leading environment
    assignments, fd-to-fd redirects, and file redirects. Unsupported
    forms — command substitution, process substitution, heredocs,
    control flow, background jobs, and unsupported shell expansions —
    surface as [Parsed.Parse_error] or [Parsed.Too_complex _].

    The parser never raises.  Lexer [Failure], Menhir [Parser.Error],
    and token-budget/depth aborts are all caught and mapped to the
    appropriate [Parsed.t] arm. *)

val parse_string : string -> Masc_exec.Shell_ir.t Masc_exec.Parsed.t
