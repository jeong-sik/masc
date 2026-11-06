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
let is_https_url url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri, Uri.query uri, Uri.fragment uri with
  | Some "https", Some host, [], None when String.length host > 0 -> true
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

