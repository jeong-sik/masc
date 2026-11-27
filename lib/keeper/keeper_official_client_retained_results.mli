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

    A size refusal that ends a session came after a response or a tool
    effect, or on a continuation only that session could carry: that run
    could not send again, so its hook never ran, and the session record is
    what tells the next run of the refusal. A run that started [Inline] there
    would send the receipts the refused turn carried and those it added (RFC
    retained-results-carrier-shrinks-to-an-address 5.5).

    A blob that cannot be written leaves the carrier [Inline] and the run
    goes on, with a warning under [keeper_name]. The run then sends the
    request it sent before this rule; ending it here, before its claim, would
    leave the record standing and end every later run at the same step. If a
    provider refuses that request for its size before any effect, the hook
    makes the same write and returns its error. A failed load is returned as
    it is.

    Every attempt of a run gets the carrier its first load made, so a form
    switched here stays switched for the run. *)
