%{
open Masc_exec

type stage_part =
  | Arg of Masc_exec.Shell_ir.arg
  | Redirect of Redirect_scope.t

let file_redirect fd target mode =
  (* A parsed command writes paths as it sees them. Nothing here knows which
     filesystem that is, so the target stays untranslated and a sandboxed
     dispatch refuses it rather than opening whatever this host has. *)
  Redirect_scope.File
    { fd
    ; target = Redirect_scope.In_command_namespace (Path_scope.classify ~raw:target ~cwd:".")
    ; mode
    }
;;
%}

/* Bash subset grammar — Menhir LR(1).

   Productions now cover simple commands, pipelines, env prefixes
   (recognized in bash.ml from leading WORD tokens), fd-to-fd redirects,
   file redirects, and && / || between pipelines. Subsequent PRs extend
   to subset guards that mint Parsed.Too_complex rather than matching.

   The grammar emits a head pipeline plus connector-joined tails, each
   pipeline a list of raw (bin, args, redirects) triples. bash.ml adapts
   a lone stage to Shell_ir.Simple, several to Shell_ir.Pipeline, and a
   non-empty tail to Shell_ir.Sequence.

   See RFC v5 (docs/rfc/RFC-0005). */

%token <string * Masc_exec.Shell_ir.arg_meta> WORD
%token <string * Masc_exec.Shell_ir.arg_meta> PARAM
%token DEV_NULL
%token <int * int> FD_REDIRECT
%token <int * Masc_exec.Redirect_scope.mode> FILE_REDIRECT_OP
%token PIPE
%token AND_IF
%token OR_IF
%token SEMICOLON
%token EOF

(* A stage is a word sequence plus redirects.  Words are already
   assembled args ([Lit] / [Var] / [Concat]) — the [bin] is decided in
   bash.ml after env prefixes are split off, because whether a word is
   the program or a binding ([FOO=$BAR cmd]) is a fact about the whole
   word, not about a token. *)
%start <(Masc_exec.Shell_ir.arg list * Masc_exec.Redirect_scope.t list) list * (Masc_exec.Shell_ir.connector * (Masc_exec.Shell_ir.arg list * Masc_exec.Redirect_scope.t list) list) list> command

%%

literal_word:
  | value = WORD { value }
  | DEV_NULL { "/dev/null", Masc_exec.Shell_ir.default_meta }

(* One piece of a shell word: a literal token or a simple parameter
   expansion.  Adjacent pieces become one word — [prefix=$DIR] lexes as
   WORD ["prefix="] then PARAM ["DIR"] and assembles to
   Concat [Lit "prefix="; Var "DIR"] — the shape bash itself uses for
   [FOO=bar$BAZ]. *)
word_piece:
  | value = literal_word { Masc_exec.Shell_ir.Lit value }
  | name = PARAM { Masc_exec.Shell_ir.Var name }

word_seq:
  | piece = word_piece { [ piece ] }
  | seq = word_seq piece = word_piece { seq @ [ piece ] }

word:
  | pieces = word_seq {
      match pieces with
      | [ single ] -> single
      | many -> Masc_exec.Shell_ir.Concat many
    }

part:
  | arg = word { Arg arg }
  | pair = FD_REDIRECT {
      let src, dst = pair in
      Redirect (Redirect_scope.Fd_to_fd { src; dst })
    }
  (* The redirect target stays a literal: [Path_scope.classify] runs on
     it at parse time and a substituted path has nothing to classify.
     [> $OUT] therefore fails to parse rather than passing unchecked. *)
  | item = FILE_REDIRECT_OP target = literal_word {
      let fd, mode = item in
      Redirect (file_redirect fd (fst target) mode)
    }

stage:
  | head = part parts = list(part) {
      let args, redirects =
        List.fold_left
          (fun (args, redirects) -> function
             | Arg arg -> arg :: args, redirects
             | Redirect redirect -> args, redirect :: redirects)
          ([], [])
          (head :: parts)
      in
      (List.rev args, List.rev redirects)
    }

pipeline:
  | stages = separated_nonempty_list(PIPE, stage) { stages }

command:
  | head = pipeline rest = command_rest EOF
    { (head, rest) }

command_rest:
  | /* empty */ { [] }
  | SEMICOLON { [] }
  | SEMICOLON head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.Seq, head) :: rest
    }
  | AND_IF head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.And_if, head) :: rest
    }
  | OR_IF head = pipeline rest = command_rest {
      (Masc_exec.Shell_ir.Or_if, head) :: rest
    }
