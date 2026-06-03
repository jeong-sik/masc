(** See [Attribution_tagged.mli]. *)

type det
type nondet

(* Runtime representation is just the plain Attribution.t. The 'origin
   type variable is a phantom — carries compile-time information only. *)
type 'origin t = Attribution.t

(* --- Det constructors --- *)

let det_passed ~gate ~evidence : det t =
  Attribution.passed ~origin:Det ~gate ~evidence

let det_policy_failed ~gate ~evidence ~reason : det t =
  Attribution.policy_failed ~origin:Det ~gate ~evidence ~reason

let det_transition_blocked ~gate ~evidence ~from_state ~to_state ~reason : det t
    =
  Attribution.transition_blocked ~origin:Det ~gate ~evidence ~from_state
    ~to_state ~reason

let det_partial_pass ~gate ~evidence ~score ~rationale : det t =
  Attribution.partial_pass ~origin:Det ~gate ~evidence ~score ~rationale

(* --- NonDet constructors --- *)

(* NonDet Passed / Policy_failed carry an additional [rationale] beyond
   the underlying Attribution outcome fields. We fold it into [evidence]
   so the value round-trips through [Attribution.t]. *)
let fold_rationale_into_evidence (evidence : Yojson.Safe.t) ~rationale :
    Yojson.Safe.t =
  match evidence with
  | `Assoc fields -> `Assoc (fields @ [ ("rationale", `String rationale) ])
  | _other ->
    `Assoc [ ("original_evidence", evidence); ("rationale", `String rationale) ]

let nondet_passed ~gate ~evidence ~rationale : nondet t =
  let evidence = fold_rationale_into_evidence evidence ~rationale in
  Attribution.passed ~origin:NonDet ~gate ~evidence

let nondet_policy_failed ~gate ~evidence ~reason ~rationale : nondet t =
  let evidence = fold_rationale_into_evidence evidence ~rationale in
  Attribution.policy_failed ~origin:NonDet ~gate ~evidence ~reason

let nondet_partial_pass ~gate ~evidence ~score ~rationale : nondet t =
  Attribution.partial_pass ~origin:NonDet ~gate ~evidence ~score ~rationale

(* --- Erasure / introspection --- *)

let to_attribution (t : 'a t) : Attribution.t = t

let origin_of (t : 'a t) : Attribution.origin = t.origin
