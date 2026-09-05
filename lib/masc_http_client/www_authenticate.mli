(** The WWW-Authenticate header, read by its grammar.

    RFC 9110 11.6.1 defines the field as a list of challenges:

    {v
    WWW-Authenticate = #challenge
    challenge        = auth-scheme [ 1*SP ( token68 / #auth-param ) ]
    auth-scheme      = token
    auth-param       = token BWS "=" BWS ( token / quoted-string )
    token68          = 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="
    quoted-string    = DQUOTE *( qdtext / quoted-pair ) DQUOTE
    quoted-pair      = %x5C ( HTAB / SP / VCHAR / obs-text )   ; %x5C is the backslash
    v}

    with [token] and [quoted-string] from 5.6.2 and 5.6.4, and the [#] list
    rule read as a recipient reads it (5.6.1.2): empty elements and optional
    whitespace around the commas are accepted.

    A challenge that has parameters is closed by the next list element that
    is a bare token, which is the next scheme; the grammar itself leaves
    that boundary to the reader, and this is the reading every browser
    settles on. *)

(** What follows the scheme. A challenge carries one of the two, never
    both: [Token68 "abc=="] is a whole credential, [Params] is a list. *)
type credentials =
  | Params of (string * string) list
      (** Parameter names as written -- compare them without regard to case,
          11.1 says they carry none -- and values with the quoting already
          removed, so a token value and a quoted one read the same. *)
  | Token68 of string

type challenge = {
  scheme : string;  (** as written; 11.1 makes scheme names case-insensitive *)
  credentials : credentials;
}

(** Where a value stops being a WWW-Authenticate header. Each carries the
    byte offset into the value where the grammar was not met. *)
type fault =
  | No_challenge  (** only whitespace and commas; the field needs one *)
  | Expected_token of int  (** a scheme or a parameter name should start here *)
  | Expected_delimiter of int
      (** after a scheme, a token68 or a value only a comma, whitespace or
          the end may follow *)
  | Param_before_scheme of int  (** [name=value] with no scheme before it *)
  | Param_after_token68 of int  (** a challenge holds either, not both *)
  | Expected_value of int  (** the equals sign is followed by neither form *)
  | Bad_quoted_character of int  (** a control character inside quotes *)
  | Bad_quoted_pair of int  (** a backslash not followed by one quotable octet *)
  | Unterminated_quoted_string of int  (** offset of the quote that never closes *)

val fault_to_string : fault -> string

val parse : string -> (challenge list, fault) result
(** [parse value] reads one header value into its challenges, in the order
    they were written. Nothing is guessed: a value the grammar does not
    cover is an [Error] naming where it stopped, never a shorter list. *)

val find_param : challenge list -> scheme:string -> name:string -> string option
(** [find_param challenges ~scheme ~name] is the value of [name] in the
    first challenge under [scheme] that carries it, both compared without
    regard to case. A challenge under [scheme] that lacks the parameter is
    passed over; the next one may carry it. *)

val resource_metadata_of_headers : (string * string) list -> string option
(** RFC 9728 5.1: where a protected resource says its metadata is. The
    value of [resource_metadata] in the first Bearer challenge that names
    it, across every WWW-Authenticate header in [headers] in order; the
    header name is matched without regard to case. Bearer because that is
    the scheme this client presents, so that is the challenge answering it.
    A header value that fails [parse] names nothing. *)
