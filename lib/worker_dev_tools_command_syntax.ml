(** Shell word helpers for worker path policy.

    Command-shape validation is owned by
    [Masc_exec_command_gate.Shell_command_gate]. This module keeps only
    path-token normalization helpers that operate on parser-provided words. *)

let strip_wrapping_quotes token =
  let len = String.length token in
  if len >= 2
  then (
    let first = token.[0]
    and last = token.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'')
    then String.sub token 1 (len - 2)
    else token)
  else token
;;
