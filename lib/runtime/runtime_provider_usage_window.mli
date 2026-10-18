(** What providers say about their own usage windows, kept for operators.

    Claude Code's [rate_limit_event] and the Codex app-server's
    [account/rateLimits/updated] report, during a turn, how much of each
    usage window the account has used and when the window resets.  The
    Codex app-server also answers [account/rateLimits/read] without a turn,
    four HTTP providers answer a usage endpoint without a model call, and
    the Antigravity CLI answers a print-mode [/usage] without a turn
    ({!Runtime_provider_usage_read}).  Muse Code pushes [usage/changed]
    during a session and answers [usage/read] ({!Runtime_muse_usage}).  This module decodes those reports at
    the wire and keeps the latest one per quota scope and window, with the
    time MASC heard it.

    It is an observation.  Routing, candidate ordering, admission and retry
    do not read this table (a usage read after an HTTP 403, or after a 429
    that states no wait, can separately rest its scope through {!Runtime_provider_usage_read.read_after_account_refusal}
    on {!Runtime_quota_window}). Codex reads preserve the refusal observation
    because the rejected bucket is not attributed: codex-cli 0.156.0's protocol schema says clients must not
    infer recovery from percentages or reset times, so no availability is
    derived from these numbers.  What the provider said is stored and shown
    as it was said.

    The table is process-local and is not persisted.  A scope with no report
    since this process started is {!Not_reported_since_start}, never an empty
    or zero window.  There is no TTL and no sweeper: a report whose
    [resets_at] has passed stays until a newer report replaces it. *)

type window_kind = Runtime_provider_usage_types.window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of int
      (** Codex stated a window length that has no name here. *)
  | Provider_label of string
      (** The provider named the window with a label that has no name here
          (a Claude [unifiedWindows] key), or Codex reported a slot
          ([primary]/[secondary]) without a length. *)

type utilization = Runtime_provider_usage_types.utilization =
  | Fraction of float  (** Claude Code: [0.67] is 67 %. Not clamped. *)
  | Percent of int  (** Codex [usedPercent]. Not clamped. *)
  | Usd of { used : float; limit : float option }
      (** USD-denominated credit use. [None] means no key cap was reported,
          so no percentage can be calculated. *)

