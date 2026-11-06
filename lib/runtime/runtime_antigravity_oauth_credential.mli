(** The Google account a native Antigravity CLI login file names.

    The CLI writes one JSON object: [auth_method], an OAuth [token] envelope,
    and the account in one of two shapes. agy 1.2.x keeps the sign-in OpenID
    [id_token]. agy 1.5.x keeps only that token's [email] claim as
    [id_token_email]; it still reads an older [id_token] but drops it on the
    next write, so a token refresh turns a 1.2.x file into a 1.5.x file.

    The email is therefore the only account name that survives a refresh, and
    it is the principal for both shapes. Google may change or reassign an
    account's address. A changed address selects a new account generation; an
    address reassigned to another account is not detected here.

    This reads a private local file for account continuity only. It is not
    authentication and does not verify the ID token's signature. *)

type field =
  | Auth_method
  | Token
  | Token_access_token
  | Token_token_type
  | Token_refresh_token
  | Token_expiry
  | Id_token  (** absent, or not a JWT whose claims are a JSON object *)
  | Id_token_issuer  (** the JWT's [iss] is not Google's *)
  | Id_token_email_claim  (** the JWT's [email] claim *)
  | Id_token_email  (** the top-level [id_token_email] *)
(** A field is unreadable when it is absent, empty, repeated in one object, or
    of another type, unless its own line says more. *)

type rejection =
  | Not_json_object
  | No_known_shape of
      { openid_id_token : field  (** the first field the agy 1.2.x shape could not read *)
      ; id_token_email : field  (** the first field the agy 1.5.x shape could not read *)
      }
  | Both_shapes
      (** Both shapes read the file. The CLI writes one of them. *)

type principal

val parse : string -> (principal, rejection) result

val principal_sha256 : principal -> string
(** Lowercase hex SHA-256 of the principal's canonical JSON. Both shapes give
    the same digest for the same email. *)

val rejection_to_string : rejection -> string
