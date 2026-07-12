(** MASC runtime-catalog adapter for OAS typed tool-failure recovery.

    OAS owns episode detection, the closed decision schema, parsing, and
    validation. MASC owns runtime selection and provider fallback. This module
    joins those boundaries without exposing Keeper concepts to OAS. *)

val create
  :  base_path:string
  -> keeper_name:string
  -> Agent_sdk.Tool_failure_recovery.judge

module For_testing : sig
  type invoke =
    sw:Eio.Switch.t
    -> runtime_id:string
    -> base_path:string
    -> keeper_name:string
    -> system_prompt:string
    -> user_prompt:string
    -> provider_config_transform:
         (Llm_provider.Provider_config.t
          -> (Llm_provider.Provider_config.t, Agent_sdk.Error.sdk_error) result)
    -> (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result

  val completion
    :  resolve_runtime:(unit -> string)
    -> invoke:invoke
    -> base_path:string
    -> keeper_name:string
    -> Agent_sdk.Tool_failure_recovery.completion
end
