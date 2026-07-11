(** Typed request-authority admission shared by HTTP/1.1 and HTTP/2.

    A request entry point classifies its authority exactly once against the
    configured listener/base-URL identities, rejects every non-[Single]
    result, and binds the admitted value for the lifetime of the request
    fiber.  The abstract [authority] is the admitted request context: it keeps
    the typed scheme and trust provenance alongside host/port so downstream
    origin/auth code cannot reconstruct either from raw headers. *)

type scheme =
  | Http
  | Https

type trust_class =
  | Configured_bind
  | Explicit_trusted_host

type authority
(** Backward-compatible name for the admitted host/port projection. *)

type request_context = authority
(** The live request context: typed scheme + admitted authority + trust class.
    The alias keeps existing projection APIs source-compatible while making
    the security boundary explicit at classifiers and fiber binding sites. *)

type trust_policy

type trust_policy_error =
  | Malformed_bind_authority
  | Malformed_explicit_base_url

val make_trust_policy :
  bind_host:string ->
  bind_port:int ->
  explicit_base_url:string option ->
  (trust_policy, trust_policy_error) result
(** Build the only live-request Host trust policy.  [bind_host]/[bind_port]
    are the actual listener identity and [explicit_base_url] is the configured
    public identity (normally [MASC_HTTP_BASE_URL]).  No request header is a
    trust-policy input. *)

val trust_policy_error_to_string : trust_policy_error -> string

type classification =
  | Missing
  | Single of request_context
  | Multiple
  | Malformed
  | Untrusted

type h2_classification =
  | H2_authority of classification
  | Unsupported_asterisk_form_options

exception Unbound_request_authority

val classify_http1_request :
  trust_policy:trust_policy -> Httpun.Request.t -> classification
(** Classify the case-insensitive HTTP/1.1 [Host] field set, then admit it only
    when it is the configured bind identity (HTTP) or the explicit base-URL
    identity (whose HTTP(S) scheme is preserved). *)

val classify_h2_request :
  trust_policy:trust_policy -> H2.Request.t -> h2_classification
(** Classify HTTP/2 [:authority].  A same-authority [Host] field is accepted
    only as a cross-check; it is never used as the authority source.  Repeated
    [:authority], repeated [Host], an unsupported [:scheme], or a
    scheme-normalized mismatch is [Malformed].  A syntactically valid but
    unconfigured identity is [Untrusted].  Authority-free [OPTIONS *] is
    reported separately because MASC does not implement asterisk-form routing. *)

val of_host_port : host:string -> port:int -> (authority, [ `Malformed ]) result
(** Validate a trusted configured host/port through the same authority parser.
    This is for synthetic background requests, not wire admission. *)

val host : authority -> string
val port : authority -> int option
val scheme : authority -> scheme
val scheme_to_string : scheme -> string
val trust_class : authority -> trust_class
val rendered : authority -> string

val equivalent_for_scheme :
  scheme:scheme -> authority -> authority -> bool
(** Compare normalized host and effective port.  [http] and [https] apply
    their standard default ports; IPv4/IPv6 textual aliases are canonicalized
    during parsing. *)

type serialized_origin

val parse_serialized_origin :
  string -> (serialized_origin, [ `Malformed ]) result
(** Parse exactly one RFC 6454 HTTP(S) serialized origin.  The parser consumes
    the complete field value and rejects OWS, userinfo, path, query, fragment,
    trailing bytes, and non-HTTP(S) schemes. *)

val serialized_origin_host : serialized_origin -> string
val serialized_origin_scheme : serialized_origin -> scheme

val serialized_origin_equal :
  serialized_origin -> serialized_origin -> bool
(** Exact scheme/normalized-host/effective-port equality. *)

val serialized_origin_matches_authority :
  serialized_origin -> authority -> bool
(** Exact scheme/normalized-host/effective-port equality against the admitted
    request context.  Loopback aliases are deliberately not collapsed. *)

val with_current : request_context -> (unit -> 'a) -> 'a
(** Bind an admitted authority to the current Eio request fiber. *)

val current : unit -> request_context option
val current_exn : unit -> request_context
(** Return the request-fiber authority or raise
    {!Unbound_request_authority}.  There is intentionally no raw-header or
    configured-host fallback. *)
