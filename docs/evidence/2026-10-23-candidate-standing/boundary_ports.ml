module Runtime_schema = struct type credential = Env of string | File of string | Inline of string end
module Env_config_core = struct let raw_value_opt _ = None end
module Runtime_account_home = struct let of_string text = Ok text let of_inherited text = Ok text end
module Agent_core = struct module Binding_identity = struct type t = string let equal = String.equal end end
module Keeper_runtime_failure_route = struct
  (* This ingress port accepts only prevalidated test hints. SDK hint validation
     and product path-rest calculation are excluded from this execution. *)
  let usable_retry_after hint = hint
end
module Llm_provider = struct
 module Http_client = struct
  type refusal_body = Received of string | Not_received_in_window
  let refusal_body_text = function Received text -> text | Not_received_in_window -> ""
  type provider_failure_kind =
   | Hard_quota of {retry_after:float option}
   | Capacity_exhausted of unit | Capability_mismatch of unit | Cli_policy_invalid of unit
   | Cli_startup_failed of unit | Provider_parse_error of unit | Provider_wire_error of unit
   | Provider_reported_error of unit | Provider_interrupted | Response_body_too_large of unit
   | Empty_completion of unit | Context_overflow of unit | Repeating_generation of unit
   | Unknown_provider_failure of unit
  type http_error =
   | HttpError of {code:int;body:refusal_body;retry_after_header:float option}
   | ProviderFailure of {kind:provider_failure_kind;message:string}
   | NetworkError of string | TimeoutError of string | AcceptRejected of unit | ProviderTerminal of unit
 end
 module Retry = struct
  type api_error = RateLimited of {retry_after:float option;message:string}
   | PaymentRequired of unit | Overloaded of unit | ServerError of unit | AuthError of unit
   | AuthorizationError of unit | InvalidRequest of unit | NotFound of unit | ContextOverflow of unit
   | InputCapacity of unit | NetworkError of unit | Timeout of unit
  let classify_refusal ~status:_ ~body:_ ~retry_after_header:_ =
    failwith "HTTP parser boundary deliberately unavailable in port execution"
  let resolve_retry_after ~body:_ ~header:_ =
    failwith "Retry-After parser boundary deliberately unavailable in port execution"
 end
end
