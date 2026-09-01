(* Bash subset lexer.

   Current token set covers literal argv words, quote-preserving
   words, pipelines, fd-to-fd redirects, and file redirect operators.
   Unsupported shell forms still fail closed through Parsed.Too_complex
   or Parse_error.  See RFC v5 (docs/rfc/RFC-0005). *)

{
  open Bash_subset
  open Masc_exec

  (* Token budget — each lexeme increments a counter.  The 50k ceiling
     is enforced in the lexer so large inputs abort before Menhir builds
     an oversized stage list. *)
  let token_count = ref 0
  let token_limit = 50_000
  exception Token_limit_exceeded

  (* Raised by the rule that matched a construct outside the subset, carrying
     the name of what that rule matched.

     This used to be inferred instead: the parser failed, and a separate pass
     scanned the whole source for the first metacharacter off an ordered list.
     That pass had no case for [$], so every script that combined an expansion
     with a redirect was reported as a redirect -- and told to use the [stdin]
     field, which is not an answer for [>] under any reading. Naming the
     construct here makes the reason a fact about the lexeme that stopped the
     lex, and lets ocamllex's longest match settle [<<<] against [<<] against
     [<], which the ordered list was hand-simulating. *)
  exception Excluded_construct of Parsed.reason_too_complex

  let excluded reason = raise (Excluded_construct reason)
  let reset_tokens () = token_count := 0
  let incr_tokens () =
    incr token_count;
    if !token_count > token_limit then raise Token_limit_exceeded
  ;;
  let get_tokens () = !token_count
  ;;
  let meta_of_string w =
    let has_star = String.contains w '*' in
    let has_qmark = String.contains w '?' in
    let has_backslash = String.contains w '\\' in
    { Shell_ir.quoted = false
    ; glob = has_star || has_qmark
    ; escaped = has_backslash
    }
  ;;

  (* A word is one or more adjacent pieces, and only the lexer can see
     adjacency: whitespace produces no token, so a grammar-side piece
     sequence cannot tell [ls -la] from [FOO=$BAR].  Menhir recorded
     exactly that as a shift/reduce conflict on WORD/PARAM lookahead,
     and the shift glued every argv word into one Concat — every
     multi-word command line parsed as a single word and was refused.
     The pieces are assembled here instead, so the grammar reads one
     token per word.  A word that is a single literal stays WORD; the
     redirect-target rule accepts only WORD, which keeps [> $OUT]
     failing to parse rather than passing unchecked. *)
  let assemble_word first rev_rest =
    match List.rev rev_rest with
    | [] ->
      (match first with
       | Shell_ir.Lit (s, meta) -> WORD (s, meta)
       | piece -> MIXED_WORD piece)
    | rest -> MIXED_WORD (Shell_ir.Concat (first :: rest))
  ;;
}

(* WORD class: printable ASCII minus shell metacharacters that the
   parser must see structurally. *)
let digit = ['0'-'9']
let fd = digit+

let word_char = [^ ' ' '\t' '\n' '\r' '|' '<' '>' '&' ';' '(' ')'
                   '\'' '"' '$' '`' '{' '}' '!']
let word = word_char+

(* Parameter names for the simple expansion forms [$NAME] and [${NAME}].
   A name must start with a letter or underscore — [\$1] is a positional
   parameter, not an environment lookup, so it stays excluded by failing
   to match rather than by being listed somewhere else. *)
let param_start = ['a'-'z' 'A'-'Z' '_']
let param_char = param_start | ['0'-'9']
let param_name = param_start param_char*

(* Prefix for a single shell word that continues with quoted literal
   content, e.g. [--include="*.ml"].  This keeps common argv-shaped
   options inside the typed parser without accepting glob metachars in
   unquoted positions. *)
let word_prefix_char = [^ ' ' '\t' '\n' '\r' '|' '<' '>' '&' ';' '(' ')'
                          '\'' '"' '$' '`' '{' '}' '!']
let word_prefix = word_prefix_char+

(* Single-quote string: literal, no escape processing, no nested
   single quote allowed (bash semantics — there is no way to embed
   a single quote inside a '...' string).  Matched content becomes
   a single WORD token so the existing grammar accepts it in any
   WORD position without change.  Spaces inside quotes are preserved
   verbatim, so arguments like 'commit message' arrive at
   [Exec_program.of_string] / args list as one element. *)
