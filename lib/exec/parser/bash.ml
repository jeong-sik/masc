(* A1 parser facade — wraps Menhir grammar + lexer with error
   translation to Parsed.t arms.  Never raises. *)

open Masc_exec

let make_parse_error (lexbuf : Lexing.lexbuf) : Parsed.parse_error =
  let pos = Lexing.lexeme_start_p lexbuf in
  let token = Lexing.lexeme lexbuf in
  { pos; token; expected = [] (* populated in later PR *) }

let raw_to_simple (bin_str, args_str) : (Shell_ir.simple, Parsed.parse_error) result =
  match Bin.of_string bin_str with
  | Error (`Unknown _) ->
    (* A0 guarantees Bin.of_string only errors on empty input.  That
       cannot happen downstream of the current grammar (WORD+ accepts
       at least one token), so this branch is defensive. *)
    Error { Parsed.pos = Lexing.dummy_pos; token = bin_str; expected = [] }
  | Ok bin ->
    let args = List.map (fun s -> Shell_ir.Lit s) args_str in
    Ok
      { Shell_ir.bin
      ; args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }

let rec map_stages = function
  | [] -> Ok []
  | stage :: rest ->
    (match raw_to_simple stage with
     | Error e -> Error e
     | Ok simple ->
       (match map_stages rest with
        | Error e -> Error e
        | Ok tail -> Ok (simple :: tail)))

let to_shell_ir (stages : (string * string list) list)
    : Shell_ir.t Parsed.t =
  match map_stages stages with
  | Error e -> Parsed.Parse_error e
  | Ok [ single ] -> Parsed.Parsed (Shell_ir.Simple single)
  | Ok (_ :: _ :: _ as many) ->
    let ir_stages = List.map (fun s -> Shell_ir.Simple s) many in
    Parsed.Parsed (Shell_ir.Pipeline ir_stages)
  | Ok [] ->
    (* Unreachable: the grammar uses separated_nonempty_list so
       stages is always length >= 1.  Defensive. *)
    Parsed.Parse_error
      { pos = Lexing.dummy_pos; token = ""; expected = [ "command" ] }

(* Post-hoc [reason_too_complex] classifier.  Runs only after the
   Menhir grammar (or lexer) has rejected the input — so the input is
   already outside the A1-PR-1 simple-command subset.  Inspects the
   raw source for the dominant shell metachar and returns the most
   specific [reason_too_complex] variant it can.

   The scan is deliberately substring-based (not quote-aware): callers
   who quote metachars through single or double quotes land on
   [Parsed.Parsed] before this path runs, so anything reaching here
   has an unquoted metachar somewhere.  False-positive precision
   matters less than differentiating between "couldn't parse at all"
   (the old [Parse_error] bucket) and "rejected because a specific
   shell feature is subset-excluded" — the latter is what the corpus
   tap aggregates to drive future grammar expansion priority.

   Order matters: multi-char markers ([<<<], [<<], [>>], [&&], [||],
   [$(], [$((], [<(], [>(]) are checked before their single-char
   prefixes.  First match wins. *)
let classify_too_complex (source : string) : Parsed.reason_too_complex option =
  let has sub = String_util.contains_substring source sub in
  if has "$((" then Some `Arith_expansion
  else if has "<<<" then Some `Here_string
  else if has "<<" then Some `Heredoc
  else if has "&&" || has "||" then Some `Logic_op
  else if has "$(" || has "`" then Some `Cmd_subst
  else if has "<(" || has ">(" then Some `Proc_subst
  else if has ">>" || has ">" || has "<" then Some `Redirect
  else if has "(" || has ")" then Some `Subshell
  else if has "&" then Some `Background
  else if has "{" || has "}" then Some `Glob_brace
  else None

let map_error_or_classify (source : string) (lexbuf : Lexing.lexbuf)
    : Shell_ir.t Parsed.t =
  match classify_too_complex source with
  | Some reason -> Parsed.Too_complex reason
  | None -> Parsed.Parse_error (make_parse_error lexbuf)

let parse_string (source : string) : Shell_ir.t Parsed.t =
  Bash_lexer.reset_tokens ();
  let lexbuf = Lexing.from_string source in
  try
    let raw = Bash_subset.command Bash_lexer.token lexbuf in
    to_shell_ir raw
  with
  | Bash_subset.Error -> map_error_or_classify source lexbuf
  | Failure _ -> map_error_or_classify source lexbuf
