let compaction_limit = function
  | Agent_sdk.Error.Api (Agent_sdk.Retry.InputCapacity { reason; _ }) ->
    (match reason with
     | Agent_sdk.Retry.Serving_constraint_rejected
         (Llm_provider.Serving_constraint.Input_rejected { accepted_through; _ }
         | Llm_provider.Serving_constraint.Boundary_unknown
             { accepted_through; _ }) ->
       Some accepted_through
     | Agent_sdk.Retry.Serving_constraint_rejected
         (Llm_provider.Serving_constraint.Evidence_not_yet_valid _
         | Llm_provider.Serving_constraint.Evidence_expired _)
     | Agent_sdk.Retry.Token_measurement_unavailable _ ->
       None)
  | Agent_sdk.Error.Api
      ( Agent_sdk.Retry.RateLimited _ | Agent_sdk.Retry.Overloaded _
      | Agent_sdk.Retry.ServerError _ | Agent_sdk.Retry.AuthError _
      | Agent_sdk.Retry.AuthorizationError _ | Agent_sdk.Retry.PaymentRequired _
      | Agent_sdk.Retry.InvalidRequest _ | Agent_sdk.Retry.NotFound _
      | Agent_sdk.Retry.ContextOverflow _ | Agent_sdk.Retry.NetworkError _
      | Agent_sdk.Retry.Timeout _ )
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> None
;;
