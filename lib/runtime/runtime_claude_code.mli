(** A single-turn client for the official Claude Code CLI.

    This is not an Anthropic HTTP provider and it does not read API keys.
    Claude Code owns the subscription session and model loop. MASC owns the
    child lifetime, exact SDK-control/MCP bridge, and terminal projection. *)

type subscription = private
  { auth_method : string
  ; subscription_type : string
  ; api_provider : string
  }

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; system_prompt : string option
  ; admission_timeout_s : float
    (** Finite bound for the post-spawn initialize exchange and callbacks
        before the user turn is written. *)
  ; native : Runtime_native_tools.posture
    (** How much of the CLI's built-in tool surface this turn may use
        (RFC-0390). Built-in calls run inside the client and never reach the
        MASC approval gate, so the keeper layer admits [Native_full] only
        for Yolo keepers. *)
  ; setting_sources : Runtime_native_tools.claude_setting_source list
    (** Which settings layers the CLI may load ([--setting-sources]). Empty —
        the default — keeps the historical no-layer stance; a loaded layer
        can carry skills and hooks that execute outside the MASC gate, so the
        keeper layer admits a non-empty list only for Yolo keepers. *)
  ; timeout_s : float option
    (** [None] removes the deadline after the user message is written: the
        spawned client decides when its own turn ends. Initialization remains
        bounded by [admission_timeout_s]. Declared as [turn-timeout-s] in
        runtime config, where [0] selects [None]. *)
    (** Maximum silence between CLI stream messages. Each received message
        resets the deadline; a progressing turn is bounded only by
        [wall_clock_ceiling_s]. *)
  ; wall_clock_ceiling_s : float option
    (** Whole-turn wall-clock ceiling measured from spawn ([None] selects the
        shared hours-scale default). The idle timeout above resets on every
        received message, so this is the only bound a turn of continuous
        thin progress cannot outlive (#31242). *)
  ; output_schema : Yojson.Safe.t option
    (** JSON Schema the CLI enforces on the turn's final answer
        ([--json-schema]). The mechanism is validation with a re-prompt, not
        constrained decoding: the client checks its own answer and tries again,
        and gives up with subtype [error_max_structured_output_retries].
        [None] leaves the answer unfenced, which is what every caller did
        before this field existed. *)
  }

val default_timeout_s : float
val default_config : cwd:string -> config

(** One image attached to a turn's user message. [base64_data] is the raw
    base64 payload with no data-URL prefix and no newlines, the shape the
    stream-json image block takes. *)
type image_input =
  { media_type : string
  ; base64_data : string
  }

type session_mode =
  | Start
  | Resume of { session_id : string }

type rate_limit_status =
  | Allowed
  | Allowed_warning
  | Rejected

type rate_limit =
  { status : rate_limit_status
  ; rate_limit_type : string option
  ; resets_at : int option
  ; overage_status : string option
  ; overage_disabled_reason : string option
  }

(** Usage counts read from a CLI frame: the result frame carries the turn
    total, and each assistant frame carries the usage of the API call that
    produced it (summed, deduplicated by message id, when a host stop ends
    the turn before the result frame). The CLI mirrors Anthropic
    Messages semantics: [input_tokens] is the exclusive wire count (tokens
    after the last cache breakpoint); absent cache fields read as 0. The
    keeper mapping builds the canonical inclusive
    {!Agent_core.Types.api_usage} from these via
    [Backend_anthropic.usage_of_wire_counts]. *)
type turn_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  }

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; rate_limit : rate_limit option
  ; resumed : bool
  ; usage : turn_usage option
  }

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | External_effect_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop = Runtime_official_client_tool.host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type stream_event =
  | Turn_started of
      { turn_id : string
      ; model : string
      }
  | Text_delta of string
  | Dynamic_tool_started of
      { call_id : string
      ; tool_name : string
      ; arguments : Yojson.Safe.t
      }
  | Dynamic_tool_finished of { call_id : string }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Turn_finished of { text : string }

val dynamic_tool_bytes : dynamic_tool list -> int
(** Bytes the tool declarations occupy in the request this process builds. Not
    provider tokens: it bounds the request, it does not price it. *)

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Subscription_required of string
  | Unsupported_control_request of string
  | Turn_transport_interrupted of
      { stage : string
      ; tool_effect_attempted : bool
      ; detail : string
      }
  | Context_window_exceeded of
      { message : string
      ; tool_effect_attempted : bool
      ; response_emitted : bool
      }
  | Turn_failed of string
  | Turn_failed_with_observation of
      { detail : string
      ; tool_effect_attempted : bool
      ; response_emitted : bool
      }
  | Stopped_by_host of
      { stop : host_stop
      ; usage : turn_usage option
        (** Token counts summed over the assistant frames seen before the
            host ended the turn, deduplicated by message id. The result
            frame that would carry the turn total never arrives after a
            host stop, so this sum is what the keeper records. *)
      }
  | Quota_blocked of
      { api_error_status : int option
      ; rate_limit : rate_limit option
      ; tool_effect_attempted : bool
      ; response_emitted : bool
      }
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?session_mode:session_mode ->
  config ->
  prompt:string ->
  images:image_input list ->
  (unit, error) result

val probe_subscription :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  (subscription, error) result
(** Measure the official CLI login without submitting a model turn. The child
    receives the same credential-scrubbed environment as [run_turn]. *)

val cli_admitted_reasoning_effort :
  Llm_provider.Reasoning_effort.t -> Llm_provider.Reasoning_effort.t
(** The CLI's effort vocabulary as a total snap: [Minimal] — the one effort
    the CLI refuses — becomes [Low]; every other effort is itself. [command]
    still rejects an un-snapped [Minimal], so this is the survivable path a
    caller opts into, not a silent coercion inside the argv builder. *)

val command :
  config ->
  dynamic_tools:dynamic_tool list ->
  reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  session_mode:session_mode ->
  session_id:string ->
  (string list, error) result
(** The exact argv handed to the CLI. Exposed because the flag set is a
    contract with the installed client — tests pin how [config.native]
    selects [--tools] and what [--allowedTools] pre-approves (RFC-0390). *)

val run_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?reasoning_effort:Llm_provider.Reasoning_effort.t ->
  ?session_mode:session_mode ->
  ?admitted_subscription:subscription ->
  ?on_spawned:(unit -> unit) ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?on_session_ready:(session_id:string -> (unit, string) result) ->
  ?on_turn_starting:(session_id:string -> (unit, string) result) ->
  ?on_turn_started:(session_id:string -> turn_id:string -> (unit, string) result) ->
  ?on_stream_event:(stream_event -> unit) ->
  config ->
  prompt:string ->
  images:image_input list ->
  (turn_result, error) result
(** Execute one turn through Claude Code's stream-json control protocol.

    API-key and token environment variables are removed from the child. The
    preflight requires [claude auth status --json] to report a logged-in
    [claude.ai] subscription served by [firstParty]. *)
