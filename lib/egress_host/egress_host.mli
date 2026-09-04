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
    {!matches}. *)

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
    {!matches} keeps them apart, so a name rule can never answer for an
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
(** One allowlist entry. Either an exact host, or a wildcard [*.example.com]
    that admits subdomains and not the apex. *)

val rule_of_string : string -> (rule, parse_error) result
(** Parse one allowlist entry. [*.example.com] is a wildcard; every other
    spelling is exact, and is parsed by the same rules as a destination, so
    an entry a resolver could read differently is refused at config load
    rather than at match time. *)

val rule_to_string : rule -> string
(** The normalized spelling of the rule. *)

val matches : rule -> t -> bool
(** Whether this rule admits this destination.

    An exact rule admits only the identical normalized name, or the
    identical IP literal. A wildcard admits a strict subdomain and refuses
    the apex, so [*.example.com] answers for [api.example.com] and not for
    [example.com]. A wildcard never answers for an IP literal.

    Matching is on parsed labels, not on string suffix: [notexample.com]
    cannot be admitted by [*.example.com] the way an [endsWith] check would
    admit it. *)

val admits : rule list -> t -> bool
(** Whether any rule admits the destination. An empty list admits nothing:
    a keeper whose allowlist parsed to nothing reaches nothing, rather than
    reaching everything. *)
