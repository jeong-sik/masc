(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    @since God file decomposition *)

open Keeper_internal_error

let capacity_backpressure_source_of_http_error = function
  | Llm_provider.Http_client.NetworkError
      { kind = Llm_provider.Http_client.Local_resource_exhaustion; _ } ->
    Some Runtime_slot
  | Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Capacity_exhausted _; _ } ->
    Some Provider_capacity
  | Llm_provider.Http_client.HttpError _
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.ProviderTerminal _
  | Llm_provider.Http_client.ProviderFailure _ ->
    None

let capacity_backpressure_of_http_error ?source ~runtime_id last_err =
  match last_err with
  | Some
      (Llm_provider.Http_client.ProviderFailure
         {
           kind =
             Llm_provider.Http_client.Capacity_exhausted
               { retry_after; _ };
           message;
         }) ->
    Some
      (Capacity_backpressure
         {
           runtime_id;
           source =
             Option.value source ~default:Provider_capacity;
           detail = message;
           retry_after =
             (match retry_after with
              | Some s -> Explicit s
              | None -> No_retry_hint);
           (* Genuine upstream capacity exhaustion, not a pre-dispatch health
              cooldown block — no arming cause to carry.  #23438. *)
           cooldown_cause = None;
         })
  | Some
      (Llm_provider.Http_client.NetworkError
         {
           kind = Llm_provider.Http_client.Local_resource_exhaustion;
           message;
         }) ->
    Some
      (Capacity_backpressure
         {
           runtime_id;
           source = Option.value source ~default:Runtime_slot;
           detail = message;
           retry_after = No_retry_hint;
           cooldown_cause = None;
         })
  | Some
      (Llm_provider.Http_client.HttpError _
      | Llm_provider.Http_client.NetworkError _
      | Llm_provider.Http_client.TimeoutError _
      | Llm_provider.Http_client.AcceptRejected _
      | Llm_provider.Http_client.ProviderTerminal _
      | Llm_provider.Http_client.ProviderFailure _)
  | None ->
    None

let capacity_backpressure_of_pending ~runtime_id = function
  | Some (source, detail, retry_after) ->
    Some
      (Capacity_backpressure
         {
           runtime_id;
           source;
           detail;
           retry_after;
           cooldown_cause = None;
         })
  | None -> None

(* [capacity_backpressure_of_sdk_error] was removed (#23438).  It classified an
   [Agent_sdk.Error.Internal msg] into [Capacity_backpressure] via a substring
   match ([message_looks_like_capacity_backpressure]) — a string classifier that
   laundered opaque internal errors into the permanently-transient (auto-
   recoverable, not-counting-toward-crash) class, the same failure mode that
   made deterministic cooldowns oscillate.  The typed [cooldown_cause] on the
   pre-dispatch gate replaces it; the function had no live callers. *)
