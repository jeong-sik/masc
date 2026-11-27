(** The retained dynamic-tool results an official-client run carries
    ({!Keeper_client_tool_outbox.run_carrier}), in the form the last recorded
    outcome of its session calls for. *)

val load :
  superseded:Keeper_official_client_session_store.superseded_input_rejection ->
  Keeper_client_tool_outbox.run_carrier ->
  (Keeper_client_tool_outbox.snapshot * Keeper_client_tool_outbox.carrier, string) result
(** The run's snapshot and carrier, as
    {!Keeper_client_tool_outbox.run_carrier_load} returns them.

    A run that supersedes a session refused for its size
    ([Superseding_effect_fenced], [Superseding_bootstrap_floor_exceeded])
    carries the receipts by address from its first request
    ({!Keeper_client_tool_outbox.run_carrier_load_by_address}). Every other
    run starts [Inline], and the capacity-refusal hook switches it when a
    provider refuses a request before any effect.

    A refusal that fences a session came after the turn had a response or a
    tool effect: that run could not send again, so its hook never ran. The
    session record is what tells the next run of the refusal. A superseding
    run that starts [Inline] sends the receipts the refused turn carried and
    those it added (RFC retained-results-carrier-shrinks-to-an-address 9 and
    11.7).

    Every attempt of a run gets the carrier its first load made, so a form
    switched here stays switched for the run. *)
