(* Moved from server_dashboard_http_link_preview.ml so the OAuth client
   metadata fetch asks the same question the link preview does. *)

let is_loopback_or_unspecified_host host =
  Masc_network_defaults.is_loopback_host host
  || Masc_network_defaults.is_unspecified_host host

let rec ipaddr_is_private_or_reserved = function
  | Ipaddr.V4 addr ->
      let octets = Ipaddr.V4.to_octets addr in
      let byte idx = Char.code octets.[idx] in
      let b0 = byte 0 and b1 = byte 1 in
      b0 = 0
      || b0 = 10
      || b0 = 127
      || (b0 = 169 && b1 = 254)
      || (b0 = 172 && b1 >= 16 && b1 <= 31)
      || (b0 = 192 && b1 = 168)
      || (b0 = 100 && b1 >= 64 && b1 <= 127)
      || (b0 = 192 && b1 = 0)
      || (b0 = 198 && (b1 = 18 || b1 = 19))
      || (b0 = 198 && b1 = 51)
      || (b0 = 203 && b1 = 0)
      || b0 >= 224
  | Ipaddr.V6 addr -> (
      (* ::ffff:10.0.0.1 reaches 10.0.0.1 over a dual-stack socket. Its text
         starts with none of the prefixes below, so it used to pass. *)
      match Ipaddr.v4_of_v6 addr with
      | Some mapped -> ipaddr_is_private_or_reserved (Ipaddr.V4 mapped)
      | None ->
          let text = Ipaddr.V6.to_string addr |> String.lowercase_ascii in
          Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0
          || Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0
          || String.starts_with ~prefix:"fc" text
          || String.starts_with ~prefix:"fd" text
          || String.starts_with ~prefix:"fe8" text
          || String.starts_with ~prefix:"fe9" text
          || String.starts_with ~prefix:"fea" text
          || String.starts_with ~prefix:"feb" text
          || String.starts_with ~prefix:"ff" text
          || String.starts_with ~prefix:"2001:db8" text)

let eio_ipaddr_is_private_or_reserved ip =
  let rendered = Fmt.str "%a" Eio.Net.Ipaddr.pp ip in
  match Ipaddr.of_string rendered with
  | Ok parsed -> ipaddr_is_private_or_reserved parsed
  | Error _ -> true

let validate_resolved_host ~net (uri : Uri.t) =
  try
    match Uri.host uri with
    | None -> Error "missing host"
    | Some host when is_loopback_or_unspecified_host host ->
        Error "host is not allowed"
    | Some host ->
        let service =
          match Uri.port uri with
          | Some port -> Int.to_string port
          | None ->
              if Uri.scheme uri = Some "https" then "443" else "80"
        in
        let addrs = Eio.Net.getaddrinfo_stream ~service net host in
        match addrs with
        | [] -> Error "dns resolution returned no addresses"
        | items ->
            let blocked =
              List.exists
                (function
                  | `Tcp (ip, _) -> eio_ipaddr_is_private_or_reserved ip
                  | `Unix _ -> true)
                items
            in
            if blocked then Error "resolved address is not allowed" else Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "dns failure: %s" (Printexc.to_string exn))
