%{
open Masc_exec

type stage_part =
  | Arg of string
  | Redirect of Redirect_scope.t

let dev_null_path () =
  Path_scope.classify ~raw:"/dev/null" ~cwd:"."
;;

let file_redirect fd mode =
  Redirect_scope.File { fd; target = dev_null_path (); mode }
;;
%}

/* Bash subset grammar — Menhir LR(1).

   Productions now cover simple commands, pipelines, fd-to-fd
   redirects, and /dev/null file redirects. Subsequent PRs extend to:
   - env prefix (FOO=bar cmd)
   - general file redirects beyond the explicit /dev/null sink
   - subset guards that mint Parsed.Too_complex rather than matching.

   The grammar emits a list of raw (bin, args, redirects) triples,
   one per pipeline stage. bash.ml adapts the singleton case to
   Shell_ir.Simple and the multi-stage case to Shell_ir.Pipeline.

   See RFC v5 (docs/rfc/RFC-0005). */

%token <string> WORD
%token DEV_NULL
%token <int * int> FD_REDIRECT
%token <int * Masc_exec.Redirect_scope.mode> FILE_REDIRECT_OP
%token PIPE
%token EOF

%start <(string * string list * Masc_exec.Redirect_scope.t list) list> command

%%

literal_word:
  | value = WORD { value }
  | DEV_NULL { "/dev/null" }

part:
  | arg = literal_word { Arg arg }
  | pair = FD_REDIRECT {
      let src, dst = pair in
      Redirect (Redirect_scope.Fd_to_fd { src; dst })
    }
  | item = FILE_REDIRECT_OP DEV_NULL {
      let fd, mode = item in
      Redirect (file_redirect fd mode)
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

command:
  | stages = separated_nonempty_list(PIPE, stage) EOF { stages }
