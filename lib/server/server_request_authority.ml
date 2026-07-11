type scheme =
  | Http
  | Https

type trust_class =
  | Configured_bind
  | Explicit_trusted_host

type host_port =
  { host : string
  ; port : int option
  }

type authority =
  { host : string
  ; port : int option
  ; scheme : scheme
  ; trust_class : trust_class
  }

type request_context = authority

type trusted_identity =
  { authority : host_port
  ; scheme : scheme
  }

type trust_policy =
  { configured_bind : trusted_identity
  ; explicit_trusted_host : trusted_identity option
  }

type trust_policy_error =
  | Malformed_bind_authority
  | Malformed_explicit_base_url

type classification =
  | Missing
  | Single of request_context
  | Multiple
  | Malformed
  | Untrusted

type h2_classification =
  | H2_authority of classification
  | Unsupported_asterisk_form_options

exception Unbound_request_authority

type serialized_origin =
  { authority : host_port
  ; scheme : scheme
  }

let scheme_to_string = function
  | Http -> "http"
  | Https -> "https"
;;

let scheme_of_string raw =
  if not (String.equal raw (String.trim raw))
  then None
  else
    match String.lowercase_ascii raw with
    | "http" -> Some Http
    | "https" -> Some Https
    | _ -> None
;;

let trust_policy_error_to_string = function
  | Malformed_bind_authority -> "configured HTTP bind authority is malformed"
  | Malformed_explicit_base_url ->
    "configured HTTP base URL is not a valid HTTP(S) trusted identity"
;;

let ascii_is_digit c = c >= '0' && c <= '9'

let ascii_is_hex_digit c =
  ascii_is_digit c
  || (c >= 'a' && c <= 'f')
  || (c >= 'A' && c <= 'F')
;;

