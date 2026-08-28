(** Keeper_identity — centralized keeper identity helpers. *)

let trace_counter = Atomic.make 0

let generate_trace_id ?(now = Time_compat.now ()) () : string =
  let ts = int_of_float (now *. 1000.0) in
  let seq = Atomic.fetch_and_add trace_counter 1 land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts seq

(* RFC-0393: the alias/nickname canonicalizer chain is gone. A keeper's
   id is its keeper_name, trimmed and case-folded; non-keeper authors
   (humans, external bots) mint comparable ids from their own name the
   same way. Whether a name denotes a keeper is a registry/meta lookup
   at the caller, never a property of the string's shape. *)
module Keeper_id = struct
  type t = string

  let of_string value =
    match String.trim value with
    | "" -> None
    | id -> Some (String.lowercase_ascii id)

  let to_string id = id
  let equal = String.equal
  let compare = String.compare
end
