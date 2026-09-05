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

type freshness =
  | Fresh  (** The allowlist was read for this request. *)
  | Serving_last_good
      (** The read failed and the caller handed back the last set that
          parsed. The rules are real -- they are the reach an operator last
          successfully granted -- but they are not what the file says now. *)

type ruleset =
  { rules : Egress_host.rule list
  ; freshness : freshness
  }
(** What {!serve} is handed per request. The freshness travels with the rules
    rather than being asked for separately, so a caller cannot report a
    generation without saying whether the file behind it could be read. *)

type rules_in_force =
  { generation : string
  ; freshness : freshness
  }
(** The allowlist a request was judged against, as it goes into the record. *)

val rules_in_force_to_string : rules_in_force -> string
(** [<generation>] when fresh, [<generation>-stale] when not, so a log line
    stays greppable by generation either way. *)

type event =
  { keeper_name : string
  ; at : float
  ; outcome : outcome
  ; rules_in_force : rules_in_force option
        (** The rules that judged this request, or [None] where none did --
            an accept that failed, or a client that sent nothing to judge.

            The rules are read per request, so without this a record of
            "admitted" cannot say which allowlist admitted it: an operator's
            edit between two requests leaves no mark, and a destination that
            should not have been reachable cannot be traced back to the rules
            that allowed it. Two events with the same value were judged by
            the same rules.

            The freshness is here rather than only in a warning line because
            a stale set hashes to a perfectly ordinary generation. Reading
            "the generation changed here, so that is where the edit landed"
            off a log that cannot say the file was unreadable gets the
            opposite answer in exactly the case worth catching -- and a
            keeper with no traffic writes no warning at all. *)
  }
(** One request that reached the proxy. Every request produces one, admitted
    or not: the point of putting a proxy here is that a keeper's reach stops
    being unobserved, and an allowlist that only records its refusals still
    cannot answer "where did this keeper go". *)

module For_testing : sig
  val address_failed_to_answer : exn -> bool
  (** Whether a failed connect earns trying the next address.

      Pinned because the answer is not readable from this file: eio wraps
      what a connect returns but creates the socket outside that wrapping, so
      the case the address list exists for -- an AAAA record leading on a
      machine with IPv6 off -- arrives as a bare [Unix.Unix_error] rather
      than [Eio.Io]. Narrowing this to the readable half once already turned
      that address into the end of the whole attempt. *)
end

val serve
  :  sw:Eio.Switch.t
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> keeper_name:string
  -> rules:(unit -> ruleset)
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

