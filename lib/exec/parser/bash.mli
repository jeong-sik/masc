(** Public entry point for the Bash subset parser.

    [parse_string s] feeds [s] through the Menhir grammar and returns
    a [Shell_ir.t Parsed.t]. The subset accepts literal arguments with
    quote metadata, command substitutions in argument and assignment-value
    positions, pipelines, command sequences, literal environment assignments,
    fd-to-fd and file redirects, and quoted literal heredocs. Variable
    expansions are outside the accepted subset.

    Each call owns its token/piece counter. Nested command substitutions
    share that counter and the existing 50,000 limit; a fresh public call
    starts a fresh counter.

    Lexer exclusions become [Parsed.Too_complex _], token-limit failures
    become [Parsed.Parse_aborted `Token_limit_50k], and Menhir syntax errors
    or lexer [Failure] become [Parsed.Parse_error _]. A nested substitution's
    refusal is returned unchanged. *)

val parse_string : string -> Masc_exec.Shell_ir.t Masc_exec.Parsed.t
