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

(** {1 Heuristic Extraction} *)

(** Common tech/domain keywords — moved from lodge_reaction.ml *)
let keywords = [
  "ocaml"; "eio"; "graphql"; "neo4j"; "rust"; "typescript"; "react";
  "agent"; "mcp"; "llm"; "ai"; "ml"; "api"; "webrtc"; "grpc";
  "postgresql"; "sqlite"; "redis"; "vector";
  "test"; "debug"; "deploy"; "ci"; "docker"; "kubernetes";
  "architecture"; "design"; "pattern"; "refactor";
  "performance"; "memory"; "concurrency"; "async";
]

let extract_topics_heuristic (content : string) : string list =
  let lower = String.lowercase_ascii content in
  List.filter (fun kw ->
    let pattern = Str.regexp_string kw in
    try ignore (Str.search_forward pattern lower 0); true
    with Not_found -> false
  ) keywords

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

Post:
"%s"

Topics (JSON array only):|} truncated

(** {1 Response Parsing} *)

(** Try to find and parse a JSON array from text.
    Handles: clean JSON, JSON embedded in prose, malformed input. *)
let parse_topics_response (text : string) : string list =
  let try_parse_json s =
    try
      match Yojson.Safe.from_string s with
      | `List items ->
        List.filter_map (function
          | `String topic ->
            let t = String.trim (String.lowercase_ascii topic) in
            if String.length t > 0 && String.length t <= max_topic_length then
              Some t
            else
              None
          | _ -> None
        ) items
      | _ -> []
    with Yojson.Json_error _ -> []
  in
  (* First: try parsing the entire text as JSON *)
  let trimmed = String.trim text in
  match try_parse_json trimmed with
  | (_ :: _) as topics ->
    if List.length topics > max_topics then
      List.filteri (fun i _ -> i < max_topics) topics
    else
      topics
  | [] ->
    (* Second: try to find a JSON array within the text *)
    let result =
      try
        let start = String.index trimmed '[' in
        let stop = String.rindex trimmed ']' in
        if stop > start then
          let json_str = String.sub trimmed start (stop - start + 1) in
          try_parse_json json_str
        else
          []
      with Not_found -> []
    in
    if List.length result > max_topics then
      List.filteri (fun i _ -> i < max_topics) result
    else
      result

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
      let topics = match cached_json with
        | `List items ->
          List.filter_map (function
            | `String s -> Some s
            | _ -> None
          ) items
        | _ -> []
      in
      Ok topics
    | Ok None | Error _ ->
      (* Cache miss — call LLM via cascade *)
      let prompt = build_topic_prompt content in
      begin match
        Lodge_cascade.call
          ~cascade_name:"topic_extraction"
          ~prompt
          ~temperature:0.1
          ~timeout_sec:5
          ~max_tokens:150
          ()
      with
      | Ok result ->
        let topics = parse_topics_response result.Lodge_cascade.response in
        (* Cache the result *)
        let json = `List (List.map (fun t -> `String t) topics) in
        let _ =
          Llm_response_cache.set_json
            ~key:cache_key
            ~ttl_seconds:cache_ttl_seconds
            json
        in
        Ok topics
      | Error msg ->
        Error (sprintf "topic_extraction cascade failed: %s" msg)
      end

(** {1 Main Dispatch} *)

let extract_topics (content : string) : string list =
  match get_topic_mode () with
  | Heuristic ->
    extract_topics_heuristic content
  | Llm ->
    begin match extract_topics_llm content with
    | Ok topics when topics <> [] -> topics
    | _ -> []
    end
  | Hybrid ->
    begin match extract_topics_llm content with
    | Ok topics when topics <> [] -> topics
    | _ -> extract_topics_heuristic content
    end
