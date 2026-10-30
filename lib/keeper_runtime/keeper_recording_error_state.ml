(* Exact-message occurrence state for [Keeper_registry.record_error].

   This module intentionally does not classify free-form diagnostics. Typed
   producers own error categories; this leaf only counts identical
   [(keeper, error)] pairs for an observational repetition metric. *)

type record_outcome =
  [ `First
  | `Repeated of int
  ]

(* Fingerprint: keeper name + MD5 digest of the raw error string.
   MD5 is intentional — cryptographic strength is irrelevant; we want
   a short, stable identifier with negligible collision risk across
   <1k cardinality. *)
let fingerprint ~keeper ~error =
  Bounded_event_dedupe.key [ keeper; Digest.to_hex (Digest.string error) ]
;;

let state = Bounded_event_dedupe.create ~initial_capacity:256 ()

let record ~keeper ~error =
  let key = fingerprint ~keeper ~error in
  match Bounded_event_dedupe.record state ~key with
  | Bounded_event_dedupe.First -> `First
  | Bounded_event_dedupe.Repeated count -> `Repeated count
;;

let reset_for_test () =
  Bounded_event_dedupe.reset state
;;

let cardinality () =
  Bounded_event_dedupe.cardinality state
;;
