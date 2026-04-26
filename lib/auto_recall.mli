(** Auto-Recall Memory - Agent Being Protocol Memory System

    Automatic memory injection for MASC agents.
    Fetches relevant context from cache, broadcasts, and file context.

    {2 Example Usage}

    {[
      let config = Auto_recall.make_config
        ~max_tokens:1000
        ~sources:[Recent_broadcasts; Masc_cache; File_context]
        () in

      (* With Eio runtime context *)
      let result = Auto_recall.fetch_context_eio ~sw ~env room_config ~config ~query:"error handling" () in
      let injection = Auto_recall.format_for_injection result in
      (* Use injection as system prompt prefix *)
    ]}
*)

(** {1 Types} *)

(** Source types for context retrieval *)
type recall_source =
  | Masc_cache (** Shared context store *)
  | Recent_broadcasts (** Last N broadcasts in room *)
  | File_context (** Recently touched files from the current working tree *)

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
  ; truncated : bool (** Whether results were truncated *)
  }

(** {1 Configuration} *)

(** Default configuration with sensible defaults *)
val default_config : recall_config

(** Create configuration with optional parameters *)
val make_config
  :  ?enabled:bool
  -> ?sources:recall_source list
  -> ?max_tokens:int
  -> ?max_broadcasts:int
  -> ?cache_tags:string list
  -> unit
  -> recall_config

(** {1 Token Estimation} *)

(** Approximate token count for a string *)
val estimate_tokens : string -> int

(** {1 Core API} *)

(** Fetch context from configured sources.
    Results are sorted by relevance and truncated to token budget.

    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Optional query for relevance ranking
    @return Recall result with items and metadata
*)
val fetch_context
  :  Coord_utils.config
  -> config:recall_config
  -> ?query:string
  -> unit
  -> recall_result

(** Fetch context with Eio runtime context.
    Uses the same retrieval sources as {!fetch_context}.

    @param sw Eio switch
    @param env Eio environment with network access
    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Query string for semantic search
    @return Recall result from configured sources
*)
val fetch_context_eio
  :  sw:Eio.Switch.t
  -> env:< net : _ Eio.Net.t ; .. >
  -> clock:_ Eio.Time.clock
  -> Coord_utils.config
  -> config:recall_config
  -> ?query:string
  -> unit
  -> recall_result

(** Fetch context with query-based relevance boosting.
    Items matching the query get their relevance boosted.

    @param room_config MASC room configuration
    @param config Recall configuration
    @param query Query string for matching
    @return Recall result with boosted relevance
*)
val fetch_context_smart
  :  Coord_utils.config
  -> config:recall_config
  -> query:string
  -> unit
  -> recall_result

(** {1 Formatting} *)

(** Format recall result as grep-like injection-ready text.
    Suitable for prepending to system prompts. *)
val format_for_injection : recall_result -> string

(** Format recall result as JSON *)
val to_json : recall_result -> Yojson.Safe.t

(** {1 Query Utilities} *)

(** Extract potential search hints from a query string *)
val extract_query_hints : string -> string list

(** Check if content matches query via keyword matching *)
val content_matches_query : string -> string -> bool
