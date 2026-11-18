(* HIGH-RISK-UNREVIEWED: the routes of this module put a person's API key on
   the disk of the server and take it off. Read it against RFC
   a-persons-api-key-is-their-own-provider-account 3.3 and 3.6. *)

(** The routes of a person's key accounts (RFC
    a-persons-api-key-is-their-own-provider-account). The caller passed
    [Manage_own_provider] ({!Auth_preview.person}) before any of these reads
    anything. An answer names no path of the server and nothing of a key. *)

(** [/api/v1/setup/accounts/key]. *)
val path : string

(** [/api/v1/setup/accounts/key/]: the key account of the id that follows. *)
val entry_prefix : string

(** [DELETE /api/v1/setup/accounts/key/<provider_account_id>]: removes the
    key account of the person from this server
    ({!Server_key_account_purge.remove}).

    - 200 [{"provider_account_id":...,"removed":true}]: the folder of its
      keys and its home are gone. The key stays valid at the vendor.
    - 404: no account of the person has this id, or its removal went
      through. An account of another person answers the same.
    - 400 [not_a_key_account]: the account holds a login.
    - 409 [account_call_running]: a call of the account runs.
    - 403 [removal_refused]: the person is not active.
    - 503 [removal_not_recorded]: the start or the end was not recorded. The
      person asks again.
    - 503 [key_not_removed] or [home_not_removed]: the files were not all
      removed, and the log says which stayed. Nothing spends the account.
      The person asks again. *)
val remove
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> provider_account_id:string
  -> Login_routes.answer

(** [POST /api/v1/setup/accounts/key] with [{"integration_id":...,"key":...}]:
    registers the key as a new key account of the person
    ({!Server_key_account_registration.register}, RFC
    a-persons-api-key-is-their-own-provider-account 3.3). No client is
    called, so the answer does not say whether the vendor takes the key: a
    verification of the account does. The request carries no idempotency
    key, and a second request makes a second account.

    [body] holds the key. Nothing of it is in an answer or in the log.

    - 200 [{"provider_account_id":...,"kind":"key"}]: the record, the home
      and the key file of the account are there.
    - 400 [invalid_request]: the body is not the two members, each a string,
      with an id as [integration_id].
    - 400 [not_a_key]: the key is empty, holds a control character, or is a
      JSON document.
    - 400 [unknown_integration]: runtime.toml declares no provider of the
      id.
    - 400 [integration_takes_no_key]: the provider is not one whose key this
      stage takes.
    - 403 [registration_refused]: the person is not active.
    - 503 [configuration_unavailable]: runtime.toml was not read.
    - 503 [registration_not_recorded]: the record was not written, and
      nothing of the key was stored.
    - 503 [key_not_stored]: the files were not made, and the account was
      removed in the same request. Nothing of the key stays.
    - 503 [account_not_removed] with [provider_account_id]: the files were
      not made, and the removal of the account did not go through. The
      person removes the account ({!remove}). *)
val register
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> body:string
  -> Login_routes.answer

(** Whether {!register} takes a key for a provider of this client: in this
    stage, the keys of Claude Code (RFC
    a-persons-api-key-is-their-own-provider-account 3.8). The list of what a
    person connects reads it ({!Server_person_integrations}). *)
val takes_key : Runtime_setup_login_client.client -> bool
