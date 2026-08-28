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
(* Naming, and why it stays: [Keeper_id] and [Validation.Agent_id] read like
   siblings -- keeper's id versus agent's id -- and they are not. They sit on
   different axes.

     [Validation.Agent_id]  "is this string usable as an id at all"
                            length, path separators, "..", character set.
                            A gate. Refuses input.
     [Keeper_id]            "are these two names the same actor"
                            trim + lowercase. A fold. Refuses nothing but "".

   So [Keeper_id.of_string] is not the keeper-flavoured validator its name
   suggests; swapping a validation call to it drops four security checks and
   the compiler says nothing, because both sides are [string]. Measured
   2026-08-28 while chasing why edgar.a.poe could not claim its own task: that
   misreading was made twice in one session before the code was read.

   Renaming to say the axis out loud (shape-check vs comparison-key) would
   touch every call site of both modules, and the only evidence for it so far
   is one reader getting it wrong. Not enough. This comment is the cheap half:
   if you are here because the names confused you too, that is a second data
   point worth recording on the rename question. *)
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