let reg_name_char_is_allowed c =
  ascii_is_digit c
  || (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || String.contains "-._~!$&'()*+,;=" c
;;

let reg_name_is_valid host =
  let length = String.length host in
  let rec consume index =
    if index = length
    then true
    else if Char.equal host.[index] '%'
    then
      index + 2 < length
      && ascii_is_hex_digit host.[index + 1]
      && ascii_is_hex_digit host.[index + 2]
      && consume (index + 3)
    else reg_name_char_is_allowed host.[index] && consume (index + 1)
  in
  length > 0 && consume 0
;;

let parse_port_suffix suffix =
  if String.equal suffix ""
  then Ok None
  else if not (Char.equal suffix.[0] ':')
  then Error ()
  else
    let raw_port = String.sub suffix 1 (String.length suffix - 1) in
    if String.equal raw_port "" || not (String.for_all ascii_is_digit raw_port)
    then Error ()
    else
      match int_of_string_opt raw_port with
      | Some port when port <= 65_535 -> Ok (Some port)
      | Some _ | None -> Error ()
;;

let canonical_reg_name host =
  match Ipaddr.V4.of_string host with
  | Ok address -> Ipaddr.V4.to_string address
  | Error _ -> String.lowercase_ascii host
;;

let parse raw =
  let value = String.trim raw in
  if String.equal value ""
  then None
  else if Char.equal value.[0] '['
  then
    match String.index_opt value ']' with
    | None | Some 1 -> None
    | Some closing_bracket ->
      let raw_host = String.sub value 1 (closing_bracket - 1) in
      let suffix_start = closing_bracket + 1 in
      let suffix =
        String.sub value suffix_start (String.length value - suffix_start)
      in
      (match Ipaddr.V6.of_string raw_host, parse_port_suffix suffix with
       | Ok address, Ok port ->
         Some { host = Ipaddr.V6.to_string address; port }
       | Error _, _ | _, Error () -> None)
  else
    let colon_count =
      String.fold_left
        (fun count char -> if Char.equal char ':' then count + 1 else count)
        0
        value
    in
    if colon_count > 1
    then None
    else
      let raw_host, suffix =
        match String.index_opt value ':' with
        | None -> value, ""
        | Some separator ->
          ( String.sub value 0 separator
          , String.sub value separator (String.length value - separator) )
      in
      if not (reg_name_is_valid raw_host)
      then None
      else
        match parse_port_suffix suffix with
        | Ok port -> Some { host = canonical_reg_name raw_host; port }
        | Error () -> None
;;

let parse_h2 raw =
  if String.equal raw (String.trim raw) then parse raw else None
;;

let rendered_host host =
  match Ipaddr.V6.of_string host with
  | Ok _ -> "[" ^ host ^ "]"
  | Error _ -> host
;;

let host_port_of_parts ~host ~port =
  let suffix = Option.fold ~none:"" ~some:(Printf.sprintf ":%d") port in
  parse_h2 (rendered_host host ^ suffix)
;;

let default_port_for_scheme = function
  | Http -> Some 80
  | Https -> Some 443
;;

let effective_port_value ~scheme port =
  match port with
  | Some _ as explicit -> explicit
  | None -> default_port_for_scheme scheme
;;

let effective_port ~scheme (authority : authority) =
  effective_port_value ~scheme authority.port
;;

let effective_host_port ~scheme (authority : host_port) =
  effective_port_value ~scheme authority.port
;;

let equivalent_for_scheme ~scheme left right =
  String.equal left.host right.host
  && Option.equal Int.equal
       (effective_port ~scheme left)
       (effective_port ~scheme right)
;;

let host_port_equivalent_for_scheme ~scheme (left : host_port)
    (right : host_port) =
  String.equal left.host right.host
  && Option.equal Int.equal
       (effective_host_port ~scheme left)
       (effective_host_port ~scheme right)
;;

let trusted_host_port_matches ~scheme (trusted : host_port)
    (candidate : host_port) =
  Option.equal Int.equal
    (effective_host_port ~scheme trusted)
    (effective_host_port ~scheme candidate)
  && (String.equal trusted.host candidate.host
      || (Masc_network_defaults.is_loopback_host trusted.host
          && Masc_network_defaults.is_loopback_host candidate.host))
;;

let host_is_unspecified host =
  match Ipaddr.of_string host with
  | Ok (Ipaddr.V4 address) -> Ipaddr.V4.compare address Ipaddr.V4.any = 0
  | Ok (Ipaddr.V6 address) -> Ipaddr.V6.compare address Ipaddr.V6.unspecified = 0
  | Error _ -> false
;;

let configured_bind_matches configured request_authority =
  let same_port =
    Option.equal Int.equal
      (effective_host_port ~scheme:Http configured.authority)
      (effective_host_port ~scheme:Http request_authority)
  in
  not (host_is_unspecified configured.authority.host)
  && same_port
  && (String.equal configured.authority.host request_authority.host
      || (Masc_network_defaults.is_loopback_host configured.authority.host
          && Masc_network_defaults.is_loopback_host request_authority.host))
;;

let explicit_identity_of_base_url raw =
  if not (String.equal raw (String.trim raw))
  then None
  else
    let uri = Uri.of_string raw in
    match
      Option.bind (Uri.scheme uri) scheme_of_string,
      Uri.userinfo uri,
      Uri.host uri,
      Uri.fragment uri,
      Uri.query uri
    with
    | Some scheme, None, Some host, None, [] ->
      Option.map
        (fun authority -> ({ authority; scheme } : trusted_identity))
        (host_port_of_parts ~host ~port:(Uri.port uri))
    | Some _, None, Some _, None, _ :: _
    | Some _, None, Some _, Some _, _
    | Some _, Some _, _, _, _
    | Some _, None, None, _, _
    | None, _, _, _, _ ->
      None
;;

let make_trust_policy ~bind_host ~bind_port ~explicit_base_url =
  match host_port_of_parts ~host:bind_host ~port:(Some bind_port) with
  | None -> Error Malformed_bind_authority
  | Some bind_authority ->
    let configured_bind = { authority = bind_authority; scheme = Http } in
    (match explicit_base_url with
     | None -> Ok { configured_bind; explicit_trusted_host = None }
     | Some raw ->
       (match explicit_identity_of_base_url raw with
        | None -> Error Malformed_explicit_base_url
        | Some explicit_trusted_host ->
          Ok
            { configured_bind
            ; explicit_trusted_host = Some explicit_trusted_host
            }))
;;

let admit_authority ~trust_policy ~wire_scheme parsed =
  let explicit_match () =
    match trust_policy.explicit_trusted_host with
    | Some trusted
      when trusted.scheme = wire_scheme
           && trusted_host_port_matches
                ~scheme:wire_scheme
                trusted.authority
                parsed ->
      Some
        { host = parsed.host
        ; port = parsed.port
        ; scheme = wire_scheme
        ; trust_class = Explicit_trusted_host
        }
    | Some _ | None -> None
  in
  let configured_match () =
    if wire_scheme = Http
       && configured_bind_matches trust_policy.configured_bind parsed
    then
      Some
        { host = parsed.host
        ; port = parsed.port
        ; scheme = Http
        ; trust_class = Configured_bind
        }
    else None
  in
  match wire_scheme with
  | Https -> explicit_match ()
  | Http ->
    (match configured_match () with
     | Some _ as admitted -> admitted
     | None -> explicit_match ())
;;

let admit_http1_authority ~trust_policy parsed =
  match trust_policy.explicit_trusted_host with
  | Some trusted
    when trusted.scheme = Https
         && trusted_host_port_matches
              ~scheme:Https
              trusted.authority
              parsed ->
    Some
      { host = parsed.host
      ; port = parsed.port
      ; scheme = Https
      ; trust_class = Explicit_trusted_host
      }
  | Some _ | None ->
    (match admit_authority ~trust_policy ~wire_scheme:Http parsed with
     | Some _ as admitted -> admitted
     | None ->
       (match trust_policy.explicit_trusted_host with
        | Some trusted
          when trusted_host_port_matches
                 ~scheme:trusted.scheme
                 trusted.authority
                 parsed ->
          Some
            { host = parsed.host
            ; port = parsed.port
            ; scheme = trusted.scheme
            ; trust_class = Explicit_trusted_host
            }
        | Some _ | None -> None))
;;

let classify_http1_request ~trust_policy request =
  match Httpun.Headers.get_multi request.Httpun.Request.headers "host" with
  | [] -> Missing
  | [ raw ] ->
    (match parse raw with
     | None -> Malformed
     | Some parsed ->
       Option.fold
         ~none:Untrusted
         ~some:(fun admitted -> Single admitted)
         (admit_http1_authority ~trust_policy parsed))
  | _ -> Multiple
;;

let classify_h2_request ~trust_policy request =
  let authorities = H2.Headers.get_multi request.H2.Request.headers ":authority" in
  let hosts = H2.Headers.get_multi request.H2.Request.headers "host" in
  match scheme_of_string request.H2.Request.scheme, authorities with
  | None, _ -> H2_authority Malformed
  | Some _, []
    when request.H2.Request.meth = `OPTIONS
         && String.equal request.H2.Request.target "*" ->
    (match hosts with
     | [] -> Unsupported_asterisk_form_options
     | [ raw_host ] ->
       (match parse_h2 raw_host with
        | Some _ -> Unsupported_asterisk_form_options
        | None -> H2_authority Malformed)
     | _ -> H2_authority Malformed)
  | Some _, [] ->
    H2_authority
      (match hosts with
       | [] | [ _ ] -> Missing
       | _ -> Malformed)
  | Some scheme, [ raw_authority ] ->
    let classification =
      match parse_h2 raw_authority with
      | None -> Malformed
      | Some parsed ->
        let host_cross_check =
          match hosts with
          | [] -> true
         | [ raw_host ] ->
           (match parse_h2 raw_host with
            | Some host ->
              host_port_equivalent_for_scheme ~scheme parsed host
            | None -> false)
          | _ -> false
        in
        if not host_cross_check
        then Malformed
        else
          Option.fold
            ~none:Untrusted
            ~some:(fun admitted -> Single admitted)
            (admit_authority ~trust_policy ~wire_scheme:scheme parsed)
    in
    H2_authority classification
  | Some _, _ -> H2_authority Malformed
;;

let host authority = authority.host
let port authority = authority.port
let scheme (authority : authority) = authority.scheme
let trust_class authority = authority.trust_class

let rendered authority =
  match authority.port with
  | None -> rendered_host authority.host
  | Some port -> Printf.sprintf "%s:%d" (rendered_host authority.host) port
;;

let of_host_port ~host ~port =
  match host_port_of_parts ~host ~port:(Some port) with
  | Some authority ->
    Ok
      { host = authority.host
      ; port = authority.port
      ; scheme = Http
      ; trust_class = Configured_bind
      }
  | None -> Error `Malformed
;;

let parse_serialized_origin raw =
  if String.equal raw "" || not (String.equal raw (String.trim raw))
  then Error `Malformed
  else
    match String.index_opt raw ':' with
    | None | Some 0 -> Error `Malformed
    | Some scheme_end ->
      let scheme_raw = String.sub raw 0 scheme_end in
      let authority_start = scheme_end + 3 in
      if authority_start > String.length raw
         || scheme_end + 2 >= String.length raw
         || not (Char.equal raw.[scheme_end + 1] '/')
         || not (Char.equal raw.[scheme_end + 2] '/')
      then Error `Malformed
      else
        let authority_raw =
          String.sub raw authority_start (String.length raw - authority_start)
        in
        (match scheme_of_string scheme_raw, parse_h2 authority_raw with
         | Some scheme, Some authority -> Ok { authority; scheme }
         | Some _, None | None, _ -> Error `Malformed)
;;

let serialized_origin_host origin = origin.authority.host
let serialized_origin_scheme origin = origin.scheme

let serialized_origin_equal left right =
  left.scheme = right.scheme
  && host_port_equivalent_for_scheme
       ~scheme:left.scheme
       left.authority
       right.authority
;;

let serialized_origin_matches_authority origin authority =
  origin.scheme = authority.scheme
  && String.equal origin.authority.host authority.host
  && Option.equal Int.equal
       (effective_host_port ~scheme:origin.scheme origin.authority)
       (effective_port ~scheme:authority.scheme authority)
;;

let current_key : authority Eio.Fiber.key = Eio.Fiber.create_key ()

let with_current authority f = Eio.Fiber.with_binding current_key authority f
let current () = Eio.Fiber.get current_key

let current_exn () =
  match current () with
  | Some authority -> authority
  | None -> raise Unbound_request_authority
;;
