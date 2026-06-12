(** See [keeper_world_observation_message_scope.mli] for the contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory
open Keeper_context_runtime

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
;;

(* RFC-0232 §3.4: identities are minted once at the parse boundary by
   [Keeper_id.of_string]; the multi-form token-set expansion that used to
   live here moved inside it.  A keeper's self is the (≤2-element) id set
   minted from its name and agent name — they usually collapse to the
   same canonical id. *)
let self_ids (meta : keeper_meta) : Keeper_identity.Keeper_id.t list =
  List.filter_map
    Keeper_identity.Keeper_id.of_string
    [ meta.name; meta.agent_name ]
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

(* Single source of truth for "is this author one of us?". *)
let is_self_author ~self_ids (author : string) : bool =
  match Keeper_identity.Keeper_id.of_string author with
  | None -> false
  | Some author_id ->
    List.exists (Keeper_identity.Keeper_id.equal author_id) self_ids
;;

let is_keeper_authored_message author =
  Option.is_some (Keeper_identity.canonical_keeper_name_from_agent_name author)
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

   RFC-0232 P1: "newer" is lane order, not wall-clock. The lane is an
   append-only file, so its line order is the true arrival order; the
   watermark is the *position* of the keeper's last assistant line. Folding
   forward, an assistant line clears every candidate accumulated so far —
   no float comparisons, no equal-timestamp conventions, no skew
   sensitivity. [append_turn]'s user→tool→assistant write order makes a
   turn's own user line answered by its own reply, as before.

   Pure over the loaded lane so it is testable without I/O; [collect_message_scope]
   only adds the [Keeper_chat_store.load]. *)

(* User lines after the keeper's last assistant line, in lane order. The
   shared positional watermark for mentions and scope. Only an assistant
   *utterance* is a self reply; a [Transport_failure] row is the server
   persisting a failed request terminal — the keeper never answered, so
   the user line stays pending until the keeper's next real utterance
   (which, per positional semantics, clears every pending line). *)
let user_lines_after_last_self (messages : Keeper_chat_store.chat_message list)
  : Keeper_chat_store.chat_message list
  =
  List.fold_left
    (fun acc (m : Keeper_chat_store.chat_message) ->
      match m.role with
      | Keeper_chat_store.Role.Assistant -> (
        match m.kind with
        | Keeper_chat_store.Row_kind.Utterance -> []
        | Keeper_chat_store.Row_kind.Transport_failure -> acc)
      | Keeper_chat_store.Role.User -> m :: acc
      | Keeper_chat_store.Role.Tool -> acc)
    []
    messages
  |> List.rev
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
  let target_ids = Keeper_lane_mentions.target_ids_of targets in
  user_lines_after_last_self messages
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
    if Keeper_lane_mentions.ids_match ~target_ids m.mentions
    then Some (speaker_display m, m.content)
    else None)
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
  let target_ids = Keeper_lane_mentions.target_ids_of targets in
  user_lines_after_last_self messages
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
    if
      is_owner_authored m
      && not (Keeper_lane_mentions.ids_match ~target_ids m.mentions)
    then Some (speaker_display m, m.content)
    else None)
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
