(** The destination an egress allowlist judges, and the rule it judges with.

    A hostname arrives as bytes from a proxy request, and comparing those
    bytes with the allowlist as a string is how such an allowlist gets
    bypassed. Claude Code's sandbox compared SOCKS5 hostnames with a
    JavaScript [endsWith]: [attacker-host.com\x00.google.com] passed, because
    the matcher read the whole string while libc's [getaddrinfo] stopped at
    the null byte and resolved the attacker's host. One byte string, two
    parsers, and the gap between them is the bypass (sandbox-runtime
    <= 0.0.42, closed in 0.0.43).

    So nothing here compares strings. Bytes are parsed into {!t}, and a
    rule into {!rule}; both reject anything a resolver could read
    differently than this module does. A value that failed to parse is not a
    host that missed the allowlist -- there is no such value to hand
    [matches]. *)

type parse_error =
  | Empty  (** No bytes, or nothing left after trimming one trailing dot. *)
  | Too_long of { bytes : int }  (** Over 253 bytes, the DNS name ceiling. *)
  | Empty_label of { position : int }
      (** Two dots in a row, or a leading dot. [position] is the 0-based
          label index. *)
  | Label_too_long of { position : int; bytes : int }
      (** Over 63 bytes, the DNS label ceiling. *)
  | Label_edge_hyphen of { position : int }
      (** A label starting or ending with [-]. *)
  | Forbidden_byte of { offset : int; byte : char }
      (** A byte outside [a-z A-Z 0-9 . -]. This is the arm that refuses
          NUL, [%], CR and LF, and it names the offset so an operator can
          see where. *)

val parse_error_to_string : parse_error -> string
(** One line naming what was refused and where. Safe to log: it reports the
    offending byte as an escape, never raw. *)

(** {1 Destinations} *)

type t
(** A destination that parsed. Either a domain name or an IP literal --
    [matches] keeps them apart, so a name rule can never answer for an
    address. *)

val parse : string -> (t, parse_error) result
(** Parse one destination. Case is folded to lower, and a single trailing
    dot is dropped because a resolver treats [example.com.] and
    [example.com] as the same name. *)

val to_string : t -> string
(** The normalized spelling, for logs and evidence rows. *)

val is_ip_literal : t -> bool
(** Whether this destination is an address rather than a name. *)

(** {1 Rules} *)

type rule
(** One allowlist entry: a host and the port it may be reached on. Either an
    exact host, or a wildcard [*.example.com] that admits subdomains and not
    the apex. *)

val default_rule_port : int
(** 443, the port a rule means when it names none.

    A destination is a host and a port, and the port is part of what is
    permitted rather than a global constant: an operator with a service on
    8443 has to be able to say so, and one who writes only hostnames should
    not have to write [:443] after each. *)

val rule_of_string : string -> (rule, parse_error) result
(** Parse one allowlist entry, as [host] or [host:port].

    [*.example.com] is a wildcard; every other spelling is exact. The host
    half is parsed by the same rules as a destination, so an entry a resolver
    could read differently is refused at config load rather than at match
    time. An absent port means {!default_rule_port}.

    The port is split off before the host is parsed, and it is split at the
    last colon, so this module is the one place that decides which bytes are
    the host -- a second splitter elsewhere could disagree with this one, and
    a disagreement about that boundary is what an allowlist bypass is. *)

val rule_to_string : rule -> string
(** The normalized spelling of the rule. *)

val equal_rule : rule -> rule -> bool
(** Structural equality on the parsed form, so two spellings of the same
    rule compare equal. *)

val pp_rule : Format.formatter -> rule -> unit
(** Prints {!rule_to_string}. Present so a rule can sit in a config record
    that derives [show] and [eq] without the record having to hold raw
    strings beside the parsed form. *)

val rule_port : rule -> int
(** The port this rule permits. *)

val admits : rule list -> t -> port:int -> bool
(** Whether any rule admits the destination on the port. An empty list
    admits nothing: a keeper whose allowlist parsed to nothing reaches
    nothing, rather than reaching everything. *)

val admits_host : rule list -> t -> bool
(** Whether any rule names this host, on any port.

    Exposed so a refusal can tell "this host is not permitted" from "this
    host is permitted on another port". The second is an operator's rule
    missing a port; reporting it as the first sends them looking for the
    wrong mistake. *)

val ports_for_host : rule list -> t -> int list
(** The ports the rules permit for this host, so a refusal can name them. *)

val generation : rule list -> string
(** A short label for a set of rules, stable across processes and machines.

    The rules an egress decision was made under are read per request, so a
    log line saying "admitted" no longer says which allowlist admitted it: an
    operator's edit between two requests is invisible in the record, and a
    connection that should not have been possible cannot be traced to the
    rules that allowed it. This is what closes that -- two requests with the
    same generation were judged by the same rules, and a change in it is
    where an edit landed.

    Order and duplicates do not change it: the same rules written in another
    order are the same policy. It is a [Digest] (MD5) of the normalized
    spellings, truncated. That is an identity label and not a security
    claim -- a collision here mislabels a log line; it does not admit a
    connection, because nothing consults this value to decide anything. *)