let sq_body = [^ '\'' '\n']*

(* Double-quote string: the subset treats it as a literal whose body
   excludes the metachars bash would interpret inside "..." — variable
   expansion ($FOO, ${FOO}), command substitution (`cmd`, $(cmd)), and
   embedded newlines.  Backslash stays rejected except for [\|], which
   is a common regex literal in rg/grep patterns and is still literal
   under bash double quotes.  Any other excluded char inside the body
   breaks the lex → Parse_error,
   which is the correct fail-closed behavior for the subset.  The most
   common caller shapes (rg "pattern", git commit -m "message",
   echo "hello world") have none of those chars and land as one WORD
   token, mirroring the single-quote rule's space-preservation guarantee.
   Upgrade path: later PR widens dq_body to support escape sequences by
   capturing in a sub-rule that unescapes into a Buffer. *)
let dq_char = [^ '"' '\n' '\\' '$' '`'] | "\\|"
let dq_body = dq_char*

rule token = parse
  | [' ' '\t']+    { token lexbuf }
  | '\n'           { incr_tokens (); Lexing.new_line lexbuf; token lexbuf }
  (* Before [PIPE] and the fd-redirect rules so the two-character
     operators win their own lexemes. A lone [&] stays out of the subset
     and is named `Background by its own rule below. *)
  | "&&"           { incr_tokens (); AND_IF }
  | "||"           { incr_tokens (); OR_IF }
  | ';'            { incr_tokens (); SEMICOLON }
  | '|'            { incr_tokens (); PIPE }
  | (fd as src) ">&" (fd as dst)
                    { incr_tokens (); FD_REDIRECT (int_of_string src, int_of_string dst) }
  | ">&" (fd as dst)
                    { incr_tokens (); FD_REDIRECT (1, int_of_string dst) }
  | (fd as src) "<&" (fd as dst)
                    { incr_tokens (); FD_REDIRECT (int_of_string src, int_of_string dst) }
  | "<&" (fd as dst)
                    { incr_tokens (); FD_REDIRECT (0, int_of_string dst) }
  | (fd as fd) ">>"
                    { incr_tokens (); FILE_REDIRECT_OP (int_of_string fd, Masc_exec.Redirect_scope.Append) }
  | ">>"
                    { incr_tokens (); FILE_REDIRECT_OP (1, Masc_exec.Redirect_scope.Append) }
  | (fd as fd) ">"
                    { incr_tokens (); FILE_REDIRECT_OP (int_of_string fd, Masc_exec.Redirect_scope.Write) }
  | ">"
                    { incr_tokens (); FILE_REDIRECT_OP (1, Masc_exec.Redirect_scope.Write) }
  | (fd as fd) "<"
                    { incr_tokens (); FILE_REDIRECT_OP (int_of_string fd, Masc_exec.Redirect_scope.Read) }
  | "<"
                    { incr_tokens (); FILE_REDIRECT_OP (0, Masc_exec.Redirect_scope.Read) }

  (* Constructs outside the subset, each named by the rule that matches it.
     Longest match orders these against the operators above: [<<<] beats [<<]
     beats [<] without anyone writing that order down. Text that matches
     none of them is not given the name of a neighbouring character; it
     reaches the catch-all at the bottom and becomes a parse error. *)
  | "$(("           { excluded `Arith_expansion }
  | "$("            { excluded `Cmd_subst }
  (* Simple parameter expansion — [$NAME] and [${NAME}] open a word
     whose adjacent pieces [word_tail] collects into one token.  Both
     forms come before the bare ['\$'] exclusion so a name that does
     not follow [param_name] (["\${NAME:-x}"], ["\$1"], ["\$" ...])
     still falls through to it and is refused as Param_expansion,
     keeping the excluded vocabulary closed. *)
  | '$' (param_name as name) {
      incr_tokens ();
      word_tail (Shell_ir.Var (name, meta_of_string name)) [] lexbuf
    }
  | "${" (param_name as name) "}" {
      incr_tokens ();
      word_tail
        (Shell_ir.Var
           (name, { Shell_ir.quoted = false; glob = false; escaped = false }))
        []
        lexbuf
    }
  | '`'             { excluded `Cmd_subst }
  | '$'             { excluded `Param_expansion }
  | "<<<"           { excluded `Here_string }
  | "<<"            { excluded `Heredoc }
  | "<("            { excluded `Proc_subst }
  | ">("            { excluded `Proc_subst }
  (* The redirect forms the grammar above does not spell. [&>] and [&>>] join
     two streams in one operator, [>|] overrides noclobber, [<>] opens for
     both, and [>&-] closes. *)
  | "&>>"           { excluded `Redirect }
  | "&>"            { excluded `Redirect }
  | ">|"            { excluded `Redirect }
  | "<>"            { excluded `Redirect }
  | ">&-"           { excluded `Redirect }
  | "<&-"           { excluded `Redirect }
  | '&'             { excluded `Background }
  | '('             { excluded `Subshell }
  | ')'             { excluded `Subshell }
  | '{'             { excluded `Glob_brace }
  | '}'             { excluded `Glob_brace }
  (* A double-quoted body stops at the first char bash would expand, so the
     quote rules below cannot close and the [$] never reaches the rule above
     on its own. Matching the opening quote through to that char reports the
     expansion instead of the quote that failed to close around it. *)
  | '"' dq_char* '$' { excluded `Param_expansion }
  | '"' dq_char* '`' { excluded `Cmd_subst }

  | "/dev/null"    { incr_tokens (); DEV_NULL }
  | '\'' "/dev/null" '\'' { incr_tokens (); DEV_NULL }
  | '"' "/dev/null" '"' { incr_tokens (); DEV_NULL }
  | (word_prefix as prefix) '\'' (sq_body as s) '\'' { incr_tokens (); word_tail (Shell_ir.Lit (prefix ^ s, { Shell_ir.quoted = true; glob = false; escaped = false })) [] lexbuf }
  | (word_prefix as prefix) '"' (dq_body as s) '"' { incr_tokens (); word_tail (Shell_ir.Lit (prefix ^ s, { Shell_ir.quoted = true; glob = false; escaped = false })) [] lexbuf }
  | '\'' (sq_body as s) '\'' { incr_tokens (); word_tail (Shell_ir.Lit (s, { Shell_ir.quoted = true; glob = false; escaped = false })) [] lexbuf }
  | '"' (dq_body as s) '"' { incr_tokens (); word_tail (Shell_ir.Lit (s, { Shell_ir.quoted = true; glob = false; escaped = false })) [] lexbuf }
  | word as w      { incr_tokens (); word_tail (Shell_ir.Lit (w, meta_of_string w)) [] lexbuf }
  | eof            { EOF }
  (* No rule matched. This is not [`Unknown_construct]: the rules above each
     name a shell feature the tool does not implement, and what arrives here
     is text that is not a command line -- [echo 'unterminated] reaches it on
     a quote the subset does take, just never closed. Saying "this tool does
     not run [']" would be false. [Parse_error] carries the position. *)
  | _ as c         { raise (Failure (Printf.sprintf "unexpected char %c" c)) }

(* Adjacent pieces of the word opened in [token].  Each arm mirrors a
   word-forming rule above; anything else — whitespace, an operator,
   eof, an excluded construct's first char — matches the empty pattern,
   which closes the word without consuming, and [token] reads on from
   the boundary.  An excluded construct glued to a word ([foo$(bar)])
   therefore still reaches its own rule and is refused by name. *)
and word_tail first rev_rest = parse
  | '$' (param_name as name) {
      incr_tokens ();
      word_tail first (Shell_ir.Var (name, meta_of_string name) :: rev_rest) lexbuf
    }
  | "${" (param_name as name) "}" {
      incr_tokens ();
      word_tail
        first
        (Shell_ir.Var
           (name, { Shell_ir.quoted = false; glob = false; escaped = false })
         :: rev_rest)
        lexbuf
    }
  | '\'' (sq_body as s) '\'' {
      incr_tokens ();
      word_tail
        first
        (Shell_ir.Lit (s, { Shell_ir.quoted = true; glob = false; escaped = false })
         :: rev_rest)
        lexbuf
    }
  | '"' (dq_body as s) '"' {
      incr_tokens ();
      word_tail
        first
        (Shell_ir.Lit (s, { Shell_ir.quoted = true; glob = false; escaped = false })
         :: rev_rest)
        lexbuf
    }
  | word as w {
      incr_tokens ();
      word_tail first (Shell_ir.Lit (w, meta_of_string w) :: rev_rest) lexbuf
    }
  | "" { assemble_word first rev_rest }
