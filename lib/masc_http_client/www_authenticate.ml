(** See www_authenticate.mli. The grammar quoted there is RFC 9110 11.6.1
    with 5.6.2 (token), 5.6.3 (whitespace) and 5.6.4 (quoted-string); the
    section numbers below point into that document. *)

type credentials =
  | Params of (string * string) list
  | Token68 of string

type challenge = {
  scheme : string;
  credentials : credentials;
}

type fault =
  | No_challenge
  | Expected_token of int
  | Expected_delimiter of int
  | Param_before_scheme of int
  | Param_after_token68 of int
  | Expected_value of int
  | Bad_quoted_character of int
  | Bad_quoted_pair of int
  | Unterminated_quoted_string of int

let fault_to_string = function
  | No_challenge -> "no challenge: the value holds only whitespace and commas"
  | Expected_token at ->
    Printf.sprintf "byte %d: a scheme or a parameter name should start here" at
  | Expected_delimiter at ->
    Printf.sprintf
      "byte %d: only a comma, whitespace or the end of the value may follow here"
      at
  | Param_before_scheme at ->
    Printf.sprintf "byte %d: a parameter with no scheme before it" at
  | Param_after_token68 at ->
    Printf.sprintf
      "byte %d: a parameter in a challenge that already holds a token68" at
  | Expected_value at ->
    Printf.sprintf
      "byte %d: a token or a quoted string should follow the equals sign" at
  | Bad_quoted_character at ->
    Printf.sprintf "byte %d: this character may not appear inside quotes" at
  | Bad_quoted_pair at ->
    Printf.sprintf
      "byte %d: a backslash inside quotes must be followed by one quotable octet"
      at
  | Unterminated_quoted_string at ->
    Printf.sprintf "byte %d: the quoted string opened here never closes" at

let ( let* ) = Result.bind

(* ── character classes, each one rule of the grammar ─────────────────── *)

let is_alpha c = ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
let is_digit c = '0' <= c && c <= '9'

(* 5.6.2: tchar is any VCHAR except the delimiters. *)
let tchar_punctuation = "!#$%&'*+-.^_`|~"
let is_tchar c = is_alpha c || is_digit c || String.contains tchar_punctuation c

(* 11.2: the body of a token68, before its trailing padding. *)
let token68_punctuation = "-._~+/"

let is_token68_char c =
  is_alpha c || is_digit c || String.contains token68_punctuation c

let is_padding c = Char.equal c '='

(* 5.6.3: OWS and BWS are the same octets; SP alone separates a scheme
   from what follows it (11.3). *)
let is_ows c = Char.equal c ' ' || Char.equal c '\t'
let is_sp c = Char.equal c ' '

(* 5.6.4, with obs-text (%x80-FF) and VCHAR (%x21-7E) from 5.5 and 2.1. *)
let is_obs_text c = '\x80' <= c
let is_vchar c = '\x21' <= c && c <= '\x7E'

let is_qdtext c =
  is_ows c
  || Char.equal c '\x21'
  || ('\x23' <= c && c <= '\x5B')
  || ('\x5D' <= c && c <= '\x7E')
  || is_obs_text c

let is_quoted_pair_octet c = is_ows c || is_vchar c || is_obs_text c

let dquote = '"'
let backslash = '\\'
let comma = ','
let equals = '='

(* ── the reader ──────────────────────────────────────────────────────── *)

(* The end of the longest run of [keep] characters starting at [from]. *)
let span value ~from ~keep =
  let length = String.length value in
  let rec go at = if at < length && keep value.[at] then go (at + 1) else at in
  go from

(* A quoted-string whose opening quote is at [from]: the text with the
   quoting removed, and the offset just past the closing quote. *)
let quoted_string value ~from =
  let length = String.length value in
  let text = Buffer.create (length - from) in
  let rec go at =
    if at >= length then Error (Unterminated_quoted_string from)
    else
      let c = value.[at] in
      if Char.equal c dquote then Ok (Buffer.contents text, at + 1)
      else if Char.equal c backslash then
        if at + 1 < length && is_quoted_pair_octet value.[at + 1] then (
          Buffer.add_char text value.[at + 1];
          go (at + 2))
        else Error (Bad_quoted_pair at)
      else if is_qdtext c then (
        Buffer.add_char text c;
        go (at + 1))
      else Error (Bad_quoted_character at)
  in
  go (from + 1)

