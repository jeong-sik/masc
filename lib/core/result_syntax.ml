(** Result_syntax — thin re-export of stdlib [Stdlib.Result.Syntax].

    Historical: defined [let*]/[let+] locally before call sites migrated.
    OCaml 4.14+ provides the same operators in [Stdlib.Result.Syntax];
    this module is kept as a compatibility alias while call sites migrate
    directly to [open Result.Syntax]. *)

include Stdlib.Result.Syntax
