(** Durable handoff eligibility for a credential generation. New credentials
    start connected; explicit departure keeps the invitation valid for reopen.
    Every caller must retain its Auth admission through the associated DOS
    ownership effect. I/O runs off the Eio scheduler; unreadable state fails. *)
type t = Connected | Departed
val read : transaction:Auth.credential_transaction -> base_path:string ->
  Masc_domain.agent_credential -> (t, string) result
val write : transaction:Auth.credential_transaction -> base_path:string ->
  Masc_domain.agent_credential -> t -> (unit, string) result
val current : transaction:Auth.credential_transaction -> base_path:string ->
  name:string -> (t, string) result
(** A principal without a named credential has no browser departure marker. *)
