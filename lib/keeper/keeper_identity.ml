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
(* Naming: [Keeper_id] and [Validation.Id_shape] sit on different axes, and
   the names now say which.

     [Validation.Id_shape]  "is this string usable as an id at all"
                            length, path separators, "..", character set.
                            A gate. Refuses input, and logs what it refuses.
     [Keeper_id]            "are these two names the same actor"
                            trim + lowercase. A fold. Refuses nothing but "".

   It used to be called [Validation.Agent_id], which read as a sibling of this
   module and was not one. Three modules carried that name and meant three
   things: [Ids.Agent_id] mints a UUID, [Board_types.Agent_id] is a board
   author, and the validator asked about any string's shape. Swapping a
   validation call to [Keeper_id.of_string] drops four security checks and the
   compiler says nothing, because both sides are [string].

   The rename waited on evidence and got three pieces. 2026-08-28: that
   misreading was made twice in one session before the code was read, while
   chasing why edgar.a.poe could not claim its own task. 2026-08-29: a reader
   arrived at this comment for the same reason. And #31815: the gate was
   standing where a parser belonged — asked "is this an address" about a bare
   "@" — which cost 208 WARN lines in one day for a candidate every caller
   discarded. The third is not a naming complaint; it is what the wrong name
   let someone build. *)
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
