(** Keeper configuration — defaults, environment variable parsing, profiles.

    Central SSOT for keeper runtime constants, environment variable parsing,
    runtime profiles and parameter registrations.

    @since v2.128.0 *)

(** {1 Core Constants} *)

(** Default runtime name for keeper turns = the default Runtime's id.

    runtime→Runtime 숙청: 이전의 phase_recovery / phase_buffer /
    tool_action / phase_routing 구분은 모두 동일한 default Runtime 으로
    수렴하는 죽은 추상화였으므로 이 단일 thunk 로 collapse 되었다.
    @since v2.128.0 *)
val default_runtime_id : unit -> string

(** Validate one persisted/requested context override value. This is a
    structural invariant only: positive integers are accepted verbatim and no
    provider/model policy is applied here. *)
val validate_max_context_override_value : int -> (int, string) result

val default_proactive_enabled : bool

(** Maximum bytes of Keeper instructions included in the rendered prompt.
    Drives [normalize_prompt_text] when called from prompt rendering.
    NOTE: persistence layer does NOT enforce this — disk JSON may hold
    longer values; the cap applies at prompt build time. *)
val prompt_render_max_bytes : int

(** {1 Environment Variable Parsing} *)

(** Parse a boolean env var where the default is [true] when unset. *)
val bool_default_true_of_env : string -> bool

(** Parse a boolean env var with an explicit default.
    Recognizes 1/true/yes/y/on and 0/false/no/n/off. *)
val bool_of_env_default : string -> default:bool -> bool

(** Parse a boolean env var, returning [None] when unset or unrecognized. *)
val bool_of_env_opt : string -> bool option

(** Parse a raw string as a boolean.
    Recognizes 1/true/yes/y/on and 0/false/no/n/off (case-insensitive).
    Returns [None] for other values. Shared parsing logic for
    [bool_of_env_default] and [bool_of_env_opt]. *)
val bool_of_string : string -> bool option

(** Parse an integer env var with default and clamping. *)
val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int

(** Parse a float env var with default and clamping. *)
val float_of_env_default : string -> default:float -> min_v:float -> max_v:float -> float

(** {1 Name Validation} *)

(** Validate a keeper name with the shared portable-name grammar. *)
val validate_name : string -> bool

val invalid_name_error : string -> string
(** Canonical explanation for a value rejected by {!validate_name}. *)

(** {1 UTF-8 Safety} *)

(** Replace invalid UTF-8 sequences with U+FFFD. *)
val utf8_repair_string : string -> string

(** {1 Text Normalization} *)

(** Trim and truncate prompt text to [max_bytes] on a UTF-8 character
    boundary. Caller MUST pass [max_bytes] explicitly so the unit is visible. *)
val normalize_prompt_text : max_bytes:int -> string -> string

(** {1 Runtime Parameters}

    These functions return the current runtime-tunable value.
    Each parameter is registered with [Runtime_params] and can be
    adjusted via the dashboard at runtime. *)

(** Own-recent-board-posts self-awareness layer (see .ml): how many of the
    keeper's own latest posts the world observation carries per turn. *)
val keeper_hitl_thinking_blocks : unit -> int
(** Newest Keeper [thinking] blocks kept in the HITL judgment bundle.

    [0] (the default) drops them all. Raising it trades bundle size -- and so
    judgment latency -- for the self-imposed constraints a judge cites when it
    denies. See {!Hitl_summary_worker} for what was measured on each side. *)

val keeper_hitl_max_concurrent_per_keeper : unit -> int
(** Maximum concurrent Auto Judge workers admitted for one workspace/Keeper
    owner. This bounds per-Keeper fan-out; provider/runtime concurrency limits
    remain the fleet-wide backpressure authority. *)

val keeper_board_own_recent_max : unit -> int

(** Fleet-message context layer (see .ml): how many projected keeper broadcasts
    the world observation carries per turn. Cursor-independent — no watermark. *)
val keeper_fleet_messages_max : unit -> int

val keeper_context_briefing_share_percent : unit -> int
(** Share (percent) of the runtime's declared request-body cap that the
    world-state briefing may occupy. The briefing is pinned, so this is what
    stops it from crowding out the turn it briefs. *)

val keeper_own_recent_turns_max : unit -> int
(** Past turns of this keeper's own tool calls replayed into the world
    observation. Autonomous turns carried no record of what the keeper had
    already done, so it re-claimed finished tasks and repeated malformed
    calls. *)

val keeper_bootstrap_proactive_warmup_sec : unit -> int
val keeper_bootstrap_stagger_step_sec : unit -> int
val keeper_bootstrap_retry_interval_sec : unit -> int

val keeper_batch_limit : unit -> int

(** Completed board-attention partitions settled per owner turn before the
    remainder defers to a continuation wake (see
    Keeper_board_attention_worker.max_completed_settlements_per_owner_turn). *)
val keeper_board_attention_settlements_per_turn : unit -> int

val keeper_unified_temperature : unit -> float

val keeper_status_fast_default : unit -> bool

val keeper_enable_thinking : unit -> bool

(** Ceiling on tool-continuation rounds in one keeper turn. [None] leaves the
    AGENT_CORE run loop unbounded, which is what it was. Reaching the ceiling
    fails the run with [ToolRoundLimitExceeded] rather than returning a
    truncated run as a finished one. Hot-reloadable via
    [keeper.turn.max_tool_rounds]; 0 means unbounded. *)
val keeper_max_tool_rounds : unit -> int option

(** How far back through a conversation a deferred tool's most recent call may
    be and still be placed with its argument schema, counted in tool calls of
    any tool. A tool further back than this is shown by name in the listing
    again and its schema is not sent until it is asked for.

    Sampled rather than enforced continuously: the carry is measured against
    this window on a call to a tool the carry does not already hold, and not
    between two such calls, so a tool can sit further back than this and still
    be placed. [Keeper_identity_tool_search.surface] carries the reason.

    Hot-reloadable via [keeper.tool_search.carry_window]; 0 places every tool
    the conversation has run. *)
val keeper_tool_carry_window : unit -> int

(** {1 Runtime Param Handles}

    Exposed for test use only (e.g. [Runtime_params.clear]). *)

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore].  Call from server bootstrap. *)
val ensure_runtime_params_init : unit -> unit
