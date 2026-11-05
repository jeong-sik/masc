(** Where a fetch whose URL came from outside MASC may connect.

    WebFetch, the dashboard link preview and the OAuth client metadata fetch
    all connect to a URL that web content, a request or a model named. None of
    them may reach the host's own network: MASC's API and other services on
    loopback, the private network, link-local metadata addresses, or the
    special-purpose ranges in the IANA IPv4 and IPv6 special-purpose address
    registries (RFC 6890). One policy answers that question for all three
    (draft-ietf-oauth-client-id-metadata-document-00 section 6.5).

    A host name is admitted by the addresses it resolves to. The caller must
    connect to exactly the addresses {!resolve_allowed_host} returned for that
    host, so a second lookup cannot answer differently. Every redirect needs
    its own normalization, resolution and admission; the original host grants
    none. *)

type refusal =
  | Loopback
  | Unspecified
  | Private_network
      (** RFC 1918 IPv4, IPv6 unique local [fc00::/7], and the deprecated
          IPv6 site-local [fec0::/10]. *)
  | Shared_address_space  (** [100.64.0.0/10], RFC 6598 carrier-grade NAT. *)
  | Link_local  (** [169.254.0.0/16] and [fe80::/10]. *)
  | Multicast
  | Reserved
      (** Documentation, benchmarking, IETF protocol assignment, discard-only
          and the reserved [240.0.0.0/4] block, broadcast included. For IPv6,
          every address outside global unicast [2000::/3], and inside it
          [2001::/23], [2001:db8::/32], 6to4 [2002::/16] and [3fff::/20]. *)

val refusal_to_string : refusal -> string
(** A phrase for a reply a model or an operator reads, such as
    ["loopback address"]. *)

val ip_refusal : Ipaddr.t -> refusal option
(** [None] admits the address. An IPv4-mapped IPv6 address
    ([::ffff:a.b.c.d]) and a well-known-prefix NAT64 address
    ([64:ff9b::a.b.c.d], RFC 6052) are judged as the IPv4 address they
    carry. *)

val ipaddr_of_eio : Eio.Net.Ipaddr.v4v6 -> Ipaddr.t

val port_of_uri : Uri.t -> int
(** The URI's explicit port, else 443 for [https] and 80 otherwise. The
    scheme is compared case-insensitively. *)

type host_refusal =
  | Missing_host
  | Local_host_name  (** A loopback or unspecified name or literal. *)
  | No_address  (** The resolver answered without an address. *)
  | Resolver_failed of string  (** The resolver raised; the detail is for display. *)
  | Refused_address of refusal
  | Non_ip_address  (** The resolver answered with a Unix socket path. *)

val host_refusal_to_string : host_refusal -> string

val resolve_allowed_host :
  net:Eio_context.eio_net ->
  Uri.t ->
  (Eio.Net.Ipaddr.v4v6 list, host_refusal) result
(** [Ok] preserves the admitted address order and is never empty.
    Every resolved address must be admitted; one refused address refuses the
    host. The lookup runs in a system thread that cancellation cannot stop,
    so the system resolver bounds its duration. Cancellation of the caller
    propagates. *)
