/* A1 bash subset grammar — Menhir LR(1).

   Productions now cover simple commands and pipelines.  Subsequent
   PRs extend to:
   - env prefix (FOO=bar cmd)
   - redirects (> < >>, with fd number)
   - subset guards that mint Parsed.Too_complex rather than matching.

   The grammar emits a list of raw (bin, args) pairs, one per
   pipeline stage.  bash.ml adapts the singleton case to
   Shell_ir.Simple and the multi-stage case to Shell_ir.Pipeline.

   See RFC v5 (docs/rfc/RFC-0005). */

%token <string> WORD
%token PIPE
%token EOF

%start <(string * string list) list> command

%%

stage:
  | bin = WORD args = list(WORD) { (bin, args) }

command:
  | stages = separated_nonempty_list(PIPE, stage) EOF { stages }
