(** Typed request-authority admission shared by HTTP/1.1 and HTTP/2.

    A request entry point classifies its authority exactly once, rejects every
    non-[Single] result, and binds the admitted value for the lifetime of the
    request fiber.  Downstream auth and projection code consumes [authority]
    rather than re-reading wire headers. *)

type authority

type classification =
  | Missing
  | Single of authority
  | Multiple
  | Malformed

type h2_classification =
  | H2_authority of classification
  | Unsupported_asterisk_form_options

exception Unbound_request_authority

val classify_http1_request : Httpun.Request.t -> classification
(** Classify the case-insensitive HTTP/1.1 [Host] field set. *)

val classify_h2_request : H2.Request.t -> h2_classification
(** Classify HTTP/2 [:authority].  A same-authority [Host] field is accepted
    only as a cross-check; it is never used as the authority source.  Repeated
    [:authority], repeated [Host], or a scheme-normalized mismatch is
    [Malformed].  Authority-free [OPTIONS *] is reported separately because
    MASC does not implement asterisk-form routing. *)

val of_host_port : host:string -> port:int -> (authority, [ `Malformed ]) result
(** Validate a trusted configured host/port through the same authority parser.
    This is for synthetic background requests, not wire admission. *)

val host : authority -> string
val port : authority -> int option
val rendered : authority -> string

val equivalent_for_scheme :
  scheme:string -> authority -> authority -> bool
(** Compare normalized host and effective port.  [http] and [https] apply
    their standard default ports; IPv4/IPv6 textual aliases are canonicalized
    during parsing. *)

val with_current : authority -> (unit -> 'a) -> 'a
(** Bind an admitted authority to the current Eio request fiber. *)

val current : unit -> authority option
val current_exn : unit -> authority
(** Return the request-fiber authority or raise
    {!Unbound_request_authority}.  There is intentionally no raw-header or
    configured-host fallback. *)
