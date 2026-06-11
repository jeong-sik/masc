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

(** Prefix for chat cursor keys stored in [oas_env]. *)
let chat_cursor_oas_key_prefix = "MASC_KEEPER_OAS_CHAT_CURSOR_"

(** [cursor_key_of_keeper_name name] builds the oas_env key for
    storing the per-keeper chat cursor (line count). *)
let cursor_key_of_keeper_name name =
  let sanitized = String.uppercase_ascii name in
  chat_cursor_oas_key_prefix ^ sanitized
;;

(** [read_cursor_from_meta ~meta ~keeper_name] reads the current
    positional watermark (line count) for a keeper from meta.oas_env.
    Returns 0 when absent. *)
let read_cursor_from_meta ~(meta : keeper_meta) ~keeper_name : int =
  let key = cursor_key_of_keeper_name keeper_name in
  match List.assoc_opt key meta.oas_env with
  | Some raw -> (try int_of_string raw with _ -> 0)
  | None -> 0
;;

(** [chat_line_count ~base_dir ~keeper_name] returns the number of
    JSONL lines in the keeper's chat store file. *)
let chat_line_count ~base_dir ~keeper_name : int =
  let messages = Keeper_chat_store.load ~base_dir ~keeper_name in
  List.length messages
;;

let collect_message_scope ~(config : Workspace.config) ~(meta : keeper_meta)
  : (string * string) list * (string * string) list * (string * int) list
  =
  let targets = message_feed_targets meta in
  let base_dir = config.base_path in
  let updates =
    List.filter_map (fun name ->
      let current_cursor = read_cursor_from_meta ~meta ~keeper_name:name in
      let actual_line_count = chat_line_count ~base_dir ~keeper_name:name in
      if actual_line_count > current_cursor then
        Some (name, actual_line_count)
      else
        None
    ) targets
  in
  [], [], updates
;;

let apply_message_cursor_updates (meta : keeper_meta) (updates : (string * int) list)
  : keeper_meta
  =
  let new_entries =
    List.map (fun (name, cursor) ->
      (cursor_key_of_keeper_name name, string_of_int cursor)
    ) updates
  in
  let merged =
    List.fold_left (fun acc (k, v) ->
      (* Replace existing entry or add new *)
      (k, v) :: List.filter (fun (k', _) -> k' <> k) acc
    ) meta.oas_env new_entries
  in
  { meta with oas_env = merged }
;;