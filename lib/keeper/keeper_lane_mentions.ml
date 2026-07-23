(** Boundary mention parser — see the interface.  The tokenization is a
    verbatim relocation of the legacy read-time tokenizer
    ([trim_token_edges] + whitespace split); equivalence against the
    legacy decision procedure is pinned by test_keeper_lane_mentions. *)

(* Trim non-word characters from both ends of a token, keeping internal
   ones.  Word chars are [a-z0-9@_-]; '.' is NOT a word char, so
   "@alice." trims to "@alice" while the internal '.' in
   "email@alice.com" is preserved (the whole token stays
   "email@alice.com" and never equals "@alice"). *)
let trim_token_edges s =
  let is_word c =
    (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9')
    || c = '@'
    || c = '_'
    || c = '-'
  in
  let n = String.length s in
  let i = ref 0 in
  let j = ref (n - 1) in
  while !i < n && not (is_word s.[!i]) do
    incr i
  done;
  while !j >= !i && not (is_word s.[!j]) do
    decr j
  done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)
;;

let normalized_tokens content =
  let normalized =
    String.map
      (fun c ->
        match c with
        | '\t' | '\n' | '\r' -> ' '
        | _ -> c)
      (String.lowercase_ascii content)
  in
  String.split_on_char ' ' normalized
  |> List.map trim_token_edges
  |> List.filter (fun token -> not (String.equal token ""))
;;

type explicit_address =
  | No_explicit_address
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list

let explicit_address_of_content content =
  let tokens = normalized_tokens content in
  let broadcast_selectors =
    tokens
    |> List.filter_map (fun token ->
      if String.length token >= 2 && String.starts_with ~prefix:"@@" token
      then Some (String.sub token 2 (String.length token - 2))
      else None)
    |> List.sort_uniq String.compare
  in
  if
    broadcast_selectors <> []
    && List.for_all (String.equal "all") broadcast_selectors
  then Broadcast_all
  else if broadcast_selectors <> []
  then Unsupported_broadcast broadcast_selectors
  else (
    let targets =
      tokens
      |> List.filter_map (fun token ->
        if
          String.length token >= 2
          && token.[0] = '@'
          && not (String.starts_with ~prefix:"@@" token)
        then
          Keeper_identity.Keeper_id.of_string
            (String.sub token 1 (String.length token - 1))
        else None)
      |> List.sort_uniq Keeper_identity.Keeper_id.compare
    in
    match targets with
    | [] -> No_explicit_address
    | _ :: _ -> Targets targets)
;;

let mention_ids_of_content content =
  match explicit_address_of_content content with
  | Targets targets -> targets
  | No_explicit_address | Broadcast_all | Unsupported_broadcast _ -> []
;;

let target_ids_of (targets : string list) :
  Keeper_identity.Keeper_id.t list
  =
  List.filter_map Keeper_identity.Keeper_id.of_string targets
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let ids_match ~(target_ids : Keeper_identity.Keeper_id.t list)
      (mentions : Keeper_identity.Keeper_id.t list)
  : bool
  =
  List.exists
    (fun mention ->
      List.exists (Keeper_identity.Keeper_id.equal mention) target_ids)
    mentions
;;
