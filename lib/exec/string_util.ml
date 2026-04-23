(* Exec-local string utilities.
   Kept minimal to avoid pulling in masc_core.
   base and re are explicit dependencies of lib/exec/dune. *)

let contains_substring haystack needle =
  Base.String.is_substring haystack ~substring:needle
