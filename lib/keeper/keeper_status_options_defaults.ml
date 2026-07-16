(** Canonical defaults and limits for [masc_keeper_status] tail options.
    Shared by runtime parsing and the public tool schema so the advertised
    contract cannot drift from execution. *)

let tail_turns = 3
let tail_messages = 5
let tail_compactions = 10
let tail_bytes = 60_000
let min_tail_bytes = 1_000
