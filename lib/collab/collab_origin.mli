(** Relay origin parsing for collab links (RFC-0471).

    Both sides of a share name the relay as a bare origin: the host
    trigger validates the operator's [base_url], and the guest resolves
    the relay from a web link or [--relay]. One parser serves both so
    the two can never disagree on what an origin is; the scheme sets
    differ (the host mints http(s) links, the guest dials ws(s)), so
    the caller names its schemes and maps them afterwards. *)

type origin = {
  scheme : string;  (** Lowercased, one of the admitted [schemes]. *)
  host : string;  (** As carried: no brackets, no port, no case fold. *)
  port : int option;
}

type parse_error =
  | Blank
  | Bad_scheme of string option
  | Missing_host
  | Bad_port
  | Has_userinfo
  | Has_path of string
  | Has_query
  | Has_fragment
  | Has_whitespace

val parse_error_to_string : parse_error -> string

val parse : schemes:string list -> string -> (origin, parse_error) result
(** [parse ~schemes raw] reads [scheme://host[:port)] and nothing else:
    no userinfo, no path past ["/"], no query, no fragment. Leading and
    trailing whitespace is trimmed; inner whitespace is refused rather
    than stripped. A port past [65535] or below [1] is [Bad_port]. *)

val to_string : origin -> string
(** [scheme://host[:port)], bracketing IPv6 literals. Carries no
    trailing slash, so {!Collab_link.format_web_link} takes it as [base]
    unchanged. *)
