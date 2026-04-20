(* A1 bash subset lexer — minimal skeleton (simple command only).

   Current token set covers the A1-PR-1 grammar: unquoted WORD tokens
   plus EOF.  Subsequent PRs extend to quoted strings, redirects, pipe,
   env-prefix assignment, and subset guards (heredoc/$()/subshell that
   mint Parsed.Too_complex).  See RFC v5 (docs/rfc/RFC-0005). *)

{
  open Bash_subset

  (* Token budget — each lexeme increments a counter the parser
     consults.  50k ceiling per RFC v5 plan; enforced at parse_string
     level, not here (lexer only counts). *)
  let token_count = ref 0
  let reset_tokens () = token_count := 0
  let incr_tokens () = incr token_count
  let get_tokens () = !token_count
}

(* The A1-PR-1 WORD class: printable ASCII minus shell metacharacters.
   Follow-up PRs widen to quoted strings and split meta off into their
   own tokens (PIPE, LESS, GREAT, EQUALS, ...). *)
let word_char = [^ ' ' '\t' '\n' '\r' '|' '<' '>' '&' ';' '(' ')'
                   '\'' '"' '$' '`' '\\' '=' '{' '}' '!' '*' '?']
let word = word_char+

(* Single-quote string: literal, no escape processing, no nested
   single quote allowed (bash semantics — there is no way to embed
   a single quote inside a '...' string).  Matched content becomes
   a single WORD token so the existing grammar accepts it in any
   WORD position without change.  Spaces inside quotes are preserved
   verbatim, so arguments like 'commit message' arrive at
   [Bin.of_string] / args list as one element. *)
let sq_body = [^ '\'' '\n']*

(* Double-quote string: A1 skeleton treats it as a literal whose body
   excludes the four metachars bash would interpret inside "..." —
   backslash escapes ('\"', '\\', '\$', '\`'), variable expansion ($FOO,
   ${FOO}), command substitution (`cmd`, $(cmd)), and embedded newlines.
   Any of those chars inside the body breaks the lex → Parse_error,
   which is the correct fail-closed behavior for the subset.  The most
   common caller shapes (rg "pattern", git commit -m "message",
   echo "hello world") have none of those chars and land as one WORD
   token, mirroring the single-quote rule's space-preservation guarantee.
   Upgrade path: later PR widens dq_body to support escape sequences by
   capturing in a sub-rule that unescapes into a Buffer. *)
let dq_body = [^ '"' '\n' '\\' '$' '`']*

rule token = parse
  | [' ' '\t']+    { token lexbuf }
  | '\n'           { incr_tokens (); Lexing.new_line lexbuf; token lexbuf }
  | '|'            { incr_tokens (); PIPE }
  | '\'' (sq_body as s) '\'' { incr_tokens (); WORD s }
  | '"' (dq_body as s) '"' { incr_tokens (); WORD s }
  | word as w      { incr_tokens (); WORD w }
  | eof            { EOF }
  | _ as c         { raise (Failure (Printf.sprintf "unexpected char %c" c)) }
