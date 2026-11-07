(** The certificate chain and private key the HTTPS listener serves
    (RFC-0512 D6).

    Both files configured: that pair, as is. Neither configured: a self-signed
    pair under [<base-path>/.masc/tls/], generated when missing, unreadable or
    within {!renew_before} of its expiry. One configured without the other
    refuses the listener, so a half-edited configuration does not fall back to
    a certificate the operator did not intend. *)

(** {!Https_listener_metrics.certificate_source}, so the health JSON names the
    same thing. *)
type source = Https_listener_metrics.certificate_source =
  | Configured  (** both files came from the configuration *)
  | Self_signed  (** the pair under [<base-path>/.masc/tls/] *)

val source_to_string : source -> string
(** ["configured"] or ["self_signed"]. *)

type error =
  | Only_cert_configured of string  (** the certificate path; no key *)
  | Only_key_configured of string  (** the key path; no certificate *)
  | Unreadable of { path : string; reason : string }
  | Invalid_pem of { path : string; reason : string }
  | Not_writable of { path : string; reason : string }
  | Signing_failed of string

val error_to_string : error -> string

type t =
  { chain : X509.Certificate.t list  (** leaf first *)
  ; key : X509.Private_key.t
  ; source : source
  ; not_after : Ptime.t  (** the leaf's expiry *)
  }

val validity : Ptime.Span.t
(** How long a self-signed certificate is valid from generation: 365 days. *)

val renew_before : Ptime.Span.t
(** A self-signed certificate this close to its expiry is generated again at
    boot: 30 days. *)

val self_signed_paths : base_path:string -> string * string
(** [(certificate, key)] under [<base-path>/.masc/tls/]. *)

val load_or_generate
  :  now:Ptime.t
  -> base_path:string
  -> bind_host:string
  -> cert_file:string option
  -> key_file:string option
  -> (t, error) result
(** The material for a boot at [now]. A generated certificate names
    [localhost], [127.0.0.1], [::1] and [bind_host] when that is one address
    (not [0.0.0.0] or [::]) as subject alternative names. The key file is
    written with mode 0600; both files are written whole and renamed into
    place. *)

val alpn_h2 : string
(** ["h2"] *)

val alpn_http1 : string
(** ["http/1.1"] *)

val tls_config : t -> (Tls.Config.server, string) result
(** A TLS 1.3-only server configuration that offers {!alpn_h2} then
    {!alpn_http1}. [Error] names what the TLS library rejected, such as a key
    that does not belong to the certificate. *)
