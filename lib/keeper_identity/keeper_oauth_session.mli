(** One Keeper's login, from the operator pressing a key to the tokens coming
    back.

    Two halves with a browser in the middle. {!start} asks the server where
    its authorization lives, registers a client if nobody configured one,
    builds the URL the operator opens, and holds what the second half will
    need. {!finish} is what the callback calls.

    It does not store anything. The tokens come back as a value and the
    caller writes them where a Keeper's credentials live, because that is a
    layer up from here: this library knows about an exchange, not about
    Keepers having secret directories. *)

type start_error =
  | Discovery_failed of Keeper_oauth_discovery.error
  | Registration_failed of Keeper_oauth_registration.error
  | No_pkce_s256 of string
      (** The server publishes no S256 challenge method. Refused rather than
          downgraded: without PKCE the authorization code is bearer material
          sitting in a redirect, and a public client has no secret to fall
          back on. Carries the issuer, because that is what an operator
          would go look at. *)
  | No_registration of string
      (** Nobody configured a client id and the server offers no way to get
          one. Carries the issuer for the same reason. *)

val start_error_to_string : start_error -> string

type started = {
  authorize_url : string;  (** where the operator has to go *)
  state : string;
      (** What the callback will echo. Returned so a caller can show which
          login it is waiting on without reaching into the table. *)
  credentials : Keeper_oauth_client_store.credentials;
      (** What the exchange will be redeemed with. A secret is here when the
          server answered registration with one, which is how a confidential
          client is recognised -- the metadata cannot be read for it: Vercel
          and Hugging Face both omit "none" from the methods they publish and
          both register a public client. *)
  registered_now : bool;
      (** True when this call had to register the client. The caller should
          persist [credentials] when so; otherwise every login registers
          again and leaves a client record behind each time. *)
}

val start :
  ?discover:(mcp_url:string -> (Keeper_oauth_discovery.t, Keeper_oauth_discovery.error) result) ->
  ?register:
    (registration_url:string ->
     client_name:string ->
     redirect_uri:string ->
     (Keeper_oauth_registration.registered, Keeper_oauth_registration.error) result) ->
  provider:Keeper_oauth_provider.t ->
  configured:Keeper_oauth_client_store.credentials option ->
      (** What this install already registered, if anything. Reused rather
          than registering again, which would leave a second client behind on
          a server nobody here administers. *)
  client_name:string ->
  redirect_uri:string ->
  keeper:string ->
  pending:Keeper_oauth_pending.t ->
  now:float ->
  ttl_sec:float ->
  unit ->
  (started, start_error) result

type finish_error =
  | Unknown_state
      (** No exchange is waiting on this state. A replayed callback, a
          callback that took longer than the window, or one meant for a
          server that has since restarted -- all of which are the same thing
          to whoever is looking at the browser, and none of which can be
          redeemed. *)
  | Exchange_failed of Keeper_oauth_flow.exchange_error

val finish_error_to_string : finish_error -> string

(** What the provider said about how long this credential lasts, and whether
    it handed over the means to keep it.

    Three shapes rather than two optional fields: the combination is what an
    operator has to be told about, and a pair of options leaves every reader
    working out which of four pairings it is looking at. *)
type expiry =
  | Never
      (** No stated expiry and no refresh token. Nothing to renew and
          nothing that stops on its own -- it lasts until the provider
          revokes it. Slack issues this for an app without token rotation. *)
  | Renewable of { expires_at : float option; refresh_token : string }
      (** A refresh token came back, so the credential can be replaced
          before or after it lapses. [expires_at] is when to go early;
          absent means the provider named no moment, so renewal waits for a
          call to fail rather than a clock. *)
  | Expiring_without_renewal of float
      (** States an expiry and carries no way to renew. This one stops
          working at that moment and leaves nothing on disk to bring it
          back: the operator has to attach the provider again. The only
          shape here that ends in a Keeper losing a provider silently. *)

val expiry_warning : expiry -> string option
(** What to tell the operator about this shape, or [None] when there is
    nothing to say. Phrased for someone reading a page right after a login,
    who has to decide whether they are finished. *)

type finished = {
  keeper : string;
  provider_id : string;
  access_token : string;
  expiry : expiry;
}

val finish :
  ?post:Keeper_oauth_flow.post ->
  pending:Keeper_oauth_pending.t ->
  state:string ->
  code:string ->
  now:float ->
  unit ->
  (finished, finish_error) result
(** Redeem the code the callback carried, at the endpoint the first half was
    built from and naming the redirect URI it sent -- both read from the
    exchange being redeemed, so a callback cannot be finished against a
    different one than it started. *)
