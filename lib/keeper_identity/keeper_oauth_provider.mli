(** An OAuth provider a Keeper can hold an identity with, as declared in
    [config/identity/<id>.toml].

    Everything the flow needs is in the declaration. Adding a provider is a
    file; there is no place in this module for a per-provider branch, and if
    one appears the declaration was missing something instead.

    This does not cover every way a Keeper reaches a service. A long-lived
    token needs no flow at all -- it goes straight into the Keeper's secret
    projection -- and GitHub's CLI keeps its own account store under
    [keepers/<keeper>/github-cli/]. This is only for the services that issue
    a short-lived token and expect an authorization exchange for it. *)

type error =
  | Missing_field of string
  | Empty_field of string
  | Wrong_type of { field : string; expected : string }
  | Name_mismatch of { declared : string; file : string }
  | Malformed_toml of string
      (** Why one declaration could not be read. Each says which field and
          what was wrong with it, because the operator who has to fix it is
          looking at a file, not a stack trace. *)

val error_to_string : error -> string

type t = private {
  id : string;
  label : string;  (** what a screen calls this provider *)
  mcp_url : string;
      (** The only endpoint declared. Everything else about the exchange --
          where to authorize, where to redeem, what scopes exist, whether a
          client has to be registered by hand -- is what this server's
          well-known documents answer, and asking beats shipping a copy that
          can go stale. *)
  access_token_env : string;
      (** Env entry in [secrets/<keeper>/env/] the access token is written
          to. A tool call reads it from there. *)
  refresh_token_file : string;
      (** File entry in [secrets/<keeper>/files/] the refresh token is
          written to. Not an env entry: a refresh token outlives the access
          tokens it mints, and an environment is read by everything a Keeper
          runs. *)
  renew_before_sec : int;
      (** How long before the stated expiry to exchange again. A turn that
          starts inside this window gets a fresh token rather than one that
          expires mid-call. *)
  authorize_params : (string * string) list;
      (** Parameters this server wants on the authorize call beyond what the
          specs define, in declaration order.

          Atlassian wants [audience]. Rather than a branch that knows that,
          the declaration says it -- so the next server that wants something
          of its own is a line in a file. [resource] is not one of these: it
          is RFC 8707 and comes from discovery, so every provider gets it
          without asking. *)
}

val load : file_name:string -> contents:string -> (t, error) result
(** [load ~file_name ~contents] reads one declaration.

    [file_name] is the basename minus [.toml]; the file's own [id] must equal
    it, so a renamed file cannot quietly become a different provider. *)
