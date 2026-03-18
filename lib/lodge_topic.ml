(** Lodge Topic Extraction — Heuristic, LLM, and Hybrid modes.

    Follows the Heuristic/Llm/Hybrid pattern from context_router.ml.
    Uses Lodge_cascade.call + Llm_response_cache for LLM extraction + caching.

    @since 4.1.0 (ROADMAP Phase 2.2.2) *)

open Printf

(** {1 Types} *)

type topic_mode =
  | Heuristic
  | Llm
  | Hybrid

(** {1 Mode Selection} *)

let get_topic_mode () =
  match Sys.getenv_opt "MASC_TOPIC_MODE" with
  | Some "heuristic" -> Heuristic
  | Some "llm" -> Llm
  | Some "hybrid" -> Hybrid
  | _ -> Hybrid

(** {1 Constants} *)

(** Maximum number of topics to return *)
let max_topics = 8

(** Maximum length of a single topic string *)
let max_topic_length = 50

(** Minimum content length to attempt LLM extraction *)
let min_content_length = 10

(** Maximum content length sent to LLM (truncated beyond this) *)
let max_prompt_content_length = 1000

(** Cache TTL for topic extraction results (seconds) *)
let cache_ttl_seconds = 3600

(** {1 Helpers} *)

(** Truncate a topic list to [max_topics] items. *)
let truncate_topics (topics : string list) : string list =
  if List.length topics > max_topics then
    List.filteri (fun i _ -> i < max_topics) topics
  else
    topics

(** Filter a Yojson list to valid topic strings.
    Keeps only non-empty strings within [max_topic_length]. *)
