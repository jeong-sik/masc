type authority =
  { host : string
  ; port : int option
  }

type classification =
  | Missing
  | Single of authority
  | Multiple
  | Malformed

type h2_classification =
  | H2_authority of classification
  | Unsupported_asterisk_form_options

exception Unbound_request_authority

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

let classify_values ~multiple values =
  match values with
  | [] -> Missing
  | [ raw ] -> Option.fold ~none:Malformed ~some:(fun value -> Single value) (parse raw)
  | _ -> multiple
;;

let classify_http1_request request =
  classify_values
    ~multiple:Multiple
    (Httpun.Headers.get_multi request.Httpun.Request.headers "host")
;;

let default_port_for_scheme scheme =
  match String.lowercase_ascii scheme with
  | "http" -> Some 80
  | "https" -> Some 443
  | _ -> None
;;

let effective_port ~scheme authority =
  match authority.port with
  | Some _ as explicit -> explicit
  | None -> default_port_for_scheme scheme
;;

let equivalent_for_scheme ~scheme left right =
  String.equal left.host right.host
  && Option.equal Int.equal
       (effective_port ~scheme left)
       (effective_port ~scheme right)
;;

let classify_h2_request request =
  let authorities = H2.Headers.get_multi request.H2.Request.headers ":authority" in
  let hosts = H2.Headers.get_multi request.H2.Request.headers "host" in
  match authorities with
  | []
    when request.H2.Request.meth = `OPTIONS
         && String.equal request.H2.Request.target "*" ->
    (match hosts with
     | [] -> Unsupported_asterisk_form_options
     | [ raw_host ] ->
       (match parse_h2 raw_host with
        | Some _ -> Unsupported_asterisk_form_options
        | None -> H2_authority Malformed)
     | _ -> H2_authority Malformed)
  | [] ->
    H2_authority
      (match hosts with
       | [] | [ _ ] -> Missing
       | _ -> Malformed)
  | [ raw_authority ] ->
    let classification =
      match parse_h2 raw_authority with
      | None -> Malformed
      | Some authority ->
        (match hosts with
         | [] -> Single authority
         | [ raw_host ] ->
           (match parse_h2 raw_host with
            | Some host
              when equivalent_for_scheme
                     ~scheme:request.H2.Request.scheme
                     authority
                     host ->
              Single authority
            | Some _ | None -> Malformed)
         | _ -> Malformed)
    in
    H2_authority classification
  | _ -> H2_authority Malformed
;;

let host authority = authority.host
let port authority = authority.port

let rendered_host authority =
  match Ipaddr.V6.of_string authority.host with
  | Ok _ -> "[" ^ authority.host ^ "]"
  | Error _ -> authority.host
;;

let rendered authority =
  match authority.port with
  | None -> rendered_host authority
  | Some port -> Printf.sprintf "%s:%d" (rendered_host authority) port
;;

let of_host_port ~host ~port =
  let raw_host =
    match Ipaddr.V6.of_string host with
    | Ok _ -> "[" ^ host ^ "]"
    | Error _ -> host
  in
  match parse (Printf.sprintf "%s:%d" raw_host port) with
  | Some authority -> Ok authority
  | None -> Error `Malformed
;;

let current_key : authority Eio.Fiber.key = Eio.Fiber.create_key ()

let with_current authority f = Eio.Fiber.with_binding current_key authority f
let current () = Eio.Fiber.get current_key

let current_exn () =
  match current () with
  | Some authority -> authority
  | None -> raise Unbound_request_authority
;;
