(** Resolving one keeper's egress allowlist from runtime.toml (RFC-0415).

    The same resolution {!Keeper_sandbox_ssh} does for an endpoint name, for
    the other half of the policy lane: a keeper names [network_mode =
    "policy"] and this reads what that mode permits it to reach. *)

val resolve_config_path : base_path:string -> keeper_name:string -> (string, string) result
(** Which runtime.toml governs this keeper.

    Answered once, when the lane starts, and never again: the workspace file
    or the global one is a fact about the deployment, not about a request.
    Deciding it per read put the choice inside the window an editor opens
    when it saves by temp-and-rename, so a request landing in that window was
    answered by a different file and then cached as though it were the
    keeper's own rules. *)

val read_allowlist
  :  config_path:string
  -> keeper_name:string
  -> (Egress_host.rule list, string) result
(** The rules for [keeper_name] as [config_path] currently spells them, or a
    typed reason they cannot be read.

    An absent [\[egress.keepers.<name>\]] table is [Ok \[\]], not an error:
    an empty allowlist is a keeper that reaches nothing, which is a coherent
    thing to declare by omission and is what the lane does anyway when a
    listener has no rules. A missing or unparsable runtime.toml is an error,
    because then nothing is known -- including whether an allowlist was
    meant. The caller decides what to serve while that lasts. *)

val listen_backlog : int
(** How many guest connections may queue before the accept loop takes them.
    One guest is behind this listener and a turn's tool calls are serial, so
    the queue exists for the burst a single turn makes, not for a fleet. *)

val request_line_read_timeout_s : float
(** How long a connected client has to send its CONNECT line. Bounds a client
    that connects and says nothing; it does not bound an admitted tunnel,
    which may be long-lived. *)

val listen_address : Eio.Net.Sockaddr.stream
(** Where a keeper's proxy binds: every interface, on a port the OS picks.

    Loopback was wrong, and measured wrong rather than argued: a guest on the
    host-only network reaches the host at that network's gateway address, and
    a listener bound to 127.0.0.1 answers such a connection with
    [Connection refused] (container 1.3.1, 2026-09-05 — a listener on
    0.0.0.0 answered the same request from the same guest). A policy keeper
    with a loopback-bound proxy therefore reached nothing at all.

    Binding every interface is what the guest can reach. It is not a wider
    boundary than the lane already has: the port carries one keeper's
    allowlist, and every request across it is judged and recorded whoever
    opened it.

    The port is ephemeral because one is needed per keeper and a fixed range
    would be a second thing to keep in step with the roster. *)
