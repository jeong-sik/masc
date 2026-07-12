(** Runtime-boundary projection for provider inference defaults. *)

let agent_default_temperature =
  Llm_provider.Constants.Inference_profile.agent_default.temperature
;;

let worker_default_temperature =
  Llm_provider.Constants.Inference_profile.worker_default.temperature
;;

let deterministic_temperature =
  Llm_provider.Constants.Inference_profile.deterministic.temperature
;;

let max_error_body_length =
  Llm_provider.Constants.Truncation.max_error_body_length
;;
