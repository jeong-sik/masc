(** List utilities — SSOT for cross-module list helpers that have no
    direct stdlib equivalent.

    [count_if] is the single-pass variant of [List.length (List.filter
    pred xs)] — it drops the intermediate filter list allocation. The
    pattern occurred 23 times across the codebase before this module
    landed; centralising avoids re-defining the helper per file and
    makes the intent searchable. *)

let count_if pred xs =
  List.fold_left (fun n x -> if pred x then n + 1 else n) 0 xs
