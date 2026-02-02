(** Auto-Recall Memory - Agent Being Protocol Memory System

    Automatic memory injection for MASC agents.
    Fetches relevant context from multiple sources and injects into prompts.

    Sources:
    - Masc_cache: Shared context store (API responses, embeddings, summaries)
    - Recent_broadcasts: Last N messages in the room
    - Qdrant_semantic: Vector similarity search for episodic memories
    - File_context: Recently modified files in working directory
*)

(** {1 String Helpers} *)

(** Check if haystack contains needle *)
let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len > haystack_len then false
  else
    let rec check i =
      if i > haystack_len - needle_len then false
      else if String.sub haystack i needle_len = needle then true
      else check (i + 1)
    in
    check 0

(** Check if str starts with prefix *)
let string_starts_with ~prefix str =
  let prefix_len = String.length prefix in
  String.length str >= prefix_len && String.sub str 0 prefix_len = prefix

(** {1 Types} *)

(** Source types for context retrieval *)
type recall_source =
  | Masc_cache        (** Use existing masc_cache_get *)
  | Recent_broadcasts (** Last N broadcasts in room *)
  | Qdrant_semantic   (** Vector similarity search - Agent Being Protocol *)
  | File_context      (** Recently modified source files *)

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

(** Fetch recently modified files from working directory *)
let fetch_from_file_context (room_config : Room_utils.config) ~(config : recall_config) ~query =
  let _ = config in  (* suppress unused warning *)
  let masc_dir = Room_utils.masc_dir room_config in
  let work_dir = Filename.dirname masc_dir in (* Parent of .masc *)
  
  (* Get recently modified files using find *)
  let max_files = 10 in
  let max_preview_bytes = 500 in
  
  let cmd = Printf.sprintf 
    "find %s -maxdepth 3 -type f -name '*.ml' -o -name '*.mli' -o -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.md' 2>/dev/null | head -50 | xargs ls -t 2>/dev/null | head -%d"
    (Filename.quote work_dir) max_files
  in
  
  let files = 
    try
      let ic = Unix.open_process_in cmd in
      let rec read_lines acc =
        try
          let line = input_line ic in
          read_lines (String.trim line :: acc)
        with End_of_file -> 
          ignore (Unix.close_process_in ic);
          List.rev acc
      in
      read_lines []
    with Unix.Unix_error _ | Sys_error _ -> []
  in
  
  (* Read preview of each file *)
  let read_preview path =
    try
      let ic = open_in path in
      let len = min max_preview_bytes (in_channel_length ic) in
      let content = really_input_string ic len in
      close_in ic;
      let truncated = in_channel_length ic > max_preview_bytes in
      if truncated then content ^ "\n... [truncated]" else content
    with Sys_error _ -> ""
  in
  
  (* Calculate relevance based on query match and recency *)
  let query_lower = String.lowercase_ascii query in
  let calc_relevance path content i =
    let name_lower = String.lowercase_ascii (Filename.basename path) in
    let content_lower = String.lowercase_ascii content in
    let name_match = if query <> "" && String.length query > 2 && 
                        (string_contains ~needle:query_lower name_lower ||
                         string_contains ~needle:query_lower content_lower) 
                     then 0.3 else 0.0 in
    let recency = 1.0 -. (float_of_int i /. float_of_int (max 1 (List.length files))) in
    min 1.0 (0.4 +. (recency *. 0.3) +. name_match)
  in
  
  List.filter_map (fun path ->
    if String.length path = 0 then None
    else
      let preview = read_preview path in
      if String.length preview = 0 then None
      else Some path
  ) files
  |> List.mapi (fun i path ->
    let preview = read_preview path in
    let rel_path = 
      if string_starts_with ~prefix:work_dir path 
      then String.sub path (String.length work_dir + 1) (String.length path - String.length work_dir - 1)
      else path
    in
    {
      source = File_context;
      content = Printf.sprintf "=== %s ===\n%s" rel_path preview;
      relevance = calc_relevance path preview i;
      metadata = `Assoc [
        ("path", `String rel_path);
        ("full_path", `String path);
        ("preview_bytes", `Int (String.length preview));
      ];
    }
  )
  |> List.filter (fun item -> String.length item.content > 10)

