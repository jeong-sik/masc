(* HIGH-RISK-UNREVIEWED: holds the client secret that a login provider gave
   this installation. *)

(** The client that this installation registered at a login provider, Google
    or GitHub (plans C2a-5 and C2b-2b).

    The secret is in no function out of it but {!token_request_fields}, which
    a token request sends. *)
type t

type error =
  | Client_id_empty
  | Client_secret_empty
  | Redirect_uri_not_https
      (** Not an [https] URL with a host and no query or fragment
          ({!Login_transport.is_https_url}). A multi-account login runs on
          [https] only: its cookies are [__Host-], which needs [Secure]. *)

val make
  :  client_id:string
  -> client_secret:string
  -> redirect_uri:string
  -> (t, error) result

type loopback_error =
  | Loopback_client_id_empty
  | Loopback_client_secret_empty
  | Port_out_of_range  (** Not in 1 to 65535. *)
  | Path_not_plain  (** Not [/] and then letters, digits, [-], [.], [_], [~] and [/]. *)

(** A client whose redirect is [http://127.0.0.1:<port><path>], for the
    localhost preview of the plan (its preview scope) and nothing else. The
    host is not an argument, so the provider can only send the browser back
    to this computer. GitHub takes such a loopback redirect on any port
    (its documentation, "Loopback redirect urls"). Chromium keeps a
    [__Host-] cookie on [http://127.0.0.1] (measured 2026-11-08, Chromium
    148); other browsers were not checked. The server builds its clients
    with {!of_environment}, which keeps the [https] rule. *)
val loopback
  :  client_id:string
  -> client_secret:string
  -> port:int
  -> path:string
  -> (t, loopback_error) result

val error_to_string : error -> string
val loopback_error_to_string : loopback_error -> string

type environment_error =
  | Secret_variable_unset of string
      (** The environment variable named by the configuration is not set. *)
  | Client_refused of error

val environment_error_to_string : environment_error -> string

(** The client of an [auth_config] login client ([google] or [github]). The
    secret is read through [getenv] from the variable [client_secret_env] at
    this call, and is held only by the client. *)
val of_environment
  :  getenv:(string -> string option)
  -> client_id:string
  -> redirect_uri:string
  -> client_secret_env:string
  -> (t, environment_error) result
val client_id : t -> string
val redirect_uri : t -> string

(** [client_id], [client_secret] and [redirect_uri], in this order: what a
    token request sends to name its client (RFC 6749 sections 2.3.1 and
    4.1.3). *)
val token_request_fields : t -> (string * string) list
