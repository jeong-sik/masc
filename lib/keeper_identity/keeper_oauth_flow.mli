(** The authorization-code exchange, for one Keeper and one declared
    provider.

    This module knows the shape of the exchange, not the provider: every URL,
    scope and field name it uses comes from
    {!Keeper_oauth_provider.t}. There is no branch here that names a service,
    and adding one would mean the declaration was missing something.

    What it does not do: decide where tokens are stored, open a browser, or
    hold state between the two halves of the exchange. Those belong to the
    caller, which is the part that knows about Keepers. *)

type tokens = {
  access_token : string;
  refresh_token : string option;
      (** Absent when the provider issued none. A provider whose declaration
          asks for [offline_access] and returns nothing here has answered
          differently than its declaration said, which is
          {!No_refresh_token}, not an absent field. *)
  expires_at : float;  (** unix seconds, computed from the response's [expires_in] *)
}

type pending = private {
  provider_id : string;
  keeper : string;
  verifier : string;
      (** The PKCE verifier. Held only until the code comes back; it is what
          proves the code is being redeemed by whoever asked for it. *)
  state : string;
      (** Echoed by the provider on the callback. A callback carrying any
          other value is not the one this pending exchange asked for. *)
  authorize_url : string;  (** where the operator has to go *)
}

val begin_authorization :
  provider:Keeper_oauth_provider.t ->
  client_id:string ->
  redirect_uri:string ->
  keeper:string ->
  pending
(** Start an exchange. Generates a PKCE verifier and a state value from the
    process crypto source and builds the URL the operator opens.

    Nothing is stored: the caller holds the returned [pending] until the
    callback arrives, and a caller that loses it has to start again -- which
    is the correct outcome, because a code that arrives with no verifier to
    match it cannot be proven to belong to this request. *)

type exchange_error =
  | Transport of string  (** the request did not complete *)
  | Provider_rejected of { status : int; body : string }
      (** the provider answered, and said no. The body is kept because
          providers put the reason there and an operator needs to read it. *)
  | Malformed_response of string
      (** the provider answered with something this cannot read *)
  | State_mismatch
      (** the callback echoed a state that is not this exchange's *)
  | No_refresh_token
      (** the declaration asked for [offline_access] and the provider
          returned no refresh token. Storing only the access token would
          leave the Keeper working for one hour and then stopping with no
          record of why. *)

val exchange_error_to_string : exchange_error -> string

(** How the exchange reaches the provider. Injected so the token-endpoint
    contract can be exercised against recorded answers rather than a live
    provider: a test that needs network is a test that does not run. *)
type post =
  url:string -> headers:(string * string) list -> body:string ->
  (int * string, string) result

val complete :
  ?post:post ->
  provider:Keeper_oauth_provider.t ->
  client_id:string ->
  client_secret:string ->
  redirect_uri:string ->
  pending:pending ->
  code:string ->
  state:string ->
  now:float ->
  unit ->
  (tokens, exchange_error) result
(** Redeem the code the callback carried. [state] is what the callback
    echoed, checked against the pending exchange's own before anything is
    sent. *)

val refresh :
  ?post:post ->
  provider:Keeper_oauth_provider.t ->
  client_id:string ->
  client_secret:string ->
  refresh_token:string ->
  now:float ->
  unit ->
  (tokens, exchange_error) result
(** Exchange a refresh token for a new access token.

    A provider that rotates refresh tokens returns a new one, and the caller
    has to store it: the one just used may already be spent. *)

val needs_renewal : provider:Keeper_oauth_provider.t -> expires_at:float -> now:float -> bool
(** Whether an access token is inside its declared renewal window. A turn
    that starts here should exchange first rather than begin a call that
    expires partway. *)
