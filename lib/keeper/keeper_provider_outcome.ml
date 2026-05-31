(** Keeper_provider_outcome — provider call outcome type.

    Re-homed from the deleted [Cascade_fsm] module (RFC-0206 L2). The pure
    failover [decide] routing engine and its [Cascade_metrics]/
    [Cascade_health_filter] dependencies were intentionally dropped: they had
    no live callers under single-binding. See the .mli for the full rationale. *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response [@tla.symbol "call_ok"]
  | Call_err of Llm_provider.Http_client.http_error [@tla.symbol "call_err"]
  | Accept_rejected of {
      response : Llm_provider.Types.api_response;
      reason : string;
    }
      [@tla.symbol "accept_rejected"]
[@@deriving tla]

let provider_outcome_to_string = function
  | Call_ok _ -> "call-ok"
  | Call_err _ -> "call-err"
  | Accept_rejected _ -> "accept-rejected"

let provider_outcome_option_to_string = function
  | Some outcome -> "some-" ^ provider_outcome_to_string outcome
  | None -> "none"
