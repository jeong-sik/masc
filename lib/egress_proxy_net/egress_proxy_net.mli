(** The socket half of the egress proxy: one listener per keeper.

    A keeper's guest sits on a host-only network with no route out except
    this listener, so the listener {i is} the keeper's whole reach. Which
    keeper is connecting is therefore the port it connected to, and no
    header or source address has to be trusted to answer that.

    Everything the allowlist decides lives in {!Egress_proxy_decision},
    which has no socket under it. This module carries bytes and records what
    it carried. *)

type outcome =
  | Admitted of { host : string; port : int }
  | Refused of { detail : string }
  | Upstream_failed of { host : string; port : int; detail : string }
      (** The request was admitted and the upstream connection did not
          open. Kept apart from a refusal: the allowlist said yes, so this
          is a fact about the network rather than about policy. *)
  | Unreadable of { detail : string }
      (** The client closed, timed out, or sent no line to judge. *)

val outcome_to_string : outcome -> string

type event =
  { keeper_name : string
  ; at : float
  ; outcome : outcome
  }
(** One request that reached the proxy. Every request produces one, admitted
    or not: the point of putting a proxy here is that a keeper's reach stops
    being unobserved, and an allowlist that only records its refusals still
    cannot answer "where did this keeper go". *)

val request_line_max_bytes : int
(** 8 KiB. A CONNECT authority that needs more than this is not a hostname,
    and the cap is what keeps a client from holding a fiber open by never
    sending a newline. *)

val serve
  :  sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> keeper_name:string
  -> rules:(unit -> Egress_host.rule list)
  -> on_event:(event -> unit)
  -> socket:[> [> `Generic ] Eio.Net.listening_socket_ty ] Eio.Resource.t
  -> read_timeout_s:float
  -> 'a
(** Serve on an already-bound socket until the switch is released. The
    return type says it does not return: the accept loop ends by the
    switch being cancelled, never by falling out. Accepts,
    judges one CONNECT, and on an admitted request copies bytes both ways
    until either side closes.

    The socket is the caller's because binding it is how the caller learns
    which port this keeper's guest must be pointed at, and because a test
    can then drive the real [serve] rather than a hatch opened for it.

    [rules] is asked once per request, not held for the life of the
    listener, so an operator's edit applies to the next connection rather
    than to the next lane restart. The sibling lane already works this way:
    {!Keeper_sandbox_ssh} re-reads its endpoint registry on every dispatch,
    and an egress allowlist that only reloaded on restart would be the same
    file behaving two ways.

    It is read per request rather than per connection because a tunnel
    outliving the policy that opened it is the one thing worse than a slow
    reload: the rules that admit a CONNECT are the rules in force when it is
    admitted, and the tunnel then runs to completion under them.

    What the thunk does when it cannot read is the caller's decision, not
    this module's.

    [on_event] is called once per request, before the tunnel opens rather
    than after it closes, so a long-lived tunnel is recorded when it is
    authorized rather than when it ends. *)

val resolve_upstream
  :  net:_ Eio.Net.t
  -> host:Egress_host.t
  -> port:int
  -> (Eio.Net.Sockaddr.stream, string) result
(** Resolve an admitted destination. Exposed because this is the only place
    a name becomes an address, and that ordering -- resolve after the
    allowlist, never before -- is what keeps the matcher and the resolver
    from reading different names. *)
