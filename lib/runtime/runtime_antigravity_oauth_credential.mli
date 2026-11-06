(** The Google account a native Antigravity CLI login names.

    The CLI keeps one JSON login in its fallback file
    [.gemini/antigravity-cli/antigravity-oauth-token] and, through go-keyring,
    in the keychain item service [gemini], account [antigravity]. agy 1.2.x
    keeps the sign-in OpenID [id_token]. agy 1.5.x keeps only that token's
    [email] claim as [id_token_email]; it still reads an older [id_token] but
    drops it on the next write, so a token refresh turns a 1.2.x login into a
    1.5.x login. Key names and value types read on 2026-11-06, values not
    read:
    - agy 1.5.1 operator file and keychain item: [auth_method], [token]
      ([access_token], [token_type], [refresh_token], [expiry], [expires_in])
      and [id_token_email]. No [id_token].
    - 20 managed copies seeded before agy 1.5: [auth_method], [token]
      ([access_token], [token_type], [refresh_token], [expiry]) and
      [id_token], a three-segment JWT. No [id_token_email].

    The email is the only account name that survives a refresh, so it names
    the account in both shapes. Only the account keys are read: [auth_method]
    and [token] belong to the CLI, and no masc code reads them.

    Google may change an account's address or give it to another account. A
    changed address selects a new account generation. An address given to
    another account selects the previous holder's generation, and that
    generation's managed credential, signed in as the previous holder, stays
    in use.

    This is account continuity for a private local file, not authentication.
    The ID token's signature is not verified. *)

type email_key =
  | Id_token_email  (** the agy 1.5 top-level [id_token_email] *)
  | Id_token_email_claim  (** the agy 1.2 [id_token]'s [email] claim *)

type id_token_rejection =
  | Not_a_jwt
      (** not a string of three [.]-separated segments with a non-empty
          header and signature *)
  | Claims_not_base64url  (** the middle segment is not unpadded base64url *)
  | Claims_not_json_object
  | Issuer_not_google
      (** [iss] is not one string equal to an issuer Google documents *)
  | No_email_claim  (** [email] is absent or [null] *)

type rejection =
  | Not_json_object
  | Repeated_account_key  (** [id_token] or [id_token_email] appears twice *)
  | No_account_key  (** neither [id_token] nor [id_token_email] holds a value *)
  | Both_account_keys
      (** No login read on 2026-11-06 held both, and agy 1.5.1 drops
          [id_token] when it writes, so such a login is not one the CLI
          wrote. It is refused even when both name one email. *)
  | Invalid_id_token of id_token_rejection
  | Unreadable_email of email_key  (** the email repeats or is not a string *)
  | Not_email_text of email_key
      (** a string {!Runtime_account_email_text.of_string} refuses *)
(** An absent key and a [null] value both hold no value. *)

val account_email : string -> (Runtime_account_email_text.t, rejection) result
(** The email one login JSON document names. *)

type keychain_rejection =
  | Not_go_keyring_base64
      (** not [go-keyring-base64:] followed by padded standard base64 *)
  | Keychain_login of rejection  (** the decoded login JSON *)

val login_of_keychain_value : string -> string option
(** The login JSON inside a keychain value. go-keyring's macOS [Set] stores
    [go-keyring-base64:] and the padded standard base64 of the given text;
    the operator's agy 1.5.1 item had that prefix on 2026-11-06. [None] for
    any other value. *)

val keychain_account_email :
  string -> (Runtime_account_email_text.t, keychain_rejection) result

val principal_sha256 : Runtime_account_email_text.t -> string
(** Lowercase hex SHA-256 of [["id_token_email", email]]. *)

val rejection_to_string : rejection -> string

val keychain_rejection_to_string : keychain_rejection -> string
