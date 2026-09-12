module Article_id = struct
  type t = string

  (* [generate] is the only minter, so the parser accepts exactly what it
     mints. Board learned this the hard way: a keeper that types an id by hand
     reaches the store as a lookup that can only miss (Board_types.Comment_id,
     #29457). An article id is refused at the boundary instead. *)
  let prefix = "a-"
  let random_bytes = 16
  let hex_length = 2 * random_bytes
  let accepted_format = Printf.sprintf "%s<%d lowercase hex>" prefix hex_length
  let json_schema_pattern = Printf.sprintf "^%s[0-9a-f]{%d}$" prefix hex_length
  let valid_pattern = Re.Pcre.re json_schema_pattern |> Re.compile

  let of_string s =
    let s = String.trim s in
    if Re.execp valid_pattern s then Ok s
    else
      Error
        (Printf.sprintf "Invalid article_id %S; expected %s" s accepted_format)

  let to_string t = t
  let generate () = Random_id.prefixed ~prefix ~bytes:random_bytes
  let equal = String.equal
end

type evidence = {
  uri : string;
  sha256 : string option;
}

type t = {
  id : Article_id.t;
  text : string;
  author : string;
  at : float;
  evidence : evidence list;
}

type invalid =
  | Empty_text
  | Multiline_text
  | Empty_author
  | Empty_evidence_uri of { index : int }

let invalid_to_string = function
  | Empty_text -> "article text is empty"
  | Multiline_text ->
    "article text spans more than one line; an article is one sentence"
  | Empty_author -> "article author is empty"
  | Empty_evidence_uri { index } ->
    Printf.sprintf "evidence[%d] has an empty uri" index

let is_blank s = String.equal (String.trim s) ""

let blank_evidence_index evidence =
  let rec scan index = function
    | [] -> None
    | item :: rest -> if is_blank item.uri then Some index else scan (index + 1) rest
  in
  scan 0 evidence

let is_multiline s =
  String.exists (fun c -> Char.equal c '\n' || Char.equal c '\r') s

let make ~id ~text ~author ~at ~evidence =
  if is_blank text then Error Empty_text
  else if is_multiline text then Error Multiline_text
  else if is_blank author then Error Empty_author
  else
    match blank_evidence_index evidence with
    | Some index -> Error (Empty_evidence_uri { index })
    | None -> Ok { id; text; author; at; evidence }

type entry =
  | Added of t
  | Removed of {
      id : Article_id.t;
      by : string;
      at : float;
    }
