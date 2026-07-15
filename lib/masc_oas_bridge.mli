(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Preserves cancellation safety and type isolation without adding a second
    wall-clock deadline around the OAS Provider transport. *)

(** Safe execution of a generic OAS operation. Re-raises structured
    cancellation and converts unexpected exceptions to typed SDK errors.
    Provider timeout errors pass through unchanged from [fn]. *)
val run_safe
  :  caller:string
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result

(** Typed-caller variant of {!run_safe}; it adds attribution only. *)
val run_with_caller
  :  caller:Env_config_oas_bridge.caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
