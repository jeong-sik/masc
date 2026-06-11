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

(* RFC-0230 §3.1 — boundary parse: turn one lane line into a typed signal.

   Pure over primitive inputs: [self_tokens] is the keeper's identity-token set
   (see [self_identity_tokens]) and [mention_targets] its addressable names (see
   [message_feed_targets]). The "@<target>" substring scan mirrors the board
   mention matcher (Keeper_world_observation_board_signal.match_signal) and runs
   once here, producing a typed [lane_signal] rather than a downstream substring
   gate. P1 classifies a non-self, non-mention line as [Ambient]; [Scope_message]
   is emitted in RFC-0230 P2 once scope subscription is wired. *)
type lane_signal =
  | Direct_mention of { speaker : string; at : float }
  | Scope_message of { speaker : string; at : float }
  | Self_authored
  | Ambient

let classify_lane_line
      ~(self_tokens : string list)
      ~(mention_targets : string list)
      ~(speaker : string)
      ~(text : string)
      ~(at : float)
  : lane_signal
  =
  if is_self_author ~self_tokens speaker
  then Self_authored
  else (
    let haystack = String.lowercase_ascii text in
    let is_mention target =
      let needle = "@" ^ String.lowercase_ascii (String.trim target) in
      needle <> "@" && String_util.contains_substring haystack needle
    in
    if List.exists is_mention mention_targets
    then Direct_mention { speaker; at }
    else Ambient)
;;

let collect_message_scope ~(config : Workspace.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list * (string * int) list
  =
  let _ = config in
  let _ = meta in
  [], [], []
;;

let apply_message_cursor_updates (meta : keeper_meta) (updates : (string * int) list)
  : keeper_meta
  =
  let _ = updates in
  meta
;;
