(* The registry observation is process-local. Physical identity of a fresh
   allocation avoids both shared counters and reuse across continuation attempts.
   The reference is never mutated or exposed. *)
type t = unit ref
let fresh () = ref ()
let equal a b = a == b
