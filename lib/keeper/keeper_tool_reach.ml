type t =
  | Masc_state
  | Sandbox
  | Network
  | Model_provider

let to_wire = function
  | Masc_state -> "masc_state"
  | Sandbox -> "sandbox"
  | Network -> "network"
  | Model_provider -> "model_provider"
;;
