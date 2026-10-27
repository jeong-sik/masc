(** The address check for an outbound fetch whose URL arrived in a request.

    The dashboard link preview and the OAuth client metadata fetch both
    fetch a URL a request named. Before connecting they resolve the host and
    refuse when any resolved address is loopback, unspecified, private,
    link-local, shared, multicast or reserved for documentation, so a
    request cannot point the server at its own network
    (draft-ietf-oauth-client-id-metadata-document-00 section 6.5).

    The HTTP client resolves the name again when it connects, so an answer
    that changes between the two lookups is not covered. *)

val ipaddr_is_private_or_reserved : Ipaddr.t -> bool
(** An IPv4-mapped IPv6 address ([::ffff:a.b.c.d]) is judged as the IPv4
    address it carries. *)

val validate_resolved_host :
  net:Eio_context.eio_net ->
  Uri.t ->
  (unit, string) result
(** [Error] names why the host was refused: no host, a loopback or
    unspecified name, an unresolvable name, or a refused address.
    Cancellation propagates. *)
