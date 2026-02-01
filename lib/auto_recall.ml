(** Auto-Recall Memory - OpenClaw memU Pattern Implementation

    Automatic memory injection for MASC agents.
    Fetches relevant context from multiple sources and injects into prompts.

    Sources (Phase 1):
    - Masc_cache: Shared context store (API responses, embeddings, summaries)
    - Recent_broadcasts: Last N messages in the room

    Future sources (Phase 2):
    - File_context: Recently touched files
    - Neo4j/Qdrant: Graph/vector retrieval
*)

(** {1 Types} *)

(** Source types for context retrieval *)
type recall_source =
  | Masc_cache        (** Use existing masc_cache_get *)
  | Recent_broadcasts (** Last N broadcasts in room *)
  | File_context      (** Recently touched files - TODO: Phase 2 *)

(** Configuration for auto-recall *)
type recall_config = {
  enabled: bool;                 (** Enable/disable auto-recall *)
  sources: recall_source list;   (** Which sources to query *)
  max_tokens: int;               (** Budget per injection *)
  max_broadcasts: int;           (** Max broadcasts to fetch *)
  cache_tags: string list;       (** Filter cache by these tags *)
}

(** A single piece of recalled context *)
type recall_item = {
  source: recall_source;
  content: string;
  relevance: float;  (** 0.0 - 1.0, higher = more relevant *)
  metadata: Yojson.Safe.t;
}

(** Result of a recall operation *)
type recall_result = {
  items: recall_item list;
  total_tokens: int;  (** Approximate token count *)
  truncated: bool;    (** Whether results were truncated to fit budget *)
}

(** {1 Configuration} *)

(** Default configuration *)
let default_config = {
  enabled = true;
  sources = [Recent_broadcasts; Masc_cache];
  max_tokens = 2000;
  max_broadcasts = 10;
  cache_tags = [];
}

(** Create config from optional parameters *)
let make_config
    ?(enabled = true)
    ?(sources = [Recent_broadcasts; Masc_cache])
    ?(max_tokens = 2000)
    ?(max_broadcasts = 10)
    ?(cache_tags = [])
    () =
  { enabled; sources; max_tokens; max_broadcasts; cache_tags }

(** {1 Token Estimation} *)

(** Approximate token count for a string (rough: ~4 chars per token) *)
let estimate_tokens s =
  (String.length s + 3) / 4

(** {1 Source Fetchers} *)

