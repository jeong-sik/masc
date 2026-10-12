(** Durable handoff eligibility per agent name. The state file is keyed by
    agent name, so a credential renewal (a new token under the same name)
    keeps an explicit departure instead of orphaning it. New credentials
    start connected; explicit departure keeps the invitation valid for
    reopen. I/O runs off the Eio scheduler; unreadable state fails. *)
type t = Connected | Departed
val read : base_path:string -> Masc_domain.agent_credential -> (t, string) result
val write : base_path:string -> Masc_domain.agent_credential -> t -> (unit, string) result
val current : transaction:Auth.credential_transaction -> base_path:string ->
  name:string -> (t, string) result
(** A principal without a named credential has no browser departure marker.
    Neither has a [Worker] credential: Workers are agents' MCP clients, not
    seats, so their state is always [Connected] and no record is read. *)
