(** See [server_tls_material.mli]. *)

type source = Https_listener_metrics.certificate_source =
  | Configured
  | Self_signed

let source_to_string = Https_listener_metrics.certificate_source_to_string

type error =
  | Only_cert_configured of string
  | Only_key_configured of string
  | Unreadable of { path : string; reason : string }
  | Invalid_pem of { path : string; reason : string }
  | Not_writable of { path : string; reason : string }
  | Signing_failed of string

let error_to_string = function
  | Only_cert_configured path ->
    Printf.sprintf
      "MASC_TLS_CERT_FILE=%s is set but MASC_TLS_KEY_FILE is not; set both or neither"
      path
  | Only_key_configured path ->
    Printf.sprintf
      "MASC_TLS_KEY_FILE=%s is set but MASC_TLS_CERT_FILE is not; set both or neither"
      path
  | Unreadable { path; reason } -> Printf.sprintf "cannot read %s: %s" path reason
  | Invalid_pem { path; reason } ->
    Printf.sprintf "%s is not PEM the HTTPS listener can use: %s" path reason
  | Not_writable { path; reason } -> Printf.sprintf "cannot write %s: %s" path reason
  | Signing_failed reason ->
    Printf.sprintf "the self-signed certificate could not be made: %s" reason
;;

type t =
  { chain : X509.Certificate.t list
  ; key : X509.Private_key.t
  ; source : source
  ; not_after : Ptime.t
  }

let seconds_per_day = 24 * 3600
let validity = Ptime.Span.of_int_s (365 * seconds_per_day)
let renew_before = Ptime.Span.of_int_s (30 * seconds_per_day)
let tls_dirname = "tls"
let alpn_h2 = "h2"
let alpn_http1 = "http/1.1"

let self_signed_paths ~base_path =
  let dir = Filename.concat (Filename.concat base_path Common.masc_dirname) tls_dirname in
  Filename.concat dir "server.crt", Filename.concat dir "server.key"
;;

(* {1 Reading a configured or previously generated pair} *)

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error reason -> Error (Unreadable { path; reason })
;;

let decode_chain ~path pem =
  match X509.Certificate.decode_pem_multiple pem with
  | Ok (_ :: _ as chain) -> Ok chain
  | Ok [] -> Error (Invalid_pem { path; reason = "no certificate in the file" })
  | Error (`Msg reason) -> Error (Invalid_pem { path; reason })
;;

let decode_key ~path pem =
  match X509.Private_key.decode_pem pem with
  | Ok key -> Ok key
  | Error (`Msg reason) -> Error (Invalid_pem { path; reason })
;;

let load_pair ~source ~cert_file ~key_file =
  let ( let* ) = Result.bind in
  let* cert_pem = read_file cert_file in
  let* chain = decode_chain ~path:cert_file cert_pem in
  let* key_pem = read_file key_file in
  let* key = decode_key ~path:key_file key_pem in
  let leaf = List.hd chain in
  let _not_before, not_after = X509.Certificate.validity leaf in
  Ok { chain; key; source; not_after }
;;

(* {1 Making a self-signed pair} *)

let subject =
  X509.Distinguished_name.
    [ Relative_distinguished_name.singleton (CN (Common_name.v "masc")) ]
;;

(* The bind host as subject alternative name octets, unless it is the
   unspecified address, which no client connects to. *)
let bind_host_octets host =
  match Ipaddr.of_string host with
  | Ok (Ipaddr.V4 v4) when Ipaddr.V4.compare v4 Ipaddr.V4.any <> 0 ->
    Some (Ipaddr.V4.to_octets v4)
  | Ok (Ipaddr.V6 v6) when Ipaddr.V6.compare v6 Ipaddr.V6.unspecified <> 0 ->
    Some (Ipaddr.V6.to_octets v6)
  | Ok (Ipaddr.V4 _ | Ipaddr.V6 _) | Error (`Msg _) -> None
;;

let subject_alt_names ~bind_host =
  let loopbacks =
    [ Ipaddr.V4.to_octets Ipaddr.V4.localhost; Ipaddr.V6.to_octets Ipaddr.V6.localhost ]
  in
  let ips =
    match bind_host_octets bind_host with
    | Some octets when not (List.mem octets loopbacks) -> loopbacks @ [ octets ]
    | Some _ | None -> loopbacks
  in
  X509.General_name.(singleton DNS [ "localhost" ] |> add IP ips)
;;

let extensions ~bind_host =
  X509.Extension.(
    empty
    |> add Subject_alt_name (false, subject_alt_names ~bind_host)
    |> add Key_usage (true, [ `Digital_signature; `Key_encipherment ])
    |> add Ext_key_usage (false, [ `Server_auth ])
    |> add Basic_constraints (true, (false, None)))
