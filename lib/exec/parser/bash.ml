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
    Ok { Shell_ir.bin; args; env = []; cwd = None; redirects = [] }

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

let parse_string (source : string) : Shell_ir.t Parsed.t =
  Bash_lexer.reset_tokens ();
  let lexbuf = Lexing.from_string source in
  try
    let raw = Bash_subset.command Bash_lexer.token lexbuf in
    to_shell_ir raw
  with
  | Bash_subset.Error -> Parsed.Parse_error (make_parse_error lexbuf)
  | Failure _ -> Parsed.Parse_error (make_parse_error lexbuf)
