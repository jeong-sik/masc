(* Boundary redaction SSOT — see boundary_redaction.mli for contract. *)

type public_label = string

let runtime_provider_label : public_label = "runtime"
let runtime_model_label : public_label = "runtime"
let unknown_model_label : public_label = "unknown_model"

let to_string (label : public_label) : string = label

(* Redacted lane label emitted to external observability metric labels
   ("model" / "model_used"). SSOT for the identical
   [to_string runtime_model_label] expression previously duplicated at keeper
   emit sites (RFC-0132 §3 / PR-2 boundary). *)
let runtime_lane_label : public_label = runtime_model_label
