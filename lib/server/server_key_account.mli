(* HIGH-RISK-UNREVIEWED: the routes of this module put a person's API key on
   the disk of the server, put another in its place and take it off. Read it
   against RFC a-persons-api-key-is-their-own-provider-account 3.3, 3.6 and
   3.7. *)

(** The routes of a person's key accounts (RFC
    a-persons-api-key-is-their-own-provider-account). The caller passed
    [Manage_own_provider] ({!Auth_preview.person}) before any of these reads
    anything. An answer names no path of the server and nothing of a key.

    {b A record the zone did not take.} The three routes answer it by what
    the zone says once it failed ({!Authz_zone.read}). A zone that can be
    trusted has not stopped: the answer is the 503 with [..._not_recorded]
    below, and a request asked again is read and its record is tried. It
    goes in after a moment in which another process held a file and wrote
    nothing. A zone that cannot be trusted takes
    no record until the server starts again, and every request of a person
    from then on gets the 503 of {!Login_routes.zone_uncertain}, which has
    no [code]. The request that found the zone so gets that answer too, in
    place of the [..._not_recorded] one. What it left is in the list of the
    accounts once the server started again. *)

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
    - 503 [removal_not_recorded]: the start or the end was not recorded,
      and the zone did not stop. The person asks again.
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
    - 403 [registration_refused]: the person is not active, or a reduction
      of theirs that was started is not ended.
    - 500 [internal_error]: the log refused the record for a reason no
      request of a person leads to.
    - 503 [configuration_unavailable]: runtime.toml was not read.
    - 503 [registration_not_recorded]: the record was not written, nothing
      of the key was stored, and the zone did not stop. The person sends
      the key again.
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

(** [PUT /api/v1/setup/accounts/key/<provider_account_id>] with
    [{"key":...}]: puts the key in place of the one the key account of the
    person holds ({!Server_key_account_replacement.replace}, RFC
    a-persons-api-key-is-their-own-provider-account 3.7). The account, its
    Runtimes and the Keepers assigned to them stay. No client is called, so
    the answer does not say whether the vendor takes the key: a verification
    of the account does. The request carries no idempotency key: a second
    request with the same key writes a second record, and the key in place
    is the same.

    [body] holds the key. Nothing of it is in an answer or in the log.

    - 200 [{"provider_account_id":...,"old_keys_removed":...}]: the new key
      is in place and is the one read. [old_keys_removed] is [false] when a
      file of the folder of the keys stayed, a key of a generation before
      among them: nothing reads it, and the start of the server, the next
      replacement and a removal of the account take it away.
    - 404 [unknown_account]: no account of the person has this id, or its
      removal began or went through. An account of another person answers
      the same.
    - 400 [not_a_key_account]: the account holds a login.
    - 400 [invalid_request]: the body is not the one member [key], a string.
    - 400 [not_a_key]: the key is empty, holds a control character, or is a
      JSON document.
    - 409 [account_call_running]: a call of the account runs.
    - 409 [removal_left]: a removal of the account did not go through. Its
      key is not replaced; the person removes the account ({!remove}).
    - 403 [replacement_refused]: the person is not active, or a reduction of
      theirs that was started is not ended.
    - 500 [internal_error]: the log refused the record for a reason no
      request of a person leads to.
    - 503 [files_not_reached]: the runtime root of the person or the home
      of the account was not reached, or a folder on the way is no folder
      this server takes. No record was tried, the zone was not asked, and
      the key of the account was not changed. While the folder stays as it
      is, the same request gets the same answer.
    - 503 [replacement_not_recorded]: the record was not written, the key
      of the account was not changed, and the zone did not stop. The person
      sends the key again. A commit that wrote its intent and not its
      record blocks the account until then (the same RFC, 3.7).
    - 503 [key_not_stored]: the record was written and the new key was not
      put in place. The key before is not read, and the server removes the
      folder of the keys of the account, so the account has no key until
      the person sends one again. The answer does not say whether the
      folder went: the log of the server does, and a list of the accounts
      says what the account reads.

    The id is read first, then the body, then the records of the account.
    A path that is no id answers 404 with the body not read. For an id that
    is one, a body that is refused answers 400 whatever account it names. *)
val replace
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> provider_account_id:string
  -> body:string
  -> Login_routes.answer

(** Whether {!register} takes a key for a provider of this client: in this
    stage, the keys of Claude Code (RFC
    a-persons-api-key-is-their-own-provider-account 3.8). The list of what a
    person connects reads it ({!Server_person_integrations}). *)
val takes_key : Runtime_setup_login_client.client -> bool
