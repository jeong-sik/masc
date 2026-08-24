%{
open Masc_exec

type stage_part =
  | Arg of (string * Masc_exec.Shell_ir.arg_meta)
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
%token DEV_NULL
%token <int * int> FD_REDIRECT
%token <int * Masc_exec.Redirect_scope.mode> FILE_REDIRECT_OP
%token PIPE
%token AND_IF
%token OR_IF
%token EOF

%start <(((string * Masc_exec.Shell_ir.arg_meta) * (string * Masc_exec.Shell_ir.arg_meta) list * Masc_exec.Redirect_scope.t list) list * (Masc_exec.Shell_ir.connector * ((string * Masc_exec.Shell_ir.arg_meta) * (string * Masc_exec.Shell_ir.arg_meta) list * Masc_exec.Redirect_scope.t list) list) list)> command

%%

literal_word:
  | value = WORD { value }
  | DEV_NULL { "/dev/null", Masc_exec.Shell_ir.default_meta }

part:
  | arg = literal_word { Arg arg }
  | pair = FD_REDIRECT {
      let src, dst = pair in
      Redirect (Redirect_scope.Fd_to_fd { src; dst })
    }
  | item = FILE_REDIRECT_OP target = literal_word {
      let fd, mode = item in
      Redirect (file_redirect fd (fst target) mode)
    }

stage:
  | bin = literal_word parts = list(part) {
      let args, redirects =
        List.fold_left
          (fun (args, redirects) -> function
             | Arg arg -> arg :: args, redirects
             | Redirect redirect -> args, redirect :: redirects)
          ([], [])
          parts
      in
      (bin, List.rev args, List.rev redirects)
    }

pipeline:
  | stages = separated_nonempty_list(PIPE, stage) { stages }

connector:
  | AND_IF { Masc_exec.Shell_ir.And_if }
  | OR_IF { Masc_exec.Shell_ir.Or_if }

/* head kept apart from the rest so an empty sequence cannot be written,
   the same shape [Shell_ir.Sequence] uses. */
command:
  | head = pipeline
    tail = list(pair(connector, pipeline))
    EOF
    { (head, tail) }