(* Parameters are consed as they are read; a finished challenge has them
   in the order they were written. *)
let close challenge =
  match challenge.credentials with
  | Params newest_first ->
    { challenge with credentials = Params (List.rev newest_first) }
  | Token68 _ -> challenge

let parse value =
  let length = String.length value in
  let at_end at = at >= length in
  let is_element_end at = at_end at || Char.equal value.[at] comma in
  (* After a complete element: OWS, then a comma or the end. *)
  let element_end at =
    let at = span value ~from:at ~keep:is_ows in
    if is_element_end at then Ok at else Error (Expected_delimiter at)
  in
  (* Just past [BWS "=" BWS]: a token or a quoted-string. *)
  let param_value at =
    if at_end at then Error (Expected_value at)
    else if Char.equal value.[at] dquote then quoted_string value ~from:at
    else
      let stop = span value ~from:at ~keep:is_tchar in
      if stop = at then Error (Expected_value at)
      else Ok (String.sub value at (stop - at), stop)
  in
  (* A token68 fills its element; anything else at [at] is not one. *)
  let token68 at =
    let body_end = span value ~from:at ~keep:is_token68_char in
    if body_end = at then None
    else
      let stop = span value ~from:body_end ~keep:is_padding in
      let next = span value ~from:stop ~keep:is_ows in
      if is_element_end next then Some (String.sub value at (stop - at), next)
      else None
  in
  (* [current] is the challenge still taking parameters; [closed] holds the
     finished ones, newest first. *)
  let rec elements at current closed =
    let at = span value ~from:at ~keep:is_ows in
    if at_end at then
      match current with
      | None -> Error No_challenge
      | Some challenge -> Ok (List.rev (close challenge :: closed))
    else if Char.equal value.[at] comma then elements (at + 1) current closed
    else
      let stop = span value ~from:at ~keep:is_tchar in
      if stop = at then Error (Expected_token at)
      else
        let name = String.sub value at (stop - at) in
        let after_bws = span value ~from:stop ~keep:is_ows in
        if (not (at_end after_bws)) && Char.equal value.[after_bws] equals then
          (* 11.3: a token followed by "=" is an auth-param of the challenge
             being read; a bare token is the next scheme. *)
          match current with
          | None -> Error (Param_before_scheme at)
          | Some { credentials = Token68 _; _ } -> Error (Param_after_token68 at)
          | Some { scheme; credentials = Params newest_first } ->
            let* text, next =
              param_value (span value ~from:(after_bws + 1) ~keep:is_ows)
            in
            let* next = element_end next in
            elements next
              (Some { scheme; credentials = Params ((name, text) :: newest_first) })
              closed
        else
          let closed =
            match current with
            | None -> closed
            | Some challenge -> close challenge :: closed
          in
          after_scheme stop name closed
  (* Just past a scheme: the end, OWS then a comma, or 1*SP and then a
     token68 or the parameter list (whose first element may be empty). *)
  and after_scheme at scheme closed =
    let bare = Some { scheme; credentials = Params [] } in
    if at_end at then elements at bare closed
    else if is_sp value.[at] then
      let at = span value ~from:at ~keep:is_sp in
      match token68 at with
      | Some (text, next) ->
        elements next (Some { scheme; credentials = Token68 text }) closed
      | None -> elements at bare closed
    else
      let* at = element_end at in
      elements at bare closed
  in
  elements 0 None []

(* ── selection ───────────────────────────────────────────────────────── *)

let same_name a b = String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)

let param challenge ~name =
  match challenge.credentials with
  | Token68 _ -> None
  | Params params ->
    List.find_map
      (fun (key, text) -> if same_name key name then Some text else None)
      params

let find_param challenges ~scheme ~name =
  List.find_map
    (fun challenge ->
      if same_name challenge.scheme scheme then param challenge ~name else None)
    challenges

let field_name = "www-authenticate"
let bearer = "Bearer"
let resource_metadata = "resource_metadata"

let resource_metadata_of_headers headers =
  List.find_map
    (fun (key, value) ->
      if same_name key field_name then
        Option.bind (Result.to_option (parse value)) (fun challenges ->
            find_param challenges ~scheme:bearer ~name:resource_metadata)
      else None)
    headers