let filter_topic_items (items : Yojson.Safe.t list) : string list =
  List.filter_map (function
    | `String topic ->
      let t = String.trim (String.lowercase_ascii topic) in
      if String.length t > 0 && String.length t <= max_topic_length then
        Some t
      else
        None
    | _ -> None
  ) items

(** {1 Heuristic Extraction} *)

(** Compound keywords — multi-word phrases checked before single words
    to avoid partial matches (e.g. "ai" inside "ai-agent"). *)
let compound_keywords = [
  "functional-programming"; "type-system"; "error-handling";
  "web-framework"; "machine-learning"; "deep-learning";
  "natural-language"; "prompt-engineering"; "code-generation";
  "knowledge-graph"; "graph-database"; "message-queue";
  "load-balancing"; "rate-limiting"; "access-control";
  "continuous-integration"; "continuous-deployment";
]

(** Single-word tech/domain keywords — expanded from original 33 *)
let single_keywords = [
  "ocaml"; "eio"; "graphql"; "neo4j"; "rust"; "typescript"; "react";
  "python"; "golang"; "elixir"; "haskell"; "lua"; "zig";
  "agent"; "mcp"; "llm"; "ai"; "ml"; "api"; "webrtc"; "grpc";
  "postgresql"; "sqlite"; "redis"; "vector"; "supabase"; "mongodb";
  "test"; "debug"; "deploy"; "ci"; "docker"; "kubernetes"; "terraform";
  "architecture"; "design"; "pattern"; "refactor"; "migration";
  "performance"; "memory"; "concurrency"; "async"; "streaming";
  "security"; "authentication"; "encryption"; "webhook"; "embedding";
]

(** Count how many times [kw] appears in [text] (non-overlapping). *)
let count_occurrences (text : string) (kw : string) : int =
  let kw_len = String.length kw in
  let text_len = String.length text in
  if kw_len = 0 || kw_len > text_len then 0
  else
    let count = ref 0 in
    let pos = ref 0 in
    let pattern = Str.regexp_string kw in
    (try
      while !pos <= text_len - kw_len do
        let found = Str.search_forward pattern text !pos in
        incr count;
        pos := found + kw_len
      done
    with Not_found -> ());
    !count

(** Check if a compound phrase matches in text.
    Matches both "kebab-case" and "space separated" forms. *)
let match_compound (lower_text : string) (phrase : string) : bool =
  let space_form = String.concat " " (String.split_on_char '-' phrase) in
  let pat_kebab = Str.regexp_string phrase in
  let pat_space = Str.regexp_string space_form in
  (try ignore (Str.search_forward pat_kebab lower_text 0); true
   with Not_found -> false)
  ||
  (try ignore (Str.search_forward pat_space lower_text 0); true
   with Not_found -> false)

let extract_topics_heuristic (content : string) : string list =
  let lower = String.lowercase_ascii content in
  (* Phase 1: compound phrases first *)
  let compound_hits =
    List.filter (fun kw -> match_compound lower kw) compound_keywords
  in
  (* Phase 2: single keywords, scored by frequency *)
  let single_scored =
    List.filter_map (fun kw ->
      let n = count_occurrences lower kw in
      if n > 0 then Some (kw, n) else None
    ) single_keywords
  in
  (* Sort singles by frequency descending *)
  let sorted_singles =
    List.sort (fun (_, a) (_, b) -> compare b a) single_scored
    |> List.map fst
  in
  (* Merge: compounds first, then singles, deduplicated *)
  let seen = Hashtbl.create 16 in
  let add_unique acc topic =
    if Hashtbl.mem seen topic then acc
    else begin Hashtbl.replace seen topic (); topic :: acc end
  in
  let merged =
    List.fold_left add_unique [] compound_hits
    |> Fun.flip (List.fold_left add_unique) sorted_singles
    |> List.rev
  in
  if List.length merged > max_topics then
    List.filteri (fun i _ -> i < max_topics) merged
  else
    merged

(** {1 LLM Prompt} *)

let build_topic_prompt (content : string) : string =
  let truncated =
    if String.length content > max_prompt_content_length then
      String.sub content 0 max_prompt_content_length
    else
      content
  in
  sprintf {|Extract the main topics from this post. Return a JSON array of lowercase topic strings.
Rules:
- Return 1 to 8 topics
- Topics should be specific (e.g. "functional-programming" not "programming")
- Use kebab-case for multi-word topics
- Include both explicit and implied topics
- Focus on technical concepts, tools, and domains
- Return [] (empty array) if no clear topics can be extracted
- Do NOT include generic words like "code", "project", "work"

Bad examples: ["code", "stuff", "thing", "misc"]
Good examples: ["ocaml", "eio-concurrency", "graphql-schema", "neo4j"]

Post:
"%s"

Topics (JSON array only):|} truncated

(** {1 Response Parsing} *)

(** Find the outermost JSON array brackets in a string.
    Uses depth tracking to handle nested brackets like ["type[T]", "foo"]. *)
let find_array_bounds (s : string) : (int * int) option =
  let len = String.length s in
  let rec find_start i =
    if i >= len then None
    else if s.[i] = '[' then
      let rec find_end j depth =
        if j >= len then None
        else match s.[j] with
          | '[' -> find_end (j + 1) (depth + 1)
          | ']' ->
            if depth = 1 then Some (i, j)
            else find_end (j + 1) (depth - 1)
          | '"' -> skip_string (j + 1) depth
          | _ -> find_end (j + 1) depth
      and skip_string j depth =
        if j >= len then None
        else match s.[j] with
          | '\\' -> skip_string (j + 2) depth
          | '"' -> find_end (j + 1) depth
          | _ -> skip_string (j + 1) depth
      in
      find_end (i + 1) 1
    else find_start (i + 1)
  in
  find_start 0

(** Try to parse a JSON string as a topic array. *)
let try_parse_json (s : string) : string list =
  try
    match Yojson.Safe.from_string s with
    | `List items -> filter_topic_items items
    | _ -> []
  with Yojson.Json_error _ -> []

(** Try to find and parse a JSON array from text.
    Handles: clean JSON, JSON embedded in prose, nested brackets, trailing text. *)
let parse_topics_response (text : string) : string list =
  let trimmed = String.trim text in
  (* First: try parsing the entire text as JSON *)
  match try_parse_json trimmed with
  | (_ :: _) as topics -> truncate_topics topics
  | [] ->
    (* Second: use bracket-aware scan to find the array *)
    match find_array_bounds trimmed with
    | Some (start, stop) ->
      let json_str = String.sub trimmed start (stop - start + 1) in
      truncate_topics (try_parse_json json_str)
    | None -> []

(** {1 Response Validation} *)

(** Validate an LLM completion response for use as [~accept] predicate.
    Rejects empty, garbage, or non-array responses so the cascade retries
    with the next model. *)
let topics_response_is_valid (result : Llm.completion_response) : bool =
  let text = String.trim (Llm_types.text_of_response result) in
  (* Must contain at least one bracket pair *)
  if not (String.contains text '[' && String.contains text ']') then false
  else
    match parse_topics_response text with
    | _ :: _ -> true
    | [] -> false

(** {1 LLM Extraction} *)

let extract_topics_llm (content : string) : (string list, string) result =
  (* Skip very short content *)
  if String.length (String.trim content) < min_content_length then
    Ok []
  else
    let cache_key =
      Llm_response_cache.make_key ~namespace:"topic" ~content
    in
    (* Check cache first *)
    match Llm_response_cache.get_json ~key:cache_key with
    | Ok (Some cached_json) ->
      Prometheus.inc_counter "lodge_topic_cache_hits_total" ();
      let topics = match cached_json with
        | `List items ->
          List.filter_map (function
            | `String s -> Some s
            | _ -> None
          ) items
        | _ -> []
      in
      Ok topics
    | cache_result ->
      (* Log cache read errors separately from clean misses *)
      (match cache_result with
       | Error e -> eprintf "[lodge_topic] cache read error: %s\n%!" e
       | _ -> ());
      Prometheus.inc_counter "lodge_topic_cache_misses_total" ();
      (* Cache miss or error — call LLM via cascade *)
      Prometheus.inc_counter "lodge_topic_llm_calls_total" ();
      let prompt = build_topic_prompt content in
      begin match
        Lodge_cascade.call
          ~cascade_name:"topic_extraction"
          ~prompt
          ~temperature:0.1
          ~timeout_sec:5
          ~max_tokens:150
          ~accept:topics_response_is_valid
          ()
      with
      | Ok result ->
        let topics = parse_topics_response result.Lodge_cascade.response in
        (* Cache the result *)
        let json = `List (List.map (fun t -> `String t) topics) in
        (match
          Llm_response_cache.set_json
            ~key:cache_key
            ~ttl_seconds:cache_ttl_seconds
            json
        with
        | Ok () -> ()
        | Error e -> eprintf "[lodge_topic] cache write failed: %s\n%!" e);
        Ok topics
      | Error msg ->
        Error (sprintf "topic_extraction cascade failed: %s" msg)
      end

