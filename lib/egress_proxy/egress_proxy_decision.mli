(** What the egress proxy decides about one CONNECT request, with no I/O.

    The decision is separated from the socket work because this is where the
    allowlist is enforced, and a security check that can only be exercised by
    opening a listener does not get exercised. Everything here is a function
    of the request line and the keeper's rules. *)

type refusal =
  | Malformed_request of string
      (** The request line is not a CONNECT this proxy will parse. Carries
          what was wrong, never the raw bytes. *)
  | Unparsable_host of Egress_host.parse_error
      (** The authority is not a host this proxy will resolve. A destination
          a resolver could read differently than the matcher does is refused
          here rather than admitted and resolved later. *)
  | Port_not_allowed of
      { host : string
      ; port : int
      ; allowed : int list
      }
      (** The host is in the allowlist and this port is not. Kept apart from
          {!Not_in_allowlist} and carrying the ports that are permitted,
          because this refusal is an operator's rule missing a port and
          reporting it as an unlisted host sends them looking for the wrong
          mistake. *)
  | Not_in_allowlist of { host : string }
      (** The destination parsed and no rule names it at all. [host] is the
          normalized spelling, safe to record. *)

val refusal_to_string : refusal -> string
(** One line for the evidence row and the 403 body. Contains no raw request
    bytes. *)

val client_env : proxy_url:string -> (string * string) list
(** The environment a client needs to find this proxy, as [(name, value)]
    pairs.

    Every spelling the common clients read, because they do not agree: curl
    and wget take the lower-case names, many Go and Java clients take the
    upper-case ones, and [gh] inherits whichever its libc build honours.
    Setting one and not the other is how a keeper reaches the proxy for [git]
    and silently finds no route for [gh].

    [NO_PROXY] is deliberately absent: an exception list here would be a
    second allowlist, one this proxy never sees and cannot record.

    This is convenience, not enforcement. On the policy lane a client that
    ignores these finds no route rather than a way around, because the
    enforcement point is the guest's network and not this list. *)

type decision =
  | Admitted of
      { host : Egress_host.t
      ; port : int
      }
  | Refused of refusal

val decide : rules:Egress_host.rule list -> request_line:string -> decision
(** Judge one request line, e.g. [{|CONNECT api.github.com:443 HTTP/1.1|}].

    The port is judged by the rule that names the host rather than against a
    constant. An allowlist of destinations has to be able to say which port
    a destination is reached on: pinning one meant an operator with a service
    on 8443 could not use the lane at all, and the refusal read as permanent
    policy rather than as a missing feature.

    The authority is split by {!Egress_host.rule_of_string}'s own splitter,
    so one place decides which bytes are the host. A second splitter here
    could disagree with that one, and a disagreement about that boundary is
    what an allowlist bypass is. *)

val response_of_decision : decision -> string
(** The bytes written back: [200 Connection Established] for an admitted
    request, or a [403] naming the refusal. Both end the headers, so a client
    that ignores the status still sees a closed tunnel rather than a hang. *)
