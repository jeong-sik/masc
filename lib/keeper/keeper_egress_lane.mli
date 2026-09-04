(** Resolving one keeper's egress allowlist from runtime.toml (RFC-0415).

    The same resolution {!Keeper_sandbox_ssh} does for an endpoint name, for
    the other half of the policy lane: a keeper names [network_mode =
    "policy"] and this reads what that mode permits it to reach. *)

val resolve_allowlist
  :  base_path:string
  -> keeper_name:string
  -> (Egress_host.rule list, string) result
(** The rules for [keeper_name], or a typed reason the lane cannot be served.

    An absent [\[egress.keepers.<name>\]] table is [Ok \[\]], not an error:
    an empty allowlist is a keeper that reaches nothing, which is a coherent
    thing to declare by omission and is what the lane does anyway when a
    listener has no rules. A missing or unparsable runtime.toml is an error,
    because then nothing is known -- including whether an allowlist was
    meant. *)

val listen_backlog : int
(** How many guest connections may queue before the accept loop takes them.
    One guest is behind this listener and a turn's tool calls are serial, so
    the queue exists for the burst a single turn makes, not for a fleet. *)

val request_line_read_timeout_s : float
(** How long a connected client has to send its CONNECT line. Bounds a client
    that connects and says nothing; it does not bound an admitted tunnel,
    which may be long-lived. *)

val listen_address : Eio.Net.Sockaddr.stream
(** Where a keeper's proxy binds: the loopback address, on a port the OS
    picks.

    Loopback rather than the host-only network's gateway because the guest
    reaches the host through NAT on that network, and binding the gateway
    address would tie the listener to a network that may not exist yet. The
    port is ephemeral because one is needed per keeper and a fixed range
    would be a second thing to keep in step with the roster. *)
