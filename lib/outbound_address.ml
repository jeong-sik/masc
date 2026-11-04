type refusal =
  | Loopback
  | Unspecified
  | Private_network
  | Shared_address_space
  | Link_local
  | Multicast
  | Reserved

let refusal_to_string = function
  | Loopback -> "loopback address"
  | Unspecified -> "unspecified address"
  | Private_network -> "private-network address"
  | Shared_address_space -> "shared address space"
  | Link_local -> "link-local address"
  | Multicast -> "multicast address"
  | Reserved -> "reserved address"

(* IANA IPv4 Special-Purpose Address Registry entries that are not covered by
   the [Ipaddr.V4.Prefix] constants used below. *)
let v4_shared_address_space = Ipaddr.V4.Prefix.of_string_exn "100.64.0.0/10"

let v4_reserved =
  List.map Ipaddr.V4.Prefix.of_string_exn
    [ "192.0.0.0/24" (* IETF protocol assignments, RFC 6890 *)
    ; "192.0.2.0/24" (* TEST-NET-1, RFC 5737 *)
    ; "198.18.0.0/15" (* benchmarking, RFC 2544 *)
    ; "198.51.100.0/24" (* TEST-NET-2, RFC 5737 *)
    ; "203.0.113.0/24" (* TEST-NET-3, RFC 5737 *)
    ; "240.0.0.0/4" (* reserved, RFC 1112; holds 255.255.255.255 *)
    ]

let v6_nat64_well_known = Ipaddr.V6.Prefix.of_string_exn "64:ff9b::/96"
let v6_link_local = Ipaddr.V6.Prefix.of_string_exn "fe80::/10"
let v6_site_local = Ipaddr.V6.Prefix.of_string_exn "fec0::/10"

(* IPv6 is admitted only from the global unicast block. Everything outside it
   that is not judged above (the IPv4-compatible ::/96 block, the local-use
   NAT64 64:ff9b:1::/48, the discard-only 100::/64, unassigned space) is
   reserved. *)
let v6_global_unicast = Ipaddr.V6.Prefix.of_string_exn "2000::/3"

let v6_reserved_global_unicast =
  List.map Ipaddr.V6.Prefix.of_string_exn
    [ "2001::/23" (* IETF protocol assignments, RFC 2928: Teredo, ORCHID *)
    ; "2001:db8::/32" (* documentation, RFC 3849 *)
    ; "2002::/16" (* 6to4, RFC 3056: the relay connects to the IPv4 inside *)
    ; "3fff::/20" (* documentation, RFC 9637 *)
    ]

let v4_refusal v4 =
  if Ipaddr.V4.Prefix.(mem v4 relative) then Some Unspecified
  else if Ipaddr.V4.Prefix.(mem v4 loopback) then Some Loopback
  else if Ipaddr.V4.Prefix.(mem v4 link) then Some Link_local
  else if List.exists (Ipaddr.V4.Prefix.mem v4) Ipaddr.V4.Prefix.private_blocks
  then Some Private_network
  else if Ipaddr.V4.Prefix.mem v4 v4_shared_address_space
  then Some Shared_address_space
  else if Ipaddr.V4.Prefix.(mem v4 multicast) then Some Multicast
  else if List.exists (Ipaddr.V4.Prefix.mem v4) v4_reserved then Some Reserved
  else None

(* The low 32 bits of a well-known-prefix NAT64 address are the IPv4
   destination the translator connects to. *)
let nat64_embedded_v4 v6 =
  Ipaddr.V4.of_octets_exn ~off:12 (Ipaddr.V6.to_octets v6)

let ip_refusal = function
  | Ipaddr.V4 v4 -> v4_refusal v4
  | Ipaddr.V6 v6 -> (
      match Ipaddr.v4_of_v6 v6 with
      | Some mapped -> v4_refusal mapped
      | None ->
          if Ipaddr.V6.compare v6 Ipaddr.V6.localhost = 0 then Some Loopback
          else if Ipaddr.V6.compare v6 Ipaddr.V6.unspecified = 0 then
            Some Unspecified
          else if Ipaddr.V6.Prefix.mem v6 v6_nat64_well_known then
            v4_refusal (nat64_embedded_v4 v6)
          else if Ipaddr.V6.Prefix.mem v6 v6_link_local then Some Link_local
          else if
            Ipaddr.V6.Prefix.(mem v6 unique_local)
            || Ipaddr.V6.Prefix.mem v6 v6_site_local
          then Some Private_network
          else if Ipaddr.V6.Prefix.(mem v6 multicast) then Some Multicast
          else if not (Ipaddr.V6.Prefix.mem v6 v6_global_unicast) then
            Some Reserved
          else if
            List.exists (Ipaddr.V6.Prefix.mem v6) v6_reserved_global_unicast
          then Some Reserved
          else None)

let ipaddr_of_eio ip =
  Eio.Net.Ipaddr.fold
    ~v4:(fun v4 ->
      Ipaddr.V4 (Ipaddr.V4.of_octets_exn (v4 : [ `V4 ] Eio.Net.Ipaddr.t :> string)))
    ~v6:(fun v6 ->
      Ipaddr.V6 (Ipaddr.V6.of_octets_exn (v6 : [ `V6 ] Eio.Net.Ipaddr.t :> string)))
    ip

let is_loopback_or_unspecified_host host =
  Masc_network_defaults.is_loopback_host host
  || Masc_network_defaults.is_unspecified_host host

let port_of_uri uri =
  match Uri.port uri with
  | Some port -> port
  | None -> (
      match Option.map String.lowercase_ascii (Uri.scheme uri) with
      | Some "https" -> 443
      | Some _ | None -> 80)

type host_refusal =
  | Missing_host
  | Local_host_name
  | No_address
  | Resolver_failed of string
  | Refused_address of refusal
  | Non_ip_address

let host_refusal_to_string = function
  | Missing_host -> "missing host"
  | Local_host_name -> "host is not allowed"
  | No_address -> "dns resolution returned no addresses"
  | Resolver_failed detail -> "dns failure: " ^ detail
  | Refused_address refusal ->
      "resolved address is not allowed: " ^ refusal_to_string refusal
  | Non_ip_address -> "resolved address is not an IP address"

(* HIGH-RISK-UNREVIEWED: admission of outbound destinations named by web
   content, a request or a model. *)
let resolve_allowed_host ~net (uri : Uri.t) =
  try
    match Uri.host uri with
    | None -> Error Missing_host
    | Some host when is_loopback_or_unspecified_host host ->
        Error Local_host_name
    | Some host -> (
        let service = Int.to_string (port_of_uri uri) in
        match Eio.Net.getaddrinfo_stream ~service net host with
        | [] -> Error No_address
        | items ->
            let rec admit accumulated = function
              | [] -> Ok (List.rev accumulated)
              | `Unix _ :: _ -> Error Non_ip_address
              | `Tcp (ip, _) :: rest -> (
                  match ip_refusal (ipaddr_of_eio ip) with
                  | Some refusal -> Error (Refused_address refusal)
                  | None -> admit (ip :: accumulated) rest)
            in
            admit [] items)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Resolver_failed (Printexc.to_string exn))
