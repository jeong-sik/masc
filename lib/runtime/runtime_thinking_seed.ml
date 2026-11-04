type t =
  { thinking_enabled : bool option
  ; preserve_thinking : bool option
  }

let absent = { thinking_enabled = None; preserve_thinking = None }

let of_model (model : Runtime_schema.model_spec) =
  { thinking_enabled = Runtime_schema.thinking_request model
  ; preserve_thinking = model.preserve_thinking
  }
;;

(* The two fields merge differently, as [Keeper_turn_driver.attempt_inference_policy]
   does on the turn path: a declared [enable_thinking] wins and an absent one
   leaves the request's value, while [preserve_thinking] has no fallback. The
   turn writes the seed's [preserve_thinking] into its agent config as is, so a
   request built here must not keep the config's value either. *)
let apply seed (config : Llm_provider.Provider_config.t) =
  { config with
    enable_thinking =
      (match seed.thinking_enabled with
       | Some _ as declared -> declared
       | None -> config.enable_thinking)
  ; preserve_thinking = seed.preserve_thinking
  }
;;
