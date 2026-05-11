(* RFC-0070 Phase 3b-ii — Container_name derivation. See .mli. *)

type t = string

(* Slice the first N hex chars of the hex-encoded digest. 32 hex chars
   = 16 bytes = 128 bits of entropy from the digest. RFC §3.1. *)
let hex_chars_taken = 32

let prefix = "masc-keeper-"

let of_hash_hex ~algo ~turn_id ~attempt ~suffix =
  let input =
    (* Use unit separators (US, \x1F) so concatenation is unambiguous —
       different (turn_id, attempt, suffix) tuples map to different
       inputs even when one field's serialisation could otherwise
       collide with another's (e.g., suffix="42|7" vs turn_id=42 ++
       attempt=7). *)
    Printf.sprintf "%d\x1f%d\x1f%s" turn_id attempt suffix
  in
  let hex = Keeper_hash_algo.digest_hex algo input in
  prefix ^ String.sub hex 0 hex_chars_taken

let to_string t = t

let equal = String.equal

let pp ppf t = Format.pp_print_string ppf t