type source = Runtime_provider_usage_types.source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read
  | Openrouter_key_read  (** OpenRouter [GET /api/v1/key]. *)
  | Zai_quota_limit_read  (** Z.AI [GET /api/monitor/usage/quota/limit]. *)
  | Kimi_coding_usages_read  (** Kimi [GET /coding/v1/usages]. *)
  | Ollama_balance_read  (** Ollama [GET https://ollama.com/api/balance]. *)
  | Antigravity_usage_read
      (** Antigravity [agy -p "/usage" --output-format json], no turn. *)
  | Muse_subscription_usage
      (** Muse Code's subscription windows, from [usage/changed] during a
          session or a [usage/read] answer ({!Runtime_muse_usage}). Both
          state the same two windows, so they are one source: a complete
          report from either replaces the other's rows. *)

(** What a window limits, set by each decoder from the provider's own
    shape, never from a label. *)
type window_role = Runtime_provider_usage_types.window_role =
  | Gates_model_calls
      (** Spending it refuses model calls on the account: Claude and Codex
          windows, OpenRouter's API key credit limit, Z.AI's TOKENS_LIMIT, both Kimi
          counts, Ollama's session and weekly allowance while its purchased
          balance is zero, Antigravity's 5-hour and weekly buckets, Muse
          Code's rolling and weekly windows. Antigravity's buckets belong to a
          model group each (Gemini; Claude and GPT), so there a spent bucket
          refuses only the calls of its own group: {!gate_coverage}. *)
  | Counts_other_use
      (** It counts something a model call does not need: Z.AI's
          TIME_LIMIT (MCP and tool calls), OpenRouter's free-model daily
          requests, uncapped credit usage totals, and Ollama's session and
          weekly allowance while its purchased balance pays for calls past
          them. *)
  | Unclassified_limit
      (** A Z.AI limit type this decoder does not know. *)

type window = Runtime_provider_usage_types.window =
  { limit_id : string option
        (** Codex [limitId]; one account reports several limits.  Claude Code
            names none. *)
  ; kind : window_kind
  ; role : window_role
  ; utilization : utilization
  ; resets_at : int option  (** Unix epoch seconds, as reported. *)
  }

type report = Runtime_provider_usage_types.report =
  { source : source
  ; windows : window list
  }

type decode_error =
  | Expected_object of { path : string }
  | Missing_field of { path : string }
  | Wrong_type of
      { path : string
      ; expected : string
      }
  | Unexpected_value of
      { path : string
      ; expected : string
      }
      (** The field has the right type and a value this decoder does not
          read, e.g. a limit of 0 or a time unit other than minutes. *)
  | Not_successful of
      { path : string
      ; message : string option
      }
      (** The response says it failed ([success] false), with its [msg]. *)
  | Duplicate_window of
      { path : string
      ; limit_id : string option
      ; kind : window_kind
      }
      (** An HTTP usage report states two windows with the same
          [(limit_id, kind)], the key {!record} keeps one row under. *)

val decode_error_to_string : decode_error -> string
val source_to_string : source -> string

val window_kind_of_minutes : int -> window_kind
(** A window length stated in minutes: exactly 300 is {!Five_hour}, exactly
    10080 is {!Seven_day}, any other length is {!Duration_minutes}. *)

val window_role_to_string : window_role -> string
(** The wire word for a role: ["gates_model_calls"], ["counts_other_use"]
    or ["unclassified_limit"]. *)

val decode_claude_rate_limit_event : Yojson.Safe.t -> (report, decode_error) result
(** A whole stream-json [rate_limit_event] message.  Windows come from
    [rate_limit_info.unifiedWindows]; an event without that member reports no
    windows.  Keys [five_hour] and [seven_day] are {!Five_hour} and
    {!Seven_day}; any other key is kept as {!Provider_label}. *)

val decode_codex_rate_limits_updated : Yojson.Safe.t -> (report, decode_error) result
(** The [params] of an [account/rateLimits/updated] notification.  A null or
    absent [primary]/[secondary] means "no value in this update" and yields no
    window, so the window already recorded stands.  [windowDurationMins] of
    exactly 300 is {!Five_hour} and exactly 10080 is {!Seven_day}; another
    length is {!Duration_minutes}; no length keeps the slot name as
    {!Provider_label}. *)

val decode_codex_rate_limits_read : Yojson.Safe.t -> (report, decode_error) result
(** The result of an [account/rateLimits/read] request, which the app-server
    answers without a thread or a turn. Every bucket of [rateLimitsByLimitId]
    is read, a bucket without its own [limitId] taking its key; when that map
    is absent or null, the single [rateLimits] is read. Windows are decoded as
    in {!decode_codex_rate_limits_updated}. *)

val decode_openrouter_key : Yojson.Safe.t -> (report, decode_error) result
(** OpenRouter [GET /api/v1/key].  A numeric [data.limit] above 0 gives one
    {!Provider_label} window "API key credit limit" with {!Usd} use
    [limit - limit_remaining] and its cap, with [limit_remaining] within
    [0..limit]. With a null [limit], a reported [usage] gives an uncapped
    "API key usage (all time)" window; absent usage gives no window. [limit_reset] is
    not read.  [data.free_model_daily_requests] gives "free model requests,
    daily" as [used / limit], with [used] within [0..limit].  Neither states
    a reset time. These windows report API key spending, not account credits
    or the account balance.

    Each HTTP decoder below refuses a report that states the same
    [(limit_id, kind)] twice ({!Duplicate_window}), and a value outside its
    stated range with {!Unexpected_value}. *)

val decode_zai_quota_limit : Yojson.Safe.t -> (report, decode_error) result
(** Z.AI [GET /api/monitor/usage/quota/limit].  [success] must be [true].
    Each [data.limits[]] row is one window with [limit_id] its [type],
    {!Percent} its [percentage] (within [0..100]) and [resets_at] its
    [nextResetTime] in seconds.  [number] must be above 0.  [unit] 3 is
    hours, so [number] hours is mapped like a Codex
    length; any other unit keeps "<number> x unit <unit>", the row's
    [type] being its [limit_id] already. *)

val decode_kimi_coding_usages : Yojson.Safe.t -> (report, decode_error) result
(** Kimi [GET /coding/v1/usages].  Each [limits[]] row is one window whose
    [window.timeUnit] must be [TIME_UNIT_MINUTE] and [window.duration]
    above 0; its length maps like a Codex length.  [detail.used] and
    [detail.limit] are decimal strings read as integers, [used] within
    [0..limit].  The top-level [usage] is one more window labelled
    "usage (provider resetTime)": it states no length, only its
    [resetTime].  [usages.*.used_ratio] is not read. *)

val decode_ollama_balance : Yojson.Safe.t -> (report, decode_error) result
(** Ollama [GET https://ollama.com/api/balance], a legacy plan's answer.
    [included] is required; [included.session] is a {!Provider_label}
    "session" window and [included.weekly] a {!Seven_day} window, each a
    {!Fraction} of [1 - remaining_percent / 100] with [remaining_percent]
    within [0..100], and [resets_at] read as RFC 3339 when present.
    [purchased.balance_usd] is required, 0 or more: above zero both windows
    are {!Counts_other_use}, because Ollama pays a call past a spent window
    from that balance; at zero they are {!Gates_model_calls}. A credit
    plan's [included.balance_usd] is refused: its calls go on against
    purchased credits, so no window alone says when a call is refused. *)

val decode_antigravity_usage : Yojson.Safe.t -> (report, decode_error) result
(** The whole JSON answer of [agy -p "/usage" --output-format json] (agy
    1.1.11 or later). [status] must be [SUCCESS]; [num_turns] must be 0, because an agy that sends "/usage" to
    the model as a prompt answers with a turn; [command.name] must be
    [usage]. Each [command.data.groups[].buckets[]] is one window: [id] is
    its [limit_id]; [window] ["5h"] is {!Five_hour} and ["weekly"]
    {!Seven_day}, any other value is refused; {!Fraction} is
    [1 - remaining_fraction], [remaining_fraction] within [0..1];
    [reset_time] (RFC 3339, optional) is [resets_at]. Every window is
    {!Gates_model_calls}: both limits refuse model calls when spent. A bucket
    with [disabled: true] does not currently apply and yields no window. *)

type recorded = Runtime_provider_usage_types.recorded =
  { window : window
  ; source : source
  ; observed_at : float
  }

type scope_state = Runtime_provider_usage_types.scope_state =
  | Not_reported_since_start
  | Reported_no_windows of { source : source; observed_at : float }
      (** A complete provider report states no applicable windows. *)
  | Reported of recorded * recorded list

val recording_since : float
(** When this process's table was created (module initialisation, i.e.
    process start).  Every {!Not_reported_since_start} means "nothing heard
    since this time". *)

type report_shape = Runtime_provider_usage_types.report_shape =
  | Complete_snapshot
  | Sparse_update
val report_shape : source -> report_shape
(** Whether absent windows revoke earlier observations from this source.
    Durable readers use the same contract as the live table. *)

val window_is_spent : window -> bool
(** The window's use reached its limit: a fraction at 1.0 or more, a
    percentage at 100 or more, USD at the key limit. A USD window with no
    limit is never spent. *)

val gates_model_calls : window -> bool
(** [true] when the window's role is {!Gates_model_calls}. *)

(** What the windows a scope holds say about calling it at a moment. *)
type scope_room =
  | No_gating_window  (** No held window gates model calls: nothing is said. *)
  | Room_left  (** The spent windows, if any, do not refuse calls. *)
  | Spent_until of float
      (** Calls are refused, every spent window states a reset still ahead,
          and the float is when the refusal ends. *)
  | Spent_without_reset
      (** Calls are refused and at least one spent window states no reset that
          can be trusted: none, or one that had already passed when the
          window was seen spent. *)

(** When a spent window refuses the scope's calls. Provider limits are either
    one pool or split by the models they cover, and the window list does not
    say which. *)
type gate_coverage =
  | One_spent_window_refuses
      (** Every gating window limits the same calls, so one spent window
          refuses all of them until it resets: the scope is refused until the
          {e last} spent window resets. *)
  | Every_window_must_be_spent
      (** The windows cover different models (Antigravity states a Gemini
          bucket and a Claude/GPT bucket), so a spent window refuses only its
          own models: the scope is refused only while {e every} gating window
          is spent, until the {e first} of them resets. *)

val gate_coverage : source -> gate_coverage option
(** [None] for a sparse source (Claude Code events, Codex): it holds only the
    windows it has stated, so a window it never stated is no evidence of room,
    and the spent buckets it reports cannot be attributed to the models a
    refused call used. Their refusals reach the quota table through the typed
    paths of {!Runtime_provider_usage_read} and the Keeper runtimes. *)

val scope_room : coverage:gate_coverage -> now:float -> recorded list -> scope_room
(** Read the windows of one complete report under [coverage]. A spent window
    whose stated reset has passed since it was seen has reset, and counts as
    having room. Windows whose role is not {!Gates_model_calls} are not read.

    [now] is the moment the answer is read against. {!record} passes the
    [observed_at] of the report it is recording, not the wall clock, so an
    older window held beside a newer report is judged at the newer report's
    time. A caller that reads a table later passes its own time. *)

val record : scope:Runtime_quota_window.scope -> observed_at:float -> report -> unit
(** HTTP and Antigravity reads are complete snapshots: windows omitted by a
    newer report from the same source are removed. Claude/Codex events and
    Codex reads allow absent windows, so they merge only stated values.
    An older or equal observation cannot replace a window or restore one
    removed by a newer complete report. Empty complete reports retain their
    observation time; empty sparse updates change nothing.

    An accepted report from a source with a {!gate_coverage} also rests the
    scope in {!Runtime_quota_window} when {!scope_room} over that source's
    windows says calls are refused: [Spent_until] as a window ending at the
    reset, [Spent_without_reset] as an observation no success has cleared.
    This is how a provider that never reports a typed refusal (Antigravity
    answers a spent quota as turn text) still orders behind its siblings once
    its usage read says the quota is gone. A report never says a scope has
    room: a window the table already holds stands until its own reset. *)

val set_record_observer :
  (scope:Runtime_quota_window.scope -> observed_at:float -> report -> unit) -> unit
(** Install the server's durable observation sink. It receives accepted
    provider reports after the in-memory table lock has been released. A sink
    failure is logged and never changes the runtime's quota reading. *)

val record_observer_failure_at : unit -> float option
(** Time of the latest observation sink failure in this process. A later
    success cannot fill that gap. Consumers compare it with the requested
    window rather than marking unrelated windows incomplete. *)

val state : scope:Runtime_quota_window.scope -> scope_state
(** The windows held for [scope], ordered by limit then kind. If complete empty
    reports from different sources share the latest timestamp, no source
    precedence is promised. *)

val recorded_scopes : unit -> Runtime_quota_window.scope list
(** Every scope that reported, including complete reports without windows,
    so a projection can show one that is no longer configured. *)
