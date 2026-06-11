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
  let from_content =
    match m.source with
    | Some "slack" | Some "discord" -> Some (m.content)
    | _ -> None
  in
  match from_speaker with
  | Some name -> " [" ^ name ^ "]"
  | None -> ""
;;

(* [substring_count s pat] returns the number of non-overlapping
   occurrences of [pat] in [s]. *)
let substring_count s pat =
  let pat_len = String.length pat in
  if pat_len = 0 then 0
  else
    let n = ref 0 in
    let i = ref 0 in
    while !i <= String.length s - pat_len do
      if String.sub s !i pat_len = pat then (
        incr n;
        i := !i + pat_len)
      else incr i
    done;
    !n
;;

let collect_chat_scope
  ?(minimum_role = Keeper_chat_role.User)
  ~(meta : keeper_meta)
  ~(config : Workspace_interface_types.config)
  ()
  =
  let targets = message_feed_targets meta in
  let base_dir = config.base_path in
  let lines =
    List.concat_map
      (fun name ->
        let unread = Keeper_chat_store.load ~base_dir ~keeper_name:name
          ~role_filter:(Keeper_chat_role.RoleSet.of_list [Keeper_chat_role.User; Keeper_chat_role.Assistant])
          ()
        in
        let reverse_sorted =
          List.sort (fun (a : Keeper_chat_store.chat_message) (b : Keeper_chat_store.chat_message) ->
            Float.compare (Option.value ~default:0.0 b.ts) (Option.value ~default:0.0 a.ts))
          unread
        in
        let newest = List.filteri (fun i _ -> i < 5) reverse_sorted in
        let in_targets =
          List.exists (fun (m : Keeper_chat_store.chat_message) ->
            line_mentions ~targets m.content)
          unread
        in
        let has_target_mention =
          List.exists (fun (m : Keeper_chat_store.chat_message) ->
            line_mentions ~targets m.content) newest
        in
        let mention_badge =
          if has_target_mention then " [MENTION]" else ""
        in
        let lines =
          List.rev_map (fun (m : Keeper_chat_store.chat_message) ->
            let role_label = Keeper_chat_role.to_string m.role in
            let speaker_label = speaker_display m in
            (name ^ speaker_label ^ " " ^ role_label ^ "> " ^ m.content,
             name ^ speaker_label ^ " " ^ role_label ^ "> " ^ m.content))
          (List.rev newest)
        in
        if in_targets || List.length lines >= 4 then
          (name, mention_badge, lines)
        else
          (name, "", lines))
      targets
  in
  lines

(** {1 Positional watermark (RFC-0232 role cursor)} *)

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

(** [collect_message_scope] gathers all new messages since the last
    positional watermark for each target keeper. Returns a list of
    (keeper_name, new_message_count) tuples. *)
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
  ([], [], updates)
;;

(** [apply_message_cursor_updates] persists new cursor positions
    back into meta.oas_env after a message cycle. *)
let apply_message_cursor_updates ~(meta : keeper_meta) ~(updates : (string * int) list) =
  List.fold_left (fun (meta : keeper_meta) (name, count) ->
    let key = cursor_key_of_keeper_name name in
    { meta with
      oas_env = (key, string_of_int count) :: meta.oas_env
    }
  ) meta updates
;;