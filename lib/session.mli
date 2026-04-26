(** Session -- Agent session registry with rate limiting.

    Tracks connected agents, enforces per-category rate limits,
    manages notification queues, and provides MCP session-id
    lifecycle (create, get, cleanup). *)

open Types
module AgentMap : Map.S with type key = String.t

(** {1 Session Types} *)

(** Session info stored in the registry. *)
type session =
  { agent_name : string
  ; connected_at : float
  ; last_activity : float
  ; is_listening : bool
  ; message_queue : Yojson.Safe.t Eio.Stream.t
  }

(** Rate-limit tracking per category. *)
type rate_tracker =
  { general_timestamps : float list
  ; broadcast_timestamps : float list
  ; task_ops_timestamps : float list
  ; burst_used : int
  ; last_burst_reset : float
  }

(** Session registry managing all connected agents. *)
type registry

(** {1 Registry Lifecycle} *)

(** Create a new session registry with optional rate-limit config. *)
val create : ?config:rate_limit_config -> unit -> registry

(** Start the Actor state loop for the registry. *)
val start_loop : registry -> sw:Eio.Switch.t -> unit

(** {1 Agent Sessions} *)

(** Register a new agent session (or replace if name exists). *)
val register : registry -> agent_name:string -> session

(** Unregister an agent session. *)
val unregister : registry -> agent_name:string -> unit

(** Update the activity timestamp and optionally the listening flag. *)
val update_activity : registry -> agent_name:string -> ?is_listening:bool -> unit -> unit

(** Get session *)
val get_session : registry -> agent_name:string -> session option

(** Get all sessions *)
val get_sessions : registry -> session AgentMap.t

(** {1 Rate Limiting} *)

(** Create an empty rate tracker. *)
val create_tracker : float -> rate_tracker

(** Get timestamps for a given rate-limit category. *)
val get_timestamps : rate_tracker -> rate_limit_category -> float list

(** Set timestamps for a given rate-limit category. *)
val set_timestamps : rate_tracker -> rate_limit_category -> float list -> rate_tracker

(** Check rate limit for an agent (simple, uses GeneralLimit + Worker). *)
val check_rate_limit : registry -> agent_name:string -> bool * int

(** Check rate limit with explicit category and role.
    Returns [(allowed, wait_seconds)]. *)
val check_rate_limit_ex
  :  registry
  -> agent_name:string
  -> category:rate_limit_category
  -> role:agent_role
  -> bool * int

(** Return rate-limit status as JSON for an agent. *)
val get_rate_limit_status
  :  registry
  -> agent_name:string
  -> role:agent_role
  -> Yojson.Safe.t

(** {1 Message Queue} *)

(** Max notification queue size per session. *)
val max_notification_queue : int

(** Push a broadcast/direct message to matching session queues.
    Returns the list of target agent names that received the message. *)
val push_message
  :  registry
  -> from_agent:string
  -> content:string
  -> mention:string option
  -> string list

(** Push a system notification to all active sessions.
    Does not exclude the sender and has no mention filter. *)
val push_notification_to_active_agents : registry -> event:Yojson.Safe.t -> int

(** Pop the next message from an agent's queue, if any. *)
val pop_message : registry -> agent_name:string -> Yojson.Safe.t option

(** Block until a message arrives or [timeout] seconds elapse. *)
val wait_for_message
  :  registry
  -> agent_name:string
  -> timeout:float
  -> Yojson.Safe.t option

(** {1 Status & Diagnostics} *)

(** Return names of agents idle longer than [threshold] seconds. *)
val get_inactive_agents : registry -> threshold:float -> string list

(** Return all agent statuses as JSON objects. *)
val get_agent_statuses : registry -> Yojson.Safe.t list

(** Formatted multi-line status string for display. *)
val status_string : registry -> string

(** List of currently connected agent names. *)
val connected_agents : registry -> string list

(** Restore sessions from on-disk agent files (call at startup). *)
val restore_from_disk : registry -> agents_path:string -> unit

(** {1 MCP Session Store} *)

(** MCP session-id management (separate from agent sessions). *)
module McpSessionStore : sig
  (** An MCP session record. *)
  type mcp_session =
    { id : string
    ; created_at : float
    ; last_activity : float
    ; agent_name : string option
    ; metadata : (string * string) list
    ; request_count : int
    }

  (** Start the Actor state loop for the store. *)
  val start_loop : sw:Eio.Switch.t -> unit

  (** Generate a cryptographically random MCP session ID. *)
  val generate_id : unit -> string

  (** Create and store a new MCP session. *)
  val create : ?agent_name:string -> unit -> mcp_session

  (** Look up an MCP session by ID (updates activity). *)
  val get : string -> mcp_session option

  (** Remove stale sessions exceeding max age.
      Returns the number removed. *)
  val cleanup_stale : unit -> int

  (** Serialize an MCP session to JSON. *)
  val to_json : mcp_session -> Yojson.Safe.t

  (** List all active MCP sessions. *)
  val list_all : unit -> mcp_session list

  (** Remove an MCP session by ID.  Returns [true] if found. *)
  val remove : string -> bool
end

(** Start a background fiber that periodically cleans up stale
    MCP sessions.  Call once at server startup. *)
val start_mcp_session_cleanup_loop
  :  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?interval:float
  -> unit
  -> unit

(** {1 MCP Session Helpers} *)

(** Extract MCP session ID from HTTP headers.
    Prefers canonical [Mcp-Session-Id], falls back to legacy
    [X-MCP-Session-ID]. *)
val extract_mcp_session_id : Cohttp.Header.t -> string option

(** Retrieve or create an MCP session from request headers. *)
val get_or_create_mcp_session : Cohttp.Header.t -> McpSessionStore.mcp_session

(** Add [Mcp-Session-Id] to response headers. *)
val add_mcp_session_header
  :  Cohttp.Header.t
  -> McpSessionStore.mcp_session
  -> Cohttp.Header.t

(** Handle the [mcp_session] tool (get/create/list/cleanup/remove). *)
val handle_mcp_session_tool : Yojson.Safe.t -> bool * string
