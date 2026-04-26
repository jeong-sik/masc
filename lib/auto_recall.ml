(** Auto-Recall Memory - Agent Being Protocol Memory System

    Automatic memory injection for MASC agents.
    Fetches relevant context from multiple sources and injects into prompts.

    Sources:
    - Masc_cache: Shared context store (API responses, embeddings, summaries)
    - Recent_broadcasts: Last N messages in the room
    - File_context: Recently modified files in working directory
*)

(** {1 Relevance scoring constants} *)

let cache_default_relevance = 0.5
let broadcast_relevance_cap = 0.8
let file_base_relevance = 0.4
let file_recency_weight = 0.3
let file_name_match_bonus = 0.3

(** {1 String Helpers} *)

let string_contains = Dashboard_utils.string_contains

(** {1 Types} *)

(** Source types for context retrieval *)
type recall_source =
  | Masc_cache (** Use existing masc_cache_get *)
  | Recent_broadcasts (** Last N broadcasts in room *)
  | File_context (** Recently modified source files *)

(** Configuration for auto-recall *)
type recall_config =
  { enabled : bool (** Enable/disable auto-recall *)
  ; sources : recall_source list (** Which sources to query *)
  ; max_tokens : int (** Budget per injection *)
  ; max_broadcasts : int (** Max broadcasts to fetch *)
  ; cache_tags : string list (** Filter cache by these tags *)
  }

(** A single piece of recalled context *)
type recall_item =
  { source : recall_source
  ; content : string
  ; relevance : float (** 0.0 - 1.0, higher = more relevant *)
  ; metadata : Yojson.Safe.t
  }

(** Result of a recall operation *)
type recall_result =
  { items : recall_item list
  ; total_tokens : int (** Approximate token count *)
  ; truncated : bool (** Whether results were truncated to fit budget *)
  }

(** {1 Configuration} *)

(** Default configuration *)
let default_config =
  { enabled = true
  ; sources = [ Recent_broadcasts; Masc_cache ]
  ; max_tokens = 2000
  ; max_broadcasts = 10
  ; cache_tags = []
  }
;;

(** Create config from optional parameters *)
let make_config
      ?(enabled = true)
      ?(sources = [ Recent_broadcasts; Masc_cache ])
      ?(max_tokens = 2000)
      ?(max_broadcasts = 10)
      ?(cache_tags = [])
      ()
  =
  { enabled; sources; max_tokens; max_broadcasts; cache_tags }
;;

(** {1 Token Estimation} *)

let estimate_tokens = Inference_utils.estimate_tokens

(** {1 Source Fetchers} *)

(* Issue #8597 #2: dropped [~query] — cache filtering is by tag
   (config.cache_tags), not by query string. *)

