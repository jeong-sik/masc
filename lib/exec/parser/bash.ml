(* A1 parser facade — wraps Menhir grammar + lexer with error
   translation to Parsed.t arms.  Never raises. *)

open Masc_exec

let make_parse_error (lexbuf : Lexing.lexbuf) : Parsed.parse_error =
  let pos = Lexing.lexeme_start_p lexbuf in
  let token = Lexing.lexeme lexbuf in
  { pos; token; expected = [] (* populated in later PR *) }

let is_env_name_start = function
  | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
  | _other -> false

let is_env_name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _other -> false

(* An env binding is a fact about a whole word, so it is read from the
   assembled [Shell_ir.arg], not from a token.  A literal word keeps the
   original [NAME=value] reading; a concatenated word ([FOO=$BAR],
   [FOO=bar$BAZ]) splits at the first [=] of its leading literal piece,
   which is where the lexer ended the word it had and started the
   expansion. *)
let binding_of_literal_name_value name (value : Shell_ir.arg) =
  if String.length name > 0
     && is_env_name_start name.[0]
     && String.for_all is_env_name_char name
  then Some (name, value)
  else None

let value_of_pieces (pieces : Shell_ir.arg list) : Shell_ir.arg =
  match pieces with
  | [ single ] -> single
  | many -> Shell_ir.Concat many

let rec arg_as_assignment (arg : Shell_ir.arg) :
    (string * Shell_ir.arg) option =
  match arg with
  | Shell_ir.Var _ -> None
  | Shell_ir.Lit (word, meta) -> (
    match String.index_opt word '=' with
    | None | Some 0 -> None
    | Some idx ->
      let name = String.sub word 0 idx in
      let value =
        String.sub word (idx + 1) (String.length word - idx - 1)
      in
      binding_of_literal_name_value name (Shell_ir.Lit (value, meta)))
  | Shell_ir.Concat (Shell_ir.Lit (word, meta) :: rest) -> (
    match String.index_opt word '=' with
    | None | Some 0 -> None
    | Some idx ->
      let name = String.sub word 0 idx in
      let value_literal =
        String.sub word (idx + 1) (String.length word - idx - 1)
      in
      let pieces =
        if String.length value_literal = 0 then rest
        else Shell_ir.Lit (value_literal, meta) :: rest
      in
      binding_of_literal_name_value name (value_of_pieces pieces))
  | Shell_ir.Concat [] -> None

let split_env_prefix (args : Shell_ir.arg list) =
  let rec loop env = function
    | [] ->
      Error { Parsed.pos = Lexing.dummy_pos; token = ""; expected = [ "command" ] }
    | arg :: rest ->
      (match arg_as_assignment arg with
       | Some binding -> loop (binding :: env) rest
       | None -> Ok (List.rev env, arg, rest))
  in
  loop [] args

(* A stage refused before there was a [Shell_ir.simple] to talk about:
   either the tokens never formed a command, or they formed one whose
   program position is an expansion — the subset reads [$CMD args] as
   outside itself rather than guessing a program at run time. *)
type stage_error =
  | Stage_parse_error of Parsed.parse_error
  | Stage_outside_subset of Parsed.reason_too_complex

let raw_to_simple (args : Shell_ir.arg list, redirects)
    : (Shell_ir.simple, stage_error) result =
  match split_env_prefix args with
  | Error e -> Error (Stage_parse_error e)
  | Ok (env, bin_arg, arg_words) -> (
    let bin_word =
      match bin_arg with
      | Shell_ir.Lit (value, _) -> `Word value
      | Shell_ir.Var _ | Shell_ir.Concat _ -> `Expansion
    in
    match bin_word with
    | `Expansion -> Error (Stage_outside_subset `Param_expansion)
    | `Word bin_str -> (
      match Exec_program.of_string bin_str with
      | Error (`Unknown _) ->
        (* A0 guarantees Exec_program.of_string only errors on empty input.  That
           cannot happen downstream of the current grammar (the stage accepts
           at least one piece), so this branch is defensive. *)
        Error
          (Stage_parse_error
             { Parsed.pos = Lexing.dummy_pos; token = bin_str; expected = [] })
      | Ok bin -> Ok { Shell_ir.bin; args = arg_words; env; cwd = None
                     ; redirects; sandbox = Sandbox_target.host () }))

