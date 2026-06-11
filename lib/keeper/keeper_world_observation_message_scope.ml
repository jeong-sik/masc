(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_context_runtime

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
;;

let normalized_identity_token value =
  let trimmed = String.lowercase_ascii (String.trim value) in
  if trimmed = "" then None else Some trimmed
;;

let identity_tokens_of_value value =
  let trimmed = String.trim value in
  [ normalized_identity_token trimmed
  ; Option.bind
      (Keeper_identity.canonical_keeper_name_from_agent_name trimmed)
      normalized_identity_token
  ; Option.bind (Keeper_identity.canonical_keeper_name trimmed) normalized_identity_token
  ]
  |> List.filter_map (fun value -> value)
  |> List.sort_uniq String.compare
;;

let self_identity_tokens (meta : keeper_meta) =
  [ meta.name; meta.agent_name ]
  |> List.map identity_tokens_of_value
  |> List.flatten
  |> List.sort_uniq String.compare
;;

(* Single source of truth for "is this author one of us?". *)
let is_self_author ~self_tokens (author : string) : bool =
  identity_tokens_of_value author
  |> List.exists (fun author_token -> List.mem author_token self_tokens)
;;

let is_keeper_authored_message author =
  Option.is_some (Keeper_identity.canonical_keeper_name_from_agent_name author)
;;

(* Trim non-word characters from both ends of a token, keeping internal ones.
   Word chars are [a-z0-9@_-]; '.' is NOT a word char, so "@dreamer." trims to
   "@dreamer" while the internal '.' in "email@dreamer.com" is preserved (the
   whole token stays "email@dreamer.com" and never equals "@dreamer"). *)
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
  while !i < n && not (is_word s.[!i]) do incr i done;
  while !j >= !i && not (is_word s.[!j]) do decr j done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)
;;

(* A line mentions a target when some whitespace token equals "@<target>"
   after edge-trimming. Token equality (not substring) is why "@dreamerx" and
   "email@dreamer.com" do not match "@dreamer". *)
let line_mentions ~(targets : string list) (content : string) : bool =
  let needles =
    List.filter_map
      (fun target ->
        let t = String.lowercase_ascii (String.trim target) in
        if t = "" then None else Some ("@" ^ t))
      targets
  in
  if needles = []
  then false
  else (
    let normalized =
      String.map
        (fun c -> match c with '\t' | '\n' | '\r' -> ' ' | _ -> c)
        (String.lowercase_ascii content)
    in
    String.split_on_char ' ' normalized
    |> List.exists (fun token -> List.mem (trim_token_edges token) needles))
;;

let speaker_display (m : Keeper_chat_store.chat_message) : string =
  let from_speaker =
    match m.speaker with
    | Some (s : Keeper_chat_store.speaker) -> s.speaker_name
    | None -> None
  in
  match from_speaker with
  | Some name when String.trim name <> "" -> name
  | _ ->
    (match m.source with
     | Some src when String.trim src <> "" -> src
     | _ -> "someone")
;;

(* RFC-0230: the lane is the state. A mention is pending when it arrives after
   the keeper's own last lane line; the keeper replying (a new assistant line,
   written when it posts to the lane) advances that watermark and clears the
   mention. No cursor, no stored engagement — "have I answered" is "is the
   mention newer than my last line". An unanswered mention stays pending across
   observations (it keeps the keeper reactive until it replies in the lane).

   Pure over the loaded lane so it is testable without I/O; [collect_message_scope]
   only adds the [Keeper_chat_store.load]. *)

(* The watermark: ts of the keeper's own last lane line (assistant role). A user
   line at or before it is already answered. *)
let last_self_ts (messages : Keeper_chat_store.chat_message list) : float =
  List.fold_left
    (fun acc (m : Keeper_chat_store.chat_message) ->
      match m.ts with
      | Some ts when m.role = "assistant" && ts > acc -> ts
      | _ -> acc)
    0.0
    messages
;;

let is_owner_authored (m : Keeper_chat_store.chat_message) : bool =
  match m.speaker with
  | Some (s : Keeper_chat_store.speaker) -> s.speaker_authority = Keeper_chat_store.Owner
  | None -> false
;;

let pending_mentions_of_messages
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : (string * string) list
  =
  let my_last_ts = last_self_ts messages in
  List.filter_map
    (fun (m : Keeper_chat_store.chat_message) ->
      match m.ts with
      | Some ts when ts > my_last_ts && m.role = "user" && line_mentions ~targets m.content
        -> Some (speaker_display m, m.content)
      | _ -> None)
    messages
;;

(* RFC-0230 P2 — scope messages: a keeper's lane is, in practice, an operator
   (Owner) conversation. The operator often addresses the keeper without an
   "@name", so an unanswered Owner line that is not already a mention is a scope
   message. External (connector) chatter without a mention is ignored, so a busy
   channel does not flood the keeper. Same watermark as mentions; the mention
   exclusion keeps the two reactive signals disjoint. *)
let pending_scope_of_messages
      ~(targets : string list)
      (messages : Keeper_chat_store.chat_message list)
  : (string * string) list
  =
  let my_last_ts = last_self_ts messages in
  List.filter_map
    (fun (m : Keeper_chat_store.chat_message) ->
      match m.ts with
      | Some ts
        when ts > my_last_ts
             && m.role = "user"
             && is_owner_authored m
             && not (line_mentions ~targets m.content) -> Some (speaker_display m, m.content)
      | _ -> None)
    messages
;;

let collect_message_scope ~(config : Workspace.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list
  =
  let messages =
    Keeper_chat_store.load ~base_dir:config.base_path ~keeper_name:meta.name
  in
  let targets = message_feed_targets meta in
  ( pending_mentions_of_messages ~targets messages
  , pending_scope_of_messages ~targets messages )
;;
