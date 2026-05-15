(** HTTP capacity probe selection for cascade runtime candidates.

    MASC does not decide probe eligibility by provider brand. A URL is probed
    only when a registered capacity probe claims it. *)

let of_provider_config (cfg : Llm_provider.Provider_config.t) =
  let base_url = String.trim cfg.base_url in
  if String.equal base_url ""
  then None
  else if Cascade_capacity_probe.can_probe ~url:base_url
  then Some base_url
  else None
;;