;;

let generate ~now ~bind_host =
  Crypto_rng.ensure_default ();
  match Ptime.add_span now validity with
  | None -> Error (Signing_failed "the validity end is not a representable time")
  | Some valid_until ->
    let key = X509.Private_key.generate `P256 in
    (match X509.Signing_request.create subject key with
     | Error (`Msg reason) -> Error (Signing_failed reason)
     | Ok request ->
       (match
          X509.Signing_request.sign
            request
            ~valid_from:now
            ~valid_until
            ~extensions:(extensions ~bind_host)
            key
            subject
        with
        | Error signature_error ->
          Error
            (Signing_failed
               (Format.asprintf "%a" X509.Validation.pp_signature_error signature_error))
        | Ok certificate ->
          Ok { chain = [ certificate ]; key; source = Self_signed; not_after = valid_until }))
;;

(* {1 Writing the generated pair} *)

(* mkdir -p with one mode for every directory it creates: the chain lives
   under the private [.masc] directory. *)
let rec ensure_dir ~mode dir =
  if Sys.file_exists dir
  then Ok ()
  else (
    match ensure_dir ~mode (Filename.dirname dir) with
    | Error _ as error -> error
    | Ok () ->
      (match Sys.mkdir dir mode with
       | () -> Ok ()
       | exception Sys_error reason -> Error (Not_writable { path = dir; reason })))
;;

let write_file ~mode path contents =
  let tmp = path ^ ".tmp" in
  match
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
      mode
      tmp
      (fun oc -> Out_channel.output_string oc contents);
    Sys.rename tmp path
  with
  | () -> Ok ()
  | exception Sys_error reason -> Error (Not_writable { path; reason })
;;

type decision =
  | Reuse of t
  | Renew of string

let decide_self_signed ~now ~cert_path ~key_path =
  match load_pair ~source:Self_signed ~cert_file:cert_path ~key_file:key_path with
  | Error error -> Renew (error_to_string error)
  | Ok material ->
    (match Ptime.add_span now renew_before with
     | None -> Renew "the renewal time is not a representable time"
     | Some renew_at ->
       if Ptime.is_later material.not_after ~than:renew_at
       then Reuse material
       else Renew "the certificate expires within 30 days")
;;

let load_or_generate ~now ~base_path ~bind_host ~cert_file ~key_file =
  match cert_file, key_file with
  | Some cert_file, Some key_file -> load_pair ~source:Configured ~cert_file ~key_file
  | Some cert_file, None -> Error (Only_cert_configured cert_file)
  | None, Some key_file -> Error (Only_key_configured key_file)
  | None, None ->
    let cert_path, key_path = self_signed_paths ~base_path in
    (match decide_self_signed ~now ~cert_path ~key_path with
     | Reuse material -> Ok material
     | Renew reason ->
       Log.Server.info "HTTPS: making a self-signed certificate at %s (%s)" cert_path reason;
       let ( let* ) = Result.bind in
       let* material = generate ~now ~bind_host in
       let* () = ensure_dir ~mode:0o700 (Filename.dirname cert_path) in
       let* () = write_file ~mode:0o600 key_path (X509.Private_key.encode_pem material.key) in
       let* () =
         write_file
           ~mode:0o644
           cert_path
           (String.concat "" (List.map X509.Certificate.encode_pem material.chain))
       in
       Ok material)
;;

let tls_config t =
  match
    Tls.Config.server
      ~certificates:(`Single (t.chain, t.key))
      ~alpn_protocols:[ alpn_h2; alpn_http1 ]
      ~version:(`TLS_1_3, `TLS_1_3)
      ()
  with
  | Ok config -> Ok config
  | Error (`Msg reason) -> Error reason
;;