(** {1 Qdrant Semantic Search - Agent Being Protocol} *)

(** Get Qdrant URL from environment *)
let get_qdrant_url () =
  Sys.getenv_opt "QDRANT_URL"

(** Qdrant search request body *)
let qdrant_search_body ~collection:_ ~vector ~limit =
  Yojson.Safe.to_string (`Assoc [
    ("vector", `List (List.map (fun f -> `Float f) vector));
    ("limit", `Int limit);
    ("with_payload", `Bool true);
  ])

(** Get RunPod BGE-M3 embedding endpoint *)
let get_runpod_config () =
  match Sys.getenv_opt "RUNPOD_ENDPOINT_ID", Sys.getenv_opt "RUNPOD_API_TOKEN" with
  | Some endpoint_id, Some token ->
    Some (Printf.sprintf "https://api.runpod.ai/v2/%s/runsync" endpoint_id, token)
  | _ -> None

(** Fallback: hash-based pseudo-embedding when RunPod unavailable *)
let fallback_embedding (text : string) : float list =
  let hash = Hashtbl.hash text in
  let dim = 1024 in  (* BGE-M3 dimension *)
  List.init dim (fun i ->
    let v = float_of_int ((hash lxor (i * 31)) mod 1000) /. 1000.0 in
    v -. 0.5
  )

(** Get embedding from BGE-M3 via RunPod Serverless (Eio) *)
let get_embedding_eio ~sw ~env (text : string) : float list =
  match get_runpod_config () with
  | None ->
    Printf.eprintf "[EMBED] RunPod not configured, using fallback\n%!";
    fallback_embedding text
  | Some (url, token) ->
    let body = Yojson.Safe.to_string (`Assoc [
      ("input", `Assoc [
        ("texts", `List [`String text])
      ])
    ]) in
    try
      let client = Cohttp_eio.Client.make ~https:None env#net in
      let uri = Uri.of_string url in
      let headers = Cohttp.Header.of_list [
        ("Content-Type", "application/json");
        ("Authorization", Printf.sprintf "Bearer %s" token)
      ] in
      let body_content = Eio.Flow.string_source body in
      let resp, resp_body = Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content in
      let status = Cohttp.Response.status resp in
      if not (Cohttp.Code.is_success (Cohttp.Code.code_of_status status)) then (
        Printf.eprintf "[EMBED] RunPod error: %s, using fallback\n%!"
          (Cohttp.Code.string_of_status status);
        fallback_embedding text
      ) else
        let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_int in
        let json = Yojson.Safe.from_string body_str in
        let open Yojson.Safe.Util in
        (* RunPod response: { "output": { "embeddings": [[...]] } } *)
        let embeddings = json |> member "output" |> member "embeddings" |> to_list in
        match embeddings with
        | first :: _ ->
          first |> to_list |> List.map to_float
        | [] ->
          Printf.eprintf "[EMBED] Empty embeddings, using fallback\n%!";
          fallback_embedding text
    with exn ->
      Printf.eprintf "[EMBED] Exception: %s, using fallback\n%!" (Printexc.to_string exn);
      fallback_embedding text

(** Synchronous embedding (fallback only, for non-Eio contexts) *)
let _simple_text_embedding (text : string) : float list =
  fallback_embedding text

(** Fetch from Qdrant (Eio-aware) - Agent Being Protocol
    Includes timeout protection to prevent indefinite blocking *)
let fetch_from_qdrant_eio ~sw ~env ~clock ~config:(_ : recall_config) ~query =
  match get_qdrant_url () with
  | None -> []  (* Silently skip if Qdrant not configured *)
  | Some qdrant_url ->
    if query = "" then []  (* Need query for semantic search *)
    else
      let collection = "retrospectives" in  (* Default collection for episodes *)
      let timeout_sec = Env_config.Qdrant.timeout_seconds in
      try
        Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
          let vector = get_embedding_eio ~sw ~env query in
          let limit = 5 in
          let url = Printf.sprintf "%s/collections/%s/points/search" qdrant_url collection in
          let body = qdrant_search_body ~collection ~vector ~limit in
          let client = Cohttp_eio.Client.make ~https:None env#net in
          let uri = Uri.of_string url in
          let body_content = Eio.Flow.string_source body in
          let headers = Cohttp.Header.of_list [("Content-Type", "application/json")] in
          let resp, resp_body = Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content in
          let status = Cohttp.Response.status resp in
          if not (Cohttp.Code.is_success (Cohttp.Code.code_of_status status)) then []
          else
            let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_int in
            let json = Yojson.Safe.from_string body_str in
            let open Yojson.Safe.Util in
            let results = json |> member "result" |> to_list in
            List.mapi (fun i result ->
              let score = result |> member "score" |> to_float in
              let payload = result |> member "payload" in
              let content = payload |> member "content" |> to_string_option |> Option.value ~default:"" in
              let title = payload |> member "title" |> to_string_option |> Option.value ~default:"" in
              let display = if title <> "" then Printf.sprintf "[%s] %s" title content else content in
              {
                source = Qdrant_semantic;
                content = display;
                relevance = score *. 0.9;  (* Scale Qdrant score *)
                metadata = `Assoc [
                  ("rank", `Int i);
                  ("score", `Float score);
                  ("payload", payload);
                ];
              }
            ) results
        )
      with
      | Eio.Time.Timeout ->
        Printf.eprintf "[Qdrant] Timeout after %.0fs\n%!" timeout_sec; []
      | _ -> []  (* Silently fail if Qdrant unavailable *)

(** Fetch from a single source (sync, no Eio) *)
let fetch_source room_config ~config ~query = function
  | Masc_cache -> fetch_from_cache room_config ~config ~query
  | Recent_broadcasts -> fetch_from_broadcasts room_config ~config ~query
  | Qdrant_semantic -> []  (* Requires Eio - use fetch_from_qdrant_eio separately *)
  | File_context -> fetch_from_file_context room_config ~config ~query

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

(** Fetch context with Eio support for Qdrant semantic search

    @param sw Eio switch
    @param env Eio environment with network access
    @param clock Eio clock for timeout support
    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Query string for semantic search

    @return Recall result including Qdrant results
*)
let fetch_context_eio
    ~sw ~env ~clock
    (room_config : Room_utils.config)
    ~(config : recall_config)
    ?(query : string = "")
    ()
    : recall_result =
  if not config.enabled then
    { items = []; total_tokens = 0; truncated = false }
  else
    (* Fetch from sync sources *)
    let sync_items = List.concat_map (fetch_source room_config ~config ~query) config.sources in

    (* Fetch from Qdrant if configured *)
    let qdrant_items =
      if List.mem Qdrant_semantic config.sources && query <> "" then
        fetch_from_qdrant_eio ~sw ~env ~clock ~config ~query
      else []
    in

    let all_items = sync_items @ qdrant_items in

    (* Sort by relevance (highest first) *)
    let sorted = List.sort (fun a b -> compare b.relevance a.relevance) all_items in

    (* Truncate to token budget *)
    let rec take_within_budget acc tokens = function
      | [] -> (List.rev acc, tokens, false)
      | item :: rest ->
          let item_tokens = estimate_tokens item.content in
          if tokens + item_tokens > config.max_tokens then
            (List.rev acc, tokens, true)
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
        | Qdrant_semantic -> "memory"
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
    | Qdrant_semantic -> "qdrant_semantic"
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