(** Fetch from MASC cache *)
let fetch_from_cache (room_config : Room_utils.config) ~(config : recall_config) ~query:_ =
  let entries =
    match config.cache_tags with
    | [] -> Cache_eio.list room_config ()
    | tags ->
        (* Fetch entries matching any of the specified tags *)
        List.concat_map (fun tag ->
          Cache_eio.list room_config ~tag ()
        ) tags
        |> List.sort_uniq (fun a b -> compare a.Cache_eio.key b.Cache_eio.key)
  in
  List.map (fun (entry : Cache_eio.cache_entry) ->
    {
      source = Masc_cache;
      content = entry.value;
      relevance = 0.5;  (* Default relevance, could be improved with query matching *)
      metadata = `Assoc [
        ("key", `String entry.key);
        ("tags", `List (List.map (fun t -> `String t) entry.tags));
        ("created_at", `Float entry.created_at);
      ];
    }
  ) entries

(** Fetch recent broadcasts *)
let fetch_from_broadcasts (room_config : Room_utils.config) ~(config : recall_config) ~query:_ =
  let messages = Room.get_messages_raw room_config
    ~since_seq:0
    ~limit:config.max_broadcasts
  in
  List.mapi (fun i (msg : Types.message) ->
    (* More recent messages get higher relevance *)
    let relevance = 1.0 -. (float_of_int i /. float_of_int (max 1 (List.length messages))) in
    {
      source = Recent_broadcasts;
      content = Printf.sprintf "[%s] %s" msg.from_agent msg.content;
      relevance = relevance *. 0.8;  (* Cap at 0.8 for broadcasts *)
      metadata = `Assoc [
        ("seq", `Int msg.seq);
        ("from", `String msg.from_agent);
        ("timestamp", `String msg.timestamp);
        ("mention", match msg.mention with Some m -> `String m | None -> `Null);
      ];
    }
  ) messages

(** Fetch from a single source *)
let fetch_source room_config ~config ~query = function
  | Masc_cache -> fetch_from_cache room_config ~config ~query
  | Recent_broadcasts -> fetch_from_broadcasts room_config ~config ~query
  | File_context ->
      (* TODO: Phase 2 - integrate with room locks/recent file access *)
      []

(** {1 Main API} *)

(** Fetch context from configured sources

    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Optional query string for relevance ranking

    @return Recall result with items sorted by relevance, truncated to token budget
*)
let fetch_context
    (room_config : Room_utils.config)
    ~(config : recall_config)
    ?(query : string = "")
    ()
    : recall_result =
  if not config.enabled then
    { items = []; total_tokens = 0; truncated = false }
  else
    (* Fetch from all configured sources *)
    let all_items = List.concat_map (fetch_source room_config ~config ~query) config.sources in

    (* Sort by relevance (highest first) *)
    let sorted = List.sort (fun a b -> compare b.relevance a.relevance) all_items in

    (* Truncate to token budget *)
    let rec take_within_budget acc tokens = function
      | [] -> (List.rev acc, tokens, false)
      | item :: rest ->
          let item_tokens = estimate_tokens item.content in
          if tokens + item_tokens > config.max_tokens then
            (List.rev acc, tokens, true)  (* Truncated *)
          else
            take_within_budget (item :: acc) (tokens + item_tokens) rest
    in
    let (items, total_tokens, truncated) = take_within_budget [] 0 sorted in

    { items; total_tokens; truncated }

(** {1 Formatting} *)

(** Format recall result as injection-ready text *)
let format_for_injection (result : recall_result) : string =
  if result.items = [] then ""
  else
    let header = "=== Auto-Recalled Context ===" in
    let items_str = List.map (fun item ->
      let source_name = match item.source with
        | Masc_cache -> "cache"
        | Recent_broadcasts -> "broadcast"
        | File_context -> "file"
      in
      Printf.sprintf "[%s] %s" source_name item.content
    ) result.items in
    let footer =
      if result.truncated then
        Printf.sprintf "=== (truncated, ~%d tokens) ===" result.total_tokens
      else
        Printf.sprintf "=== (~%d tokens) ===" result.total_tokens
    in
    String.concat "\n" ([header] @ items_str @ [footer])

(** Format as JSON *)
let to_json (result : recall_result) : Yojson.Safe.t =
  let source_to_string = function
    | Masc_cache -> "masc_cache"
    | Recent_broadcasts -> "recent_broadcasts"
    | File_context -> "file_context"
  in
  `Assoc [
    ("items", `List (List.map (fun item ->
      `Assoc [
        ("source", `String (source_to_string item.source));
        ("content", `String item.content);
        ("relevance", `Float item.relevance);
        ("metadata", item.metadata);
      ]
    ) result.items));
    ("total_tokens", `Int result.total_tokens);
    ("truncated", `Bool result.truncated);
  ]

(** {1 Query Enhancement} *)

(** Extract potential cache keys from a query string *)
let extract_query_hints query =
  (* Simple extraction: split on whitespace, filter common words *)
  let common_words = ["the"; "a"; "an"; "is"; "are"; "was"; "were"; "be"; "to"; "of"; "and"; "in"; "for"] in
  String.split_on_char ' ' query
  |> List.filter (fun w -> String.length w > 2)
  |> List.filter (fun w -> not (List.mem (String.lowercase_ascii w) common_words))

(** Check if content matches query (simple keyword matching) *)
let content_matches_query content query =
  if query = "" then true
  else
    let hints = extract_query_hints query in
    let content_lower = String.lowercase_ascii content in
    List.exists (fun hint ->
      String.length hint >= 3 &&
      try
        let _ = Str.search_forward (Str.regexp_string (String.lowercase_ascii hint)) content_lower 0 in
        true
      with Not_found -> false
    ) hints

(** Fetch context with query-based relevance boosting *)
let fetch_context_smart
    (room_config : Room_utils.config)
    ~(config : recall_config)
    ~(query : string)
    ()
    : recall_result =
  let result = fetch_context room_config ~config ~query () in
  (* Boost relevance for items matching query *)
  let boosted_items = List.map (fun item ->
    if content_matches_query item.content query then
      { item with relevance = min 1.0 (item.relevance +. 0.3) }
    else
      item
  ) result.items in
  (* Re-sort after boosting *)
  let sorted = List.sort (fun a b -> compare b.relevance a.relevance) boosted_items in
  { result with items = sorted }
