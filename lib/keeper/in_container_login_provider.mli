(** In-container login provider — Option B credential lifecycle.

    @see {!In_container_login_provider} for full documentation.
    @since 2.90.0 *)

include Credential_provider.S

(** {1 F-1 Security Gate} *)

(** Reject when the keeper's token matches the operator's ambient token.

    Both inputs are SHA-256-hashed and compared as fixed-length hex
    strings.  Matching tokens indicate a confused-deputy scenario where
    the keeper would act as the operator — the gate prevents this by
    returning [Error Invalid_token].

    Callers should read the keeper token from the credential bundle
    and the operator token from the process environment ([GH_TOKEN],
    [GITHUB_TOKEN]) before passing them here. *)
val provider_gate :
  keeper_token:string ->
  operator_token:string ->
  identity:string ->
  (unit, Credential_provider.error) result

(**/**)

(** White-box test helpers.  Not part of the stable API. *)
module For_testing : sig
  val provider_gate :
    keeper_token:string ->
    operator_token:string ->
    identity:string ->
    (unit, Credential_provider.error) result

  val ct_hex_equal : string -> string -> bool
end
