(** Durable handoff eligibility per agent name. The state file is keyed by
    agent name, so a credential renewal (a new token under the same name)
    keeps an explicit departure instead of orphaning it; a newly issued
    credential under an existing name inherits that name's last recorded
    state, starting [Connected] when no record exists. Explicit departure
    keeps the invitation valid for reopen. Every caller must retain its Auth
    admission through the associated DOS ownership effect. I/O runs off the
    Eio scheduler; unreadable state fails. *)
type t = Connected | Departed
val read : transaction:Auth.credential_transaction -> base_path:string ->
  Masc_domain.agent_credential -> (t, string) result
val write : transaction:Auth.credential_transaction -> base_path:string ->
  Masc_domain.agent_credential -> t -> (unit, string) result
val current : transaction:Auth.credential_transaction -> base_path:string ->
  name:string -> (t, string) result
(** A principal without a named credential has no browser departure marker.
    Neither has a [Worker] credential: Workers are agents' MCP clients, not
    seats, so their state is always [Connected] and no record is read. *)
