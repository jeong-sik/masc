(* RFC-0070 Phase 3b-ii — Container_name derivation. See .mli. *)

type t = string

(* Slice the first N hex chars of the hex-encoded digest. 32 hex chars
   = 16 bytes = 128 bits of entropy from the digest. RFC §3.1. *)
let hex_chars_taken = 32

let prefix = "masc-keeper-"

let derive ~algo ~turn_id ~attempt ~suffix =
  let input =
    (* Use unit separators (US, \x1F) so concatenation is unambiguous —
       different (turn_id, attempt, suffix) tuples map to different
       inputs even when adjacent digit fields could otherwise blur.
       Without separators, [Printf.sprintf "%d%d%s" 1 23 "x" = "123x"]
       and [Printf.sprintf "%d%d%s" 12 3 "x" = "123x"] — same string.
       With \x1f between fields these become "1\x1f23\x1fx" vs
       "12\x1f3\x1fx" and remain distinct. *)
    Printf.sprintf "%d\x1f%d\x1f%s" turn_id attempt suffix
  in
  let hex = Keeper_hash_algo.digest_hex algo input in
  prefix ^ String.sub hex 0 hex_chars_taken

let to_string t = t

let of_external_string s = s

let equal = String.equal

let pp ppf t = Format.pp_print_string ppf t
