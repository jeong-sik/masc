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

   Productions cover simple commands, pipelines, env prefixes (recognized
   in bash.ml from the assembled words), fd-to-fd redirects, file
   redirects, and && / || between pipelines.

   Whitespace reaches the grammar as a SEP token, and that token is what
   separates words: adjacent pieces (no SEP between) assemble into one
   word — [prefix=$DIR] is WORD ["prefix="] then PARAM ["DIR"], one
   Concat — while [echo $HOME] carries a SEP and stays two words.  A
   stage's trailing SEP is consumed here too, so the token after a SEP
   (a part, PIPE, SEMICOLON, or EOF) is what decides what the SEP
   separated, never a guess made one token early.

   A stage begins with a word — the program position.  Redirects never
   open a stage; they continue one, glued directly ([ls 2>&1]) or behind
   a SEP.  The [bin] itself is decided in bash.ml after env prefixes are
   split off, because whether a word is the program or a binding
   ([FOO=$BAR cmd]) is a fact about the whole word.

   The grammar emits a head pipeline plus connector-joined tails, each
   pipeline a list of (args, redirects) stages.  bash.ml adapts a lone
   stage to Shell_ir.Simple, several to Shell_ir.Pipeline, and a
   non-empty tail to Shell_ir.Sequence.

   See RFC v5 (docs/rfc/RFC-0005). */

%token <string * Masc_exec.Shell_ir.arg_meta> WORD
%token <string * Masc_exec.Shell_ir.arg_meta> PARAM
%token SEP
%token DEV_NULL
%token <int * int> FD_REDIRECT
%token <int * Masc_exec.Redirect_scope.mode> FILE_REDIRECT_OP
%token PIPE
%token AND_IF
%token OR_IF
%token SEMICOLON
%token EOF

%start <(Masc_exec.Shell_ir.arg list * Masc_exec.Redirect_scope.t list) list * (Masc_exec.Shell_ir.connector * (Masc_exec.Shell_ir.arg list * Masc_exec.Redirect_scope.t list) list) list> command

%%

(* One separator — a whitespace run the lexer shrank to a single token.
   At most one can sit in any position: the lexer merges runs, so
   [SEP SEP] cannot happen. *)
gap:
  | /* empty */ { () }
  | SEP { () }

literal_word:
  | value = WORD { value }
  | DEV_NULL { "/dev/null", Masc_exec.Shell_ir.default_meta }

(* One piece of a shell word: a literal token or a simple parameter
   expansion.  Adjacent pieces become one word — [prefix=$DIR] assembles
   to Concat [Lit "prefix="; Var "DIR"], the shape bash itself uses for
   [FOO=bar$BAZ].  Pieces are adjacent by token position: whatever SEP
   the source had between them already ended the previous word. *)
word_piece:
  | value = literal_word {
      let text, meta = value in
      Masc_exec.Shell_ir.Lit (text, meta)
    }
  | param = PARAM {
      let name, meta = param in
      Masc_exec.Shell_ir.Var (name, meta)
    }

word_seq:
  | piece = word_piece { [ piece ] }
  | seq = word_seq piece = word_piece { seq @ [ piece ] }

word:
  | pieces = word_seq {
      match pieces with
      | [ single ] -> single
      | many -> Masc_exec.Shell_ir.Concat many
    }

redirect_part:
  | pair = FD_REDIRECT {
      let src, dst = pair in
      Redirect (Redirect_scope.Fd_to_fd { src; dst })
    }
  (* The redirect target stays a literal: [Path_scope.classify] runs on
     it at parse time and a substituted path has nothing to classify.
     [> $OUT] therefore fails to parse rather than passing unchecked.
     The target may sit behind a separator from its operator
     ([2> /dev/null] as well as [2>/dev/null]). *)
  | item = FILE_REDIRECT_OP gap target = literal_word {
      let fd, mode = item in
      Redirect (file_redirect fd (fst target) mode)
    }

part:
  | arg = word { Arg arg }
  | redirect = redirect_part { redirect }

(* What follows the program word.  A SEP either continues the stage with
   a part or ends it — which one, the token after the SEP says.  A
   redirect may also glue directly onto the stage with no separator. *)
stage_parts:
  | /* empty */ { [] }
  | SEP p = part rest = stage_parts { p :: rest }
  | SEP { [] }
  | r = redirect_part rest = stage_parts { r :: rest }

stage:
  | head = word parts = stage_parts {
      let args, redirects =
        List.fold_left
          (fun (args, redirects) -> function
             | Arg arg -> arg :: args, redirects
             | Redirect redirect -> args, redirect :: redirects)
          ([], [])
          (Arg head :: parts)
      in
      (List.rev args, List.rev redirects)
    }

pipeline:
  | gap head = stage rest = pipeline_tail { head :: rest }

(* Stages join flat: [PIPE pipeline ...] here would nest, and the same
   [PIPE stage] suffix would then have two derivations — inside the
   innermost pipeline's tail or this one. *)
pipeline_tail:
  | /* empty */ { [] }
  | PIPE gap next = stage rest = pipeline_tail { next :: rest }

command:
  | head = pipeline rest = command_rest EOF { (head, rest) }

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
