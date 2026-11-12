(* HIGH-RISK-UNREVIEWED: seals the secrets of logins in flight. A sealed
   transaction that another browser can read or change lets one person
   finish another's login, or spend their invitation. Nothing here stops a
   sealed transaction from being used twice: that rests on Google and on
   GitHub refusing a code they have exchanged. *)

(** Logins in flight, Google's and GitHub's (design 5.2 and 5.2.1, plans
    C2a-2, C2b-1b and S1a-3a-1).

    The start of a login draws its [state] and PKCE verifier, and for Google
    its nonce, from the CSPRNG of {!Random_id}. The server keeps none of
    them: it seals them, with where the login returns and what it replaces,
    under a key of the process, and the browser carries the sealed text
    (plan C3 puts it in [__Host-masc_oidc_txn], for both providers). The
    provider carries [state] back to the callback, which opens the sealed
    text and compares the two. The seal is ChaCha20-Poly1305 (RFC 8439), so
    the browser and the provider read only the challenge, and for Google the
    nonce sent to it, and a text with a changed byte does not open.

    Nothing is held per login, so a start is never refused for the logins of
    others: a request with no credential can start a login, and one that
    starts many takes nothing from the next person.

    A sealed transaction knows the flow that started it, and the callback of
    one flow does not open the transaction of another. It opens for
    {!lifetime_ms} after its start, by the [now_ms] of each call. A clock
    that is set back keeps it open that much longer, and one set forward
    ends the logins in flight.

    It can be opened more than once in that time: the server does not
    remember that it was opened. What a second callback could spend is
    spent once elsewhere. The provider takes a code once, so a second
    exchange is refused there, and the log takes an invitation once
    ({!Authz_login.sign_in}). The answer of a callback clears the cookie
    of the browser whatever it found ({!Login_routes.callback}), so a
    browser sends a sealed transaction to one callback.

    The key lives as long as the process: a login that started before a
    restart does not open after it, and starts again.

    The nonce of a seal is the count of seals of this key, and it goes in
    the clear at the head of the sealed text. A count never comes twice, as
    the seal requires. Whoever starts a login reads how many logins this
    process has started.

    No network. *)

(** The token of an invitation link ([<base url>/accounts/invite#<token>],
    plan B3d-1), sent by the form of the invitation screen. Nothing prints
    it and nothing seals it: the only function out of it is its digest,
    which is what a transaction carries, so the token reaches no log, query
    string, cookie, or error text (design 5.1-4). *)
module Invite_token : sig
  type t

  (** [Some] for 64 lowercase hex characters, the token that
      {!Authz_activation} makes. *)
  val of_form : string -> t option

  val digest : t -> Authz_invite_event.Token_digest.t
end

(** Where the browser goes after the login: a path of this host (design 5.2).
    It is read as an RFC 3986 [path-absolute] with an optional query, not
    matched by prefix. A scheme, an authority ([//host]), a fragment, or a
    character outside the grammar (a backslash, a space, a control character,
    a [%] not followed by two hex digits) is refused. A browser reads a
    backslash as [/], so a slash and a backslash before a host name would
    leave this host. *)
module Local_path : sig
  type t

  val of_string : string -> t option
  val to_string : t -> string

  (** ["/"]. *)
  val root : t
end

(** A sealed transaction, as the browser carries it: unpadded base64url of
    the nonce, the sealed bytes and the tag, at most {!max_sealed_length}
    characters. One text opens: another base64url text of the same bytes
    does not. *)
module Sealed : sig
  type t

  (** [Some] for 1 to {!max_sealed_length} characters of the base64url
      alphabet. It says nothing of the key: {!open_} does. *)
  val of_string : string -> t option

  val to_string : t -> string
end

(** 4000. A browser keeps at least 4096 bytes of a cookie with its name and
    its attributes (RFC 6265 section 6.1), and those of the transaction
    cookie are under 96 bytes.

    The HTTP/1 listener reads a header line of at most 4096 bytes, and the
    [Cookie] line of a callback carries every cookie that the browser sends
    this host. A sealed text is 400 to 650 characters with the return path
    [/] and grows by four characters for three of the path, so a login with
    a return path of thousands of characters, from a browser that sends
    other cookies as well, is a 400 at its callback. *)
val max_sealed_length : int

(** Ten minutes. A login that takes longer starts again. *)
val lifetime_ms : int

(** What only a Google login holds: the nonce its ID token must carry
    ({!Oidc_google.identity}). A GitHub login has no ID token and holds
    nothing more. *)
type google = { nonce : string }

(** The flow that starts a transaction, and with it what the transaction
    holds. *)
type _ flow =
  | Google : google flow
  | Github : unit flow

(** What the start of a login sends: the sealed transaction to the browser,
    the rest to the provider in the authorization request. [code_challenge] is the S256
    challenge of the verifier (RFC 7636 section 4.2). *)
type 'held started =
  { sealed : Sealed.t
  ; state : string
  ; code_challenge : string
  ; held : 'held
  }

(** What the callback gets back. *)
type 'held taken =
  { held : 'held
  ; code_verifier : string  (** Sent with the code to the token endpoint. *)
  ; invite : Authz_invite_event.Token_digest.t option
        (** The digest of the invitation the start came with. *)
  ; return_to : Local_path.t
  ; replaces : Authz_types.Session_id.t option
        (** The browser session that the browser held at the start, its
            cookie checked there (plan C3-8). The sign-in ends it in the
            record that issues the new session. The callback cannot read
            the session cookie itself: it is [SameSite=Strict], and the
            redirect back from the provider is a cross-site navigation that
            does not carry it, while the start is a same-origin [POST] that
            does. *)
  }

(** The key that seals the logins of a process. *)
type t

(** Draws a key from the CSPRNG. Two values do not open each other's
    transactions. *)
val create : unit -> t

type start_error =
  | Too_long
      (** The sealed transaction is longer than {!max_sealed_length}: the
          return path is too long for a cookie. *)

val start
  :  t
  -> now_ms:int
  -> 'held flow
  -> invite:Invite_token.t option
  -> return_to:Local_path.t
  -> replaces:Authz_types.Session_id.t option
  -> ('held started, start_error) result

type open_error =
  | Unknown
      (** The text was not sealed with this key, or a byte of it changed:
          another process sealed it, or nobody did. *)
  | Other_flow  (** Another flow started it. *)
  | Expired  (** It started {!lifetime_ms} or more before [now_ms]. *)
  | State_differs

val open_error_to_string : open_error -> string

(** Opens a sealed transaction and gives back what it carries if [flow]
    started it, it started less than {!lifetime_ms} before [now_ms], and
    [state] is its state, compared in constant time. *)
val open_
  :  t
  -> now_ms:int
  -> 'held flow
  -> Sealed.t
  -> state:string
  -> ('held taken, open_error) result
