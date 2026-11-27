type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

type get = url:string -> headers:(string * string) list -> (response, string) result
type post = url:string -> headers:(string * string) list -> body:string -> (response, string) result

let max_answer_bytes = 64 * 1024

(* An https URL with a host and no query or fragment: the rule for a
   provider endpoint and for the redirect URI of a client. *)
let has_control_or_space s =
  String.exists (fun ch -> let code = Char.code ch in code <= 0x20 || code = 0x7f) s
;;

let is_https_url url =
  if String.equal url "" || has_control_or_space url then false
  else
    let uri = Uri.of_string url in
    let valid_port =
      match Uri.port uri with
      | None -> true
      | Some p -> p >= 1 && p <= 65535
    in
    match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.query uri, Uri.fragment uri with
    | Some "https", Some host, None, [], None when String.length host > 0 && valid_port -> true
    | _ -> false
;;

let is_unreserved = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false
;;

(* Percent-encodes every byte that is not unreserved (RFC 3986 section 2.3),
   which a query and an application/x-www-form-urlencoded body both read. *)
let encode text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      if is_unreserved c
      then Buffer.add_char buffer c
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code c)))
    text;
  Buffer.contents buffer
;;

let form pairs = String.concat "&" (List.map (fun (key, value) -> encode key ^ "=" ^ encode value) pairs)