let rec map_stages = function
  | [] -> Ok []
  | stage :: rest ->
    (match raw_to_simple stage with
     | Error e -> Error e
     | Ok simple ->
       (match map_stages rest with
        | Error e -> Error e
        | Ok tail -> Ok (simple :: tail)))

let pipeline_to_ir
      (stages : (Shell_ir.arg list * Redirect_scope.t list) list)
    : (Shell_ir.t, stage_error) result =
  match map_stages stages with
  | Error e -> Error e
  | Ok [ single ] -> Ok (Shell_ir.Simple single)
  | Ok (_ :: _ :: _ as many) ->
    Ok (Shell_ir.Pipeline (List.map (fun s -> Shell_ir.Simple s) many))
  | Ok [] ->
    (* Unreachable: the grammar uses separated_nonempty_list so
       stages is always length >= 1.  Defensive. *)
    Error
      (Stage_parse_error
         { Parsed.pos = Lexing.dummy_pos; token = ""; expected = [ "command" ] })

let to_shell_ir
      ((head, tail) :
        (Shell_ir.arg list * Redirect_scope.t list) list
        * (Shell_ir.connector * (Shell_ir.arg list * Redirect_scope.t list) list)
          list)
    : Shell_ir.t Parsed.t =
  let ( let* ) = Result.bind in
  let parsed =
    let* head_ir = pipeline_to_ir head in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (connector, stages) :: rest ->
        let* ir = pipeline_to_ir stages in
        loop ((connector, ir) :: acc) rest
    in
    let* tail_irs = loop [] tail in
    match tail_irs with
    | [] -> Ok head_ir
    | _ :: _ -> Ok (Shell_ir.Sequence { head = head_ir; tail = tail_irs })
  in
  match parsed with
  | Ok ir -> Parsed.Parsed ir
  | Error (Stage_parse_error e) -> Parsed.Parse_error e
  | Error (Stage_outside_subset reason) -> Parsed.Too_complex reason

(* Two ways to be outside the subset, told apart by which stage refused.

   The lexer refuses a lexeme it has no token for, and names the construct as
   it matches it ([Bash_lexer.Excluded_construct]). The parser refuses an
   arrangement of tokens that all lexed, and there is no construct to name --
   [echo hi | | grep x] is two pipes, not a shell feature -- so that is
   [Parse_error], carrying the position and token.

   Neither answer is inferred from the source text. An earlier version
   scanned the whole string for the first metacharacter off an ordered list
   after either failure; it had no case for [$], so an expansion next to a
   redirect was reported as the redirect. RFC execute-subset-dispositions §6
   recorded the same shape from the other end -- a tag naming the first trip
   rather than the construct -- and this is where that is closed. *)
let parse_string (source : string) : Shell_ir.t Parsed.t =
  Bash_lexer.reset_tokens ();
  let lexbuf = Lexing.from_string source in
  try
    let raw = Bash_subset.command Bash_lexer.token lexbuf in
    to_shell_ir raw
  with
  | Bash_lexer.Token_limit_exceeded -> Parsed.Parse_aborted `Token_limit_50k
  | Bash_lexer.Excluded_construct reason -> Parsed.Too_complex reason
  | Bash_subset.Error -> Parsed.Parse_error (make_parse_error lexbuf)
  (* [int_of_string] on a descriptor the rule matched but no machine has, as
     in [99999999999999999999>out]. The token is well formed and unusable,
     which is what a parse error says. *)
  | Failure _ -> Parsed.Parse_error (make_parse_error lexbuf)
