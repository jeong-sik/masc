(* A link's base is an http(s) origin of printable ASCII with a host, an
   optional valid port, and no userinfo, path, query, or fragment. A value
   outside this contract cannot form [<base>/play#<token>] or
   [<base>/accounts/invite#<token>] that a browser, a QR code, and the
   server's root-mounted routes agree on. The rule lives here, below the
   readers of the setting, so the runtime.toml loader, the Play invite and
   masc auth judge one base URL by one rule. *)
let is_valid_port_suffix suffix =
  if String.equal suffix "" then true
  else if not (Char.equal suffix.[0] ':') then false
  else
    let raw_port = String.sub suffix 1 (String.length suffix - 1) in
    raw_port <> ""
    && String.for_all (fun c -> c >= '0' && c <= '9') raw_port
    &&
    match int_of_string_opt raw_port with
    | Some port -> port >= 1 && port <= 65_535
    | None -> false

let is_valid_reg_name_char c =
  (c >= '0' && c <= '9')
  || (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || String.contains "-._~!$&'()*+,;=" c

(* WHATWG special hosts ending in a number are IPv4, including shortened,
   octal and hexadecimal forms. A generic URI reg-name check does not perform
   these range checks: https://url.spec.whatwg.org/#concept-ipv4-parser . *)
let ipv4_number raw =
  let len = String.length raw in
  let radix, offset =
    if len >= 2 && Char.equal raw.[0] '0' then
      if Char.equal raw.[1] 'x' || Char.equal raw.[1] 'X' then 16, 2
      else 8, 1
    else 10, 0
  in
  let rec parse i value =
    if i = len then Some value
    else
      let digit = match raw.[i] with
        | '0' .. '9' as c -> Char.code c - Char.code '0'
        | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
        | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
        | _ -> radix
      in
      (* The IPv4 address space is 32 bits; reject before multiplication can
         overflow, even if the input has arbitrarily many digits. *)
      if digit >= radix || value > (0xffff_ffff - digit) / radix then None
      else parse (i + 1) (value * radix + digit)
  in
  if len = 0 then None else parse offset 0

let is_valid_numeric_host host =
  let parts = String.split_on_char '.' host in
  let reversed = match List.rev parts with
    | "" :: (_ :: _ as rest) -> rest
    | rest -> rest
  in
  match reversed with
  | [] -> false
  | last :: preceding ->
    let ends_in_number =
      (last <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) last)
      || (String.length last >= 2 && Char.equal last.[0] '0'
          && (Char.equal last.[1] 'x' || Char.equal last.[1] 'X')
          && String.for_all (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
               (String.sub last 2 (String.length last - 2)))
    in
    if not ends_in_number then true
    else
      let count = List.length reversed in
      count <= 4
      && List.for_all (fun part -> match ipv4_number part with
          | Some number -> number <= 255
          | None -> false) preceding
      && (match ipv4_number last with
          | Some number -> number < (1 lsl (8 * (5 - count)))
          | None -> false)

let is_valid_authority authority =
  let len = String.length authority in
  if len = 0 then false
  else if Char.equal authority.[0] '[' then
    match String.index_opt authority ']' with
    | None | Some 1 -> false
    | Some close ->
      let raw_host = String.sub authority 1 (close - 1) in
      let suffix = String.sub authority (close + 1) (len - close - 1) in
      Result.is_ok (Ipaddr.V6.of_string raw_host) && is_valid_port_suffix suffix
  else
    let host, suffix =
      match String.index_opt authority ':' with
      | None -> authority, ""
      | Some i ->
        String.sub authority 0 i, String.sub authority i (len - i)
    in
    host <> ""
    && String.for_all is_valid_reg_name_char host
    && is_valid_numeric_host host
    && is_valid_port_suffix suffix

let is_http_origin base =
  let authority_opt =
    if String.starts_with ~prefix:"https://" base
    then Some (String.sub base 8 (String.length base - 8))
    else if String.starts_with ~prefix:"http://" base
    then Some (String.sub base 7 (String.length base - 7))
    else None
  in
  match authority_opt with
  | None -> false
  | Some authority ->
    String.for_all (fun c -> c > ' ' && c < '\127') base
    && is_valid_authority authority
    &&
    let uri = Uri.of_string base in
    Option.is_none (Uri.userinfo uri)
    && (match Uri.host uri with Some host -> host <> "" | None -> false)
    && (match Uri.port uri with None -> true | Some port -> port >= 1 && port <= 65_535)
    && String.equal (Uri.path uri) ""
    && Uri.query uri = []
    && Option.is_none (Uri.fragment uri)