(** Fetch from MASC cache *)
let fetch_from_cache (room_config : Coord_utils.config) ~(config : recall_config) =
  let entries =
    match config.cache_tags with
    | [] -> Cache_eio.list room_config ()
    | tags ->
      (* Fetch entries matching any of the specified tags *)
      List.concat_map (fun tag -> Cache_eio.list room_config ~tag ()) tags
      |> List.sort_uniq (fun a b -> compare a.Cache_eio.key b.Cache_eio.key)
  in
  List.map
    (fun (entry : Cache_eio.cache_entry) ->
       { source = Masc_cache
       ; content = entry.value
       ; relevance = cache_default_relevance
       ; metadata =
           `Assoc
             [ "key", `String entry.key
             ; "tags", `List (List.map (fun t -> `String t) entry.tags)
             ; "created_at", `Float entry.created_at
             ]
       })
    entries
;;

(* Issue #8597 #2: dropped [~query] — broadcast fetch is limit-based
   (config.max_broadcasts), not query-ranked. *)
(** Fetch recent broadcasts *)
let fetch_from_broadcasts (room_config : Coord_utils.config) ~(config : recall_config) =
  let messages =
    Coord.get_messages_raw room_config ~since_seq:0 ~limit:config.max_broadcasts
  in
  List.mapi
    (fun i (msg : Types.message) ->
       (* More recent messages get higher relevance *)
       let relevance =
         1.0 -. (float_of_int i /. float_of_int (max 1 (List.length messages)))
       in
       { source = Recent_broadcasts
       ; content = Printf.sprintf "[%s] %s" msg.from_agent msg.content
       ; relevance = relevance *. broadcast_relevance_cap
       ; metadata =
           `Assoc
             [ "seq", `Int msg.seq
             ; "from", `String msg.from_agent
             ; "timestamp", `String msg.timestamp
             ; "mention", Json_util.string_opt_to_json msg.mention
             ]
       })
    messages
;;

(* Issue #8597 #2: dropped [~config]. recall_config has no field that
   maps to file scanning (max_files=10 / max_preview_bytes=500 are
   hard-coded; cache_tags / max_broadcasts / max_tokens belong to other
   sources). The arg was structurally received, semantically ignored. *)
(** Fetch recently modified files from working directory *)
let fetch_from_file_context (room_config : Coord_utils.config) ~query =
  let masc_dir = Coord_utils.masc_dir room_config in
  let work_dir = Filename.dirname masc_dir in
  (* Parent of .masc *)
  (* Get recently modified files without shelling out (no find/xargs). *)
  let max_files = 10 in
  let max_preview_bytes = 500 in
  let is_allowed_file path =
    Filename.check_suffix path ".ml"
    || Filename.check_suffix path ".mli"
    || Filename.check_suffix path ".py"
    || Filename.check_suffix path ".ts"
    || Filename.check_suffix path ".js"
    || Filename.check_suffix path ".md"
  in
  let should_skip_dir name =
    name = ".git"
    || name = "node_modules"
    || name = "_build"
    || name = ".worktrees"
    || name = Common.masc_dirname
  in
  let rec walk depth dir acc =
    if depth > 3
    then acc
    else (
      match Safe_ops.list_dir_safe dir with
      | Error _ -> acc
      | Ok names ->
        List.fold_left
          (fun acc name ->
             if should_skip_dir name
             then acc
             else (
               let path = Filename.concat dir name in
               try
                 if Sys.is_directory path
                 then walk (depth + 1) path acc
                 else if is_allowed_file path
                 then path :: acc
                 else acc
               with
               | Sys_error _ -> acc))
          acc
          names)
  in
  let files =
    walk 0 work_dir []
    |> List.filter_map (fun path ->
      try
        let st = Unix.stat path in
        Some (st.Unix.st_mtime, path)
      with
      | Unix.Unix_error _ -> None)
    |> List.sort (fun (a_m, _) (b_m, _) -> compare b_m a_m)
    |> List.filteri (fun i _ -> i < max_files)
    |> List.map snd
  in
  (* Read preview of each file *)
  let read_preview path =
    try
      let content = Fs_compat.load_file path in
      let len = String.length content in
      if len > max_preview_bytes
      then String.sub content 0 max_preview_bytes ^ "\n... [truncated]"
      else content
    with
    | Sys_error _ -> ""
  in
  (* Calculate relevance based on query match and recency *)
  let query_lower = String.lowercase_ascii query in
  let calc_relevance path content i =
    let name_lower = String.lowercase_ascii (Filename.basename path) in
    let content_lower = String.lowercase_ascii content in
    let name_match =
      if
        query <> ""
        && String.length query > 2
        && (string_contains ~needle:query_lower name_lower
            || string_contains ~needle:query_lower content_lower)
      then file_name_match_bonus
      else 0.0
    in
    let recency = 1.0 -. (float_of_int i /. float_of_int (max 1 (List.length files))) in
    min 1.0 (file_base_relevance +. (recency *. file_recency_weight) +. name_match)
  in
  List.filter_map
    (fun path ->
       if String.length path = 0
       then None
       else (
         let preview = read_preview path in
         if String.length preview = 0 then None else Some path))
    files
  |> List.mapi (fun i path ->
    let preview = read_preview path in
    let rel_path =
      if String.starts_with ~prefix:work_dir path
      then
        String.sub
          path
          (String.length work_dir + 1)
          (String.length path - String.length work_dir - 1)
      else path
    in
    { source = File_context
    ; content = Printf.sprintf "=== %s ===\n%s" rel_path preview
    ; relevance = calc_relevance path preview i
    ; metadata =
        `Assoc
          [ "path", `String rel_path
          ; "full_path", `String path
          ; "preview_bytes", `Int (String.length preview)
          ]
    })
  |> List.filter (fun item -> String.length item.content > 10)
;;

(** Fetch from a single source (sync, no Eio).

    Each leaf consumes only the args it needs (#8597 #2):
    - [Masc_cache] / [Recent_broadcasts] use [config] (tags / limit)
    - [File_context] uses [query] for relevance ranking *)
let fetch_source room_config ~config ~query = function
  | Masc_cache -> fetch_from_cache room_config ~config
  | Recent_broadcasts -> fetch_from_broadcasts room_config ~config
  | File_context -> fetch_from_file_context room_config ~query
;;

(** {1 Main API} *)

(** Fetch context from configured sources

    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Optional query string for relevance ranking

    @return Recall result with items sorted by relevance, truncated to token budget
*)
let fetch_context
      (room_config : Coord_utils.config)
      ~(config : recall_config)
      ?(query : string = "")
      ()
  : recall_result
  =
  if not config.enabled
  then { items = []; total_tokens = 0; truncated = false }
  else (
    (* Fetch from all configured sources *)
    let all_items =
      List.concat_map (fetch_source room_config ~config ~query) config.sources
    in
    (* Sort by relevance (highest first) *)
    let sorted = List.sort (fun a b -> compare b.relevance a.relevance) all_items in
    (* Truncate to token budget *)
    let rec take_within_budget acc tokens = function
      | [] -> List.rev acc, tokens, false
      | item :: rest ->
        let item_tokens = estimate_tokens item.content in
        if tokens + item_tokens > config.max_tokens
        then List.rev acc, tokens, true (* Truncated *)
        else take_within_budget (item :: acc) (tokens + item_tokens) rest
    in
    let items, total_tokens, truncated = take_within_budget [] 0 sorted in
    { items; total_tokens; truncated })
;;

(** Fetch context with Eio runtime context

    @param sw Eio switch
    @param env Eio environment with network access
    @param clock Eio clock
    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Query string for relevance

    @return Recall result from configured sources
*)
let fetch_context_eio
      ~sw:_
      ~env:_
      ~clock:_
      (room_config : Coord_utils.config)
      ~(config : recall_config)
      ?(query : string = "")
      ()
  : recall_result
  =
  fetch_context room_config ~config ~query ()
;;

(** {1 Formatting} *)

(** Format recall result as grep-like injection-ready text *)
let metadata_string_opt (metadata : Yojson.Safe.t) key =
  match metadata with
  | `Assoc _ ->
    metadata |> Yojson.Safe.Util.member key |> Yojson.Safe.Util.to_string_option
  | _ -> None
;;

let metadata_int_opt (metadata : Yojson.Safe.t) key =
  match metadata with
  | `Assoc _ -> metadata |> Yojson.Safe.Util.member key |> Yojson.Safe.Util.to_int_option
  | _ -> None
;;

let grep_like_line_of_item (item : recall_item) =
  let source, location =
    match item.source with
    | Masc_cache ->
      let key =
        metadata_string_opt item.metadata "key" |> Option.value ~default:"entry"
      in
      "cache", key
    | Recent_broadcasts ->
      let from_agent =
        metadata_string_opt item.metadata "from" |> Option.value ~default:"agent"
      in
      let seq =
        metadata_int_opt item.metadata "seq"
        |> Option.map string_of_int
        |> Option.value ~default:"latest"
      in
      "broadcast", Printf.sprintf "%s#%s" from_agent seq
    | File_context ->
      let path =
        metadata_string_opt item.metadata "path" |> Option.value ~default:"recent-file"
      in
      "file", path
  in
  Retrieval_projection.grep_like_line ~source ~location ~content:item.content
;;

let format_for_injection (result : recall_result) : string =
  if result.items = []
  then ""
  else (
    let header = "=== Auto-Recalled Context ===" in
    let items_str = List.map grep_like_line_of_item result.items in
    let footer =
      if result.truncated
      then Printf.sprintf "=== (truncated, ~%d tokens) ===" result.total_tokens
      else Printf.sprintf "=== (~%d tokens) ===" result.total_tokens
    in
    String.concat "\n" ([ header ] @ items_str @ [ footer ]))
;;

(** Format as JSON *)
let to_json (result : recall_result) : Yojson.Safe.t =
  let source_to_string = function
    | Masc_cache -> "masc_cache"
    | Recent_broadcasts -> "recent_broadcasts"
    | File_context -> "file_context"
  in
  `Assoc
    [ ( "items"
      , `List
          (List.map
             (fun item ->
                `Assoc
                  [ "source", `String (source_to_string item.source)
                  ; "content", `String item.content
                  ; "relevance", `Float item.relevance
                  ; "metadata", item.metadata
                  ])
             result.items) )
    ; "total_tokens", `Int result.total_tokens
    ; "truncated", `Bool result.truncated
    ]
;;

(** {1 Query Enhancement} *)

(** Extract potential cache keys from a query string *)
let extract_query_hints query =
  (* Simple extraction: split on whitespace, filter common words *)
  let common_words =
    [ "the"; "a"; "an"; "is"; "are"; "was"; "were"; "be"; "to"; "of"; "and"; "in"; "for" ]
  in
  String.split_on_char ' ' query
  |> List.filter (fun w -> String.length w > 2)
  |> List.filter (fun w -> not (List.mem (String.lowercase_ascii w) common_words))
;;

(* Byte-wise substring search (haystack already lowered, needle lowered
   inline).  Replaces a per-hint [Re.compile] that ran inside a
   [List.exists]: with K hints and N items in [fetch_context_smart],
   the old form built K × N regex DFAs even though each pattern was a
   plain literal. *)
let contains_lowered_substring ~haystack_lower needle =
  let nlen = String.length needle in
  let hlen = String.length haystack_lower in
  if nlen = 0
  then true
  else if nlen > hlen
  then false
  else (
    let rec match_at i j =
      if j = nlen
      then true
      else (
        let h = String.unsafe_get haystack_lower (i + j) in
        let n = Char.lowercase_ascii (String.unsafe_get needle j) in
        if h <> n then false else match_at i (j + 1))
    in
    let last = hlen - nlen in
    let rec loop i =
      if i > last then false else if match_at i 0 then true else loop (i + 1)
    in
    loop 0)
;;

(** Check if content matches query (simple keyword matching) *)
let content_matches_query content query =
  if query = ""
  then true
  else (
    let hints = extract_query_hints query in
    let content_lower = String.lowercase_ascii content in
    List.exists
      (fun hint ->
         String.length hint >= 3
         && contains_lowered_substring ~haystack_lower:content_lower hint)
      hints)
;;

(** Fetch context with query-based relevance boosting *)
let fetch_context_smart
      (room_config : Coord_utils.config)
      ~(config : recall_config)
      ~(query : string)
      ()
  : recall_result
  =
  let result = fetch_context room_config ~config ~query () in
  (* Boost relevance for items matching query *)
  let boosted_items =
    List.map
      (fun item ->
         if content_matches_query item.content query
         then { item with relevance = min 1.0 (item.relevance +. 0.3) }
         else item)
      result.items
  in
  (* Re-sort after boosting *)
  let sorted = List.sort (fun a b -> compare b.relevance a.relevance) boosted_items in
  { result with items = sorted }
;;
