(** The retained dynamic-tool results an official-client run carries
    ({!Keeper_client_tool_outbox.run_carrier}), in the form the last recorded
    outcome of its session calls for. *)

val load :
  keeper_name:string ->
  superseded:Keeper_official_client_session_store.superseded_size_refusal ->
  Keeper_client_tool_outbox.run_carrier ->
  (Keeper_client_tool_outbox.snapshot * Keeper_client_tool_outbox.carrier, string) result
(** The run's snapshot and carrier, as
    {!Keeper_client_tool_outbox.run_carrier_load} returns them.

    A run that takes the place of a session refused for its size
    ([Supersedes_size_refusal]) makes the switch of
    {!Keeper_client_tool_outbox.switch_to_address} before its first request.
    Every other run starts [Inline], and the capacity-refusal hook switches it
    when a provider refuses a request before any effect.

    The condition is the hook's: the carrier holds a receipt and its
    [By_address] text is strictly shorter. Neither asks whether the receipts
    were what the vendor refused.

    A size refusal recorded after a response or a tool effect, or on a
    continuation only that session could carry, ended a run that could not
    send again: its hook never ran. One recorded before any effect
    ([Bootstrap_floor_exceeded]) ended a run whose hook had run and had
    nothing left to shorten. In both the session record is what tells the
    next run of the refusal, and a run that started [Inline] there would send
    the receipts the refused turn carried and those it added (RFC
    retained-results-carrier-shrinks-to-an-address 5.5).

    A switch that fails leaves the carrier [Inline] and the run goes on, with
    a warning under [keeper_name] that carries the failure. The run then
    sends the request it sent before this rule; ending it here, before its
    claim, would leave the record standing and end every later run at the
    same step. If a provider refuses that request for its size before any
    effect, the hook makes the same step and fails again; the run then ends
    with the provider's size refusal, and the failure of the step is in the
    warning only. A failed load is returned as it is.

    Every attempt of a run gets the carrier its first load made, so a form
    switched here stays switched for the run. *)
