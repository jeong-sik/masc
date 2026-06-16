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

let mention_ids_of_content (content : string) :
  Keeper_identity.Keeper_id.t list
  =
  let normalized =
    String.map
      (fun c ->
        match c with
        | '\t' | '\n' | '\r' -> ' '
        | _ -> c)
      (String.lowercase_ascii content)
  in
  String.split_on_char ' ' normalized
  |> List.filter_map (fun token ->
    let trimmed = trim_token_edges token in
    if String.length trimmed >= 2 && trimmed.[0] = '@' then
      Keeper_identity.Keeper_id.of_string
        (String.sub trimmed 1 (String.length trimmed - 1))
    else None)
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
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
