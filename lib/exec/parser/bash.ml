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

let parse_env_assignment (word_str, meta) =
  match String.index_opt word_str '=' with
  | None -> None
  | Some 0 -> None
  | Some idx ->
    let name = String.sub word_str 0 idx in
    if is_env_name_start name.[0]
       && String.for_all is_env_name_char name
    then
      let value =
        String.sub word_str (idx + 1) (String.length word_str - idx - 1)
      in
      Some (name, Shell_ir.Lit (value, meta))
    else None

let split_env_prefix words =
  let rec loop env = function
    | [] -> Error { Parsed.pos = Lexing.dummy_pos; token = ""; expected = [ "command" ] }
    | word :: rest ->
      (match parse_env_assignment word with
       | Some binding -> loop (binding :: env) rest
       | None -> Ok (List.rev env, word, rest))
  in
  loop [] words

let raw_to_simple (bin_word, args_words, redirects)
    : (Shell_ir.simple, Parsed.parse_error) result =
  match split_env_prefix (bin_word :: args_words) with
  | Error e -> Error e
  | Ok (env, (bin_str, _), args_words) -> (
  match Exec_program.of_string bin_str with
  | Error (`Unknown _) ->
    (* A0 guarantees Exec_program.of_string only errors on empty input.  That
       cannot happen downstream of the current grammar (WORD+ accepts
       at least one token), so this branch is defensive. *)
    Error { Parsed.pos = Lexing.dummy_pos; token = bin_str; expected = [] }
  | Ok bin ->
    let args =
      List.map (fun (s, meta) -> Shell_ir.Lit (s, meta)) args_words
    in
    Ok
      { Shell_ir.bin
      ; args
      ; env
      ; cwd = None
      ; redirects
      ; sandbox = Sandbox_target.host ()
      })

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
      (stages :
        ( (string * Shell_ir.arg_meta)
        * (string * Shell_ir.arg_meta) list
        * Redirect_scope.t list )
        list)
    : (Shell_ir.t, Parsed.parse_error) result =
  match map_stages stages with
  | Error e -> Error e
  | Ok [ single ] -> Ok (Shell_ir.Simple single)
  | Ok (_ :: _ :: _ as many) ->
    Ok (Shell_ir.Pipeline (List.map (fun s -> Shell_ir.Simple s) many))
  | Ok [] ->
    (* Unreachable: the grammar uses separated_nonempty_list so
       stages is always length >= 1.  Defensive. *)
    Error { pos = Lexing.dummy_pos; token = ""; expected = [ "command" ] }

let to_shell_ir
      ((head, tail) :
        ( (string * Shell_ir.arg_meta)
        * (string * Shell_ir.arg_meta) list
        * Redirect_scope.t list )
        list
        * (Shell_ir.connector
          * ( (string * Shell_ir.arg_meta)
            * (string * Shell_ir.arg_meta) list
            * Redirect_scope.t list )
            list)
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
  | Error e -> Parsed.Parse_error e

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
  (* [&&] and [||] are in the subset now, so reaching here with one means
     the input failed for another reason -- an operand the grammar could not
     read. Classifying it as `Logic_op would name the wrong construct. *)
  else if has "$(" || has "`" then Some `Cmd_subst
  else if has "<(" || has ">(" then Some `Proc_subst
  (* Before the redirect check, not after. A separated list usually carries a
     redirect somewhere in it, and reporting the redirect names a construct
     this subset already supports. Measured against the 548 command lines the
     runtime produced over 2026-08-21..23, every one of the 31 refusals
     reported as `Redirect was in fact a [;] beside a supported [2>/dev/null].
     The tap that decides which construct the subset takes next was reading
     the wrong one. *)
  else if has ";" then Some `Command_separator
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
  | Bash_lexer.Token_limit_exceeded -> Parsed.Parse_aborted `Token_limit_50k
  | Bash_subset.Error -> map_error_or_classify source lexbuf
  | Failure _ -> map_error_or_classify source lexbuf