(** {1 Merge Logic} *)

(** Merge two topic lists: [primary] topics kept first, then unique
    topics from [secondary]. Deduplicates and caps at [max_topics]. *)
let merge_topics ~(primary : string list) ~(secondary : string list) : string list =
  let seen = Hashtbl.create 16 in
  let add_unique acc t =
    if Hashtbl.mem seen t then acc
    else begin Hashtbl.replace seen t (); t :: acc end
  in
  let merged =
    List.fold_left add_unique [] primary
    |> Fun.flip (List.fold_left add_unique) secondary
    |> List.rev
  in
  if List.length merged > max_topics then
    List.filteri (fun i _ -> i < max_topics) merged
  else
    merged

(** {1 Main Dispatch} *)

let extract_topics (content : string) : string list =
  match get_topic_mode () with
  | Heuristic ->
    extract_topics_heuristic content
  | Llm ->
    begin match extract_topics_llm content with
    | Ok topics when topics <> [] -> topics
    | Ok _ -> []
    | Error msg ->
      eprintf "[lodge_topic] LLM-only mode failed: %s\n%!" msg;
      []
    end
  | Hybrid ->
    let heuristic_topics = extract_topics_heuristic content in
    begin match extract_topics_llm content with
    | Ok llm_topics when llm_topics <> [] ->
      merge_topics ~primary:llm_topics ~secondary:heuristic_topics
    | Ok _ ->
      Prometheus.inc_counter "lodge_topic_heuristic_fallbacks_total" ();
      heuristic_topics
    | Error msg ->
      eprintf "[lodge_topic] LLM failed, using heuristic: %s\n%!" msg;
      Prometheus.inc_counter "lodge_topic_heuristic_fallbacks_total" ();
      heuristic_topics
    end
