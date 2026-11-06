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
  | Claims_not_base64url  (** the middle segment does not decode as base64url *)
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
          wrote. It is refused even when both name one email, and when one
          of them is an empty string. *)
  | Invalid_id_token of id_token_rejection
  | Unreadable_email of email_key
      (** [id_token_email] is not a string, or the [email] claim repeats or
          is not a string. A repeated [id_token_email] is
          [Repeated_account_key]. *)
  | Not_email_text of email_key
      (** a string {!Runtime_account_email_text.of_string} refuses *)
(** An absent key and a [null] value both hold no value. Any other value,
    an empty string included, is a value. *)

val account_email : string -> (Runtime_account_email_text.t, rejection) result
(** The email one login JSON document names. *)

type undecodable =
  | Not_printable
      (** holds a byte outside printable ASCII, so [security -w] hands the
          CLI the bytes as hex text, which is no login *)
  | Not_hex  (** [go-keyring-encoded:] followed by no even count of hex digits *)
  | Not_base64
      (** [go-keyring-base64:] followed by text that is not whole groups of
          standard base64 with at most two [=] at the end *)

type keychain_rejection =
  | Undecodable of undecodable
  | Keychain_login of rejection  (** the decoded login JSON *)

val login_of_keychain_value : string -> (string, undecodable) result
(** The login JSON a keychain value holds, as the CLI's go-keyring [Get]
    reads it. Read at go-keyring tag v0.2.8 and master 85eb737c1258 on
    2026-11-06T12:50Z:
    https://github.com/zalando/go-keyring/blob/85eb737c1258e4849bfba6456dc0c48228ca8242/keyring_darwin.go#L43-L67
    [Get] reads the value through [security find-generic-password -w], which
    prints the stored bytes as they are only when every byte is printable
    ASCII and prints lowercase hex otherwise:
    https://github.com/apple-oss-distributions/Security/blob/ef677c3d667a44e1737c1b0245e9ed04d11c51c1/SecurityTool/macOS/keychain_find.c#L408-L443
    - A value with any other byte is [Not_printable].
    - Spaces around the value are trimmed, as [strings.TrimSpace] does.
    - [go-keyring-encoded:] is followed by an even count of hex digits in
      either case.
    - [go-keyring-base64:] is followed by padded standard base64, [+] and
      [/] included.
    - Any other value is the login itself.

    [Set], which agy writes through, always writes [go-keyring-base64:]; the
    operator's agy 1.5.1 item had that prefix on 2026-11-06. The other two
    are what [Get] still reads. [security] is taken to run in the C locale,
    where [isprint] admits bytes 0x20 to 0x7E. *)

val keychain_account_email :
  string -> (Runtime_account_email_text.t, keychain_rejection) result

val principal_sha256 : Runtime_account_email_text.t -> string
(** Lowercase hex SHA-256 of [["id_token_email", email]]. *)

val rejection_to_string : rejection -> string

val keychain_rejection_to_string : keychain_rejection -> string
