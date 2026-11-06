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

val error_to_string : error -> string
val client_id : t -> string
val redirect_uri : t -> string

(** [client_id], [client_secret] and [redirect_uri], in this order: what a
    token request sends to name its client (RFC 6749 sections 2.3.1 and
    4.1.3). *)
val token_request_fields : t -> (string * string) list
