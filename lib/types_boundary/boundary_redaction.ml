(* Boundary redaction SSOT — see boundary_redaction.mli for contract. *)

type public_label = string

let runtime_provider_label : public_label = "runtime"
let runtime_model_label : public_label = "runtime"

let to_string (label : public_label) : string = label
