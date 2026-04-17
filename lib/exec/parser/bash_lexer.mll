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

rule token = parse
  | [' ' '\t']+    { token lexbuf }
  | '\n'           { incr_tokens (); Lexing.new_line lexbuf; token lexbuf }
  | '|'            { incr_tokens (); PIPE }
  | word as w      { incr_tokens (); WORD w }
  | eof            { EOF }
  | _ as c         { raise (Failure (Printf.sprintf "unexpected char %c" c)) }
