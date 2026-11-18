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
