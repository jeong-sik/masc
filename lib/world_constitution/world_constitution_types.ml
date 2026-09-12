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

module Non_empty = struct
  type 'a t = { head : 'a; tail : 'a list }

  let of_list = function
    | [] -> Error `Empty
    | head :: tail -> Ok { head; tail }

  let to_list { head; tail } = head :: tail
  let length { tail; _ } = 1 + List.length tail
end

type evidence = {
  uri : string;
  sha256 : string option;
}

type state =
  | Proposed of { post_id : string }
  | Ratified of { at : float; ratifiers : string Non_empty.t }
  | Superseded of { by : Article_id.t; at : float }
  | Repealed of { at : float; post_id : string }

type t = {
  id : Article_id.t;
  text : string;
  evidence : evidence Non_empty.t;
  proposer : string;
  state : state;
  last_cited_at : float option;
}

type invalid =
  | Empty_text
  | Empty_proposer
  | Empty_evidence_uri of { index : int }

let invalid_to_string = function
  | Empty_text -> "article text is empty"
  | Empty_proposer -> "article proposer is empty"
  | Empty_evidence_uri { index } ->
    Printf.sprintf "evidence[%d] has an empty uri" index

let is_blank s = String.equal (String.trim s) ""

let blank_evidence_index evidence =
  let rec scan index = function
    | [] -> None
    | item :: rest -> if is_blank item.uri then Some index else scan (index + 1) rest
  in
  scan 0 (Non_empty.to_list evidence)

let make ~id ~text ~evidence ~proposer ~state ~last_cited_at =
  if is_blank text then Error Empty_text
  else if is_blank proposer then Error Empty_proposer
  else
    match blank_evidence_index evidence with
    | Some index -> Error (Empty_evidence_uri { index })
    | None -> Ok { id; text; evidence; proposer; state; last_cited_at }

let cite article ~at =
  match article.last_cited_at with
  | Some existing when Float.compare existing at >= 0 -> article
  | Some _ | None -> { article with last_cited_at = Some at }

type transition_error = Illegal_transition of { from_ : state; to_ : state }

let state_name = function
  | Proposed _ -> "proposed"
  | Ratified _ -> "ratified"
  | Superseded _ -> "superseded"
  | Repealed _ -> "repealed"

let transition_error_to_string (Illegal_transition { from_; to_ }) =
  Printf.sprintf "illegal article transition %s -> %s" (state_name from_)
    (state_name to_)

let transition article ~to_ =
  let illegal = Error (Illegal_transition { from_ = article.state; to_ }) in
  let move () = Ok { article with state = to_ } in
  match article.state, to_ with
  (* A proposal that reached quorum, or one its author withdrew. *)
  | Proposed _, Ratified _ -> move ()
  | Proposed _, Repealed _ -> move ()
  (* Nothing supersedes a norm that never took force, and re-proposing is a
     new article, not a move. *)
  | Proposed _, Superseded _ -> illegal
  | Proposed _, Proposed _ -> illegal
  (* In force: replaced by a successor, or withdrawn at the cost that put it
     here (RFC-0442 3.2). *)
  | Ratified _, Superseded _ -> move ()
  | Ratified _, Repealed _ -> move ()
  (* Re-ratifying hides whether the second vote carried, and a ratified norm
     cannot return to a proposal. *)
  | Ratified _, Ratified _ -> illegal
  | Ratified _, Proposed _ -> illegal
  (* Superseded is terminal: the successor is the live article. *)
  | Superseded _, Proposed _ -> illegal
  | Superseded _, Ratified _ -> illegal
  | Superseded _, Superseded _ -> illegal
  | Superseded _, Repealed _ -> illegal
  (* Repealed is terminal: a world that wants the norm back ratifies a new
     article, leaving the repeal legible in the ledger. *)
  | Repealed _, Proposed _ -> illegal
  | Repealed _, Ratified _ -> illegal
  | Repealed _, Superseded _ -> illegal
  | Repealed _, Repealed _ -> illegal

