/* A1 bash subset grammar — Menhir LR(1), minimal skeleton.

   Current productions cover a single simple command (bin + args).
   Subsequent PRs extend to:
   - env prefix (FOO=bar cmd)
   - redirects (> < >>, with fd number)
   - pipeline (cmd | cmd | cmd)
   - subset guards that mint Parsed.Too_complex rather than matching.

   The grammar emits a raw (bin, args) pair of strings.  bash.ml
   adapts it to Shell_ir.t via Bin.of_string + Shell_ir.Lit for args.

   See RFC v5 (docs/rfc/RFC-0005). */

%token <string> WORD
%token EOF

%start <string * string list> command

%%

command:
  | bin = WORD args = list(WORD) EOF { (bin, args) }
