(** A single-turn Codex app-server client.

    This is an agent-runtime boundary, not an {!Llm_provider.Llm_transport}
    implementation. Codex owns the whole turn. MASC owns process lifetime,
    typed CLI authentication admission, and terminal projection. *)

type subscription =
  | Chatgpt of { plan_type : string; email : string option }
  | Api_key
  | Provider_managed
  | Amazon_bedrock

val authentication_to_string : subscription -> string

type probe_result =
  { subscription : subscription
  ; user_agent : string option
  }

type config =
  { cli_path : string
  ; isolated_home : string option
    (** Verification-only private CODEX_HOME prepared with auth/provider configuration.
        Normal turns leave this [None] to retain the user's configured home. *)
  ; model : string option
  ; developer_instructions : string option
  ; native : Runtime_native_tools.posture
    (** Built-in tool posture (RFC-0390): [Native_read] maps to the
        [:read-only] named permissions profile, [Native_full] to
        [:workspace]. These are app-server profile ids sent as
        [thread/start]'s [permissions], not values of the CLI's [SandboxMode]
        vocabulary, which belongs to the [sandbox] field this client never
        sends. [Native_none] is unrepresentable on Codex and fails as
        config. *)
  ; admission_timeout_s : float
    (** Finite bound for post-spawn subscription/account checks, thread
        creation, history injection, and the complete [turn/start] write. *)
  ; timeout_s : float option
    (** Maximum silence between app-server protocol messages. Each received
        message resets the deadline; a progressing turn has no wall limit.
        [None] removes the deadline after the complete [turn/start] dispatch —
        the spawned client decides when its own turn ends, which is the posture
        of running the CLI directly. Setup and dispatch remain bounded by
        [admission_timeout_s]. Declared as [turn-timeout-s] in runtime config,
        where [0] selects [None]. *)
  ; wall_clock_ceiling_s : float option
    (** Whole-turn wall-clock ceiling measured from spawn ([None] selects the
        shared hours-scale default). The idle timeout above resets on every
        received message, so this is the only bound a turn of continuous
        thin progress cannot outlive (#31242). *)
  ; output_schema : Yojson.Safe.t option
    (** JSON Schema for the turn's final assistant message, sent as
        [outputSchema] on the v2 [turn/start] request. The flag documented for
        [codex exec] is a different surface; this transport speaks the
        app-server protocol, whose own generated schema declares the field.
        The schema binds the message itself, so unlike the Antigravity adapter
        there is no separate structured field to prefer. *)
  }

val default_timeout_s : float
val default_config : unit -> config

(** One image attached to a turn. [base64_data] is the raw base64 payload with
    no data-URL prefix and no newlines; the app-server [image] input variant
    takes an inline data URL, which this module builds. *)
type image_input =
  { media_type : string
  ; base64_data : string
  }

type thread_mode =
  | Start
  | Resume of { thread_id : string }

(* The per-turn counts the app-server reports on thread/tokenUsage/updated,
   its [last] breakdown. OpenAI counting: [input_tokens] already includes the
   cached prefix and [output_tokens] already includes reasoning, the same
   reading Backend_openai_parse makes of the API wire. [cache_write_input_tokens]
   defaults to 0 on the wire. *)
type token_usage =
  { input_tokens : int
  ; cached_input_tokens : int
  ; cache_write_input_tokens : int
  ; output_tokens : int
  ; reasoning_output_tokens : int
  ; total_tokens : int
  }

type turn_result =
  { thread_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; user_agent : string option
  ; resumed : bool
  ; usage : token_usage option
    (* [None] when no thread/tokenUsage/updated for this turn arrived before
       turn/completed; the host then reports the usage scope as unavailable
       rather than a count of zero. *)
  }

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
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
  ; content_blocks : Agent_core.Types.content_block list option
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type elicitation_mode = Form | Openai_form | Url

type elicitation_cancel_reason = Host_input_unavailable

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
  | Elicitation_cancelled of
      { server_name : string
      ; mode : elicitation_mode
      ; reason : elicitation_cancel_reason
      }
  | Turn_finished of { text : string }

type history_role =
  | User
  | Assistant
  | Developer

type history_message =
  { role : history_role
  ; text : string
  }

val history_bytes : history_message list -> int
(** Bytes the history occupies on the wire. On a [Start] this is what
    [thread/inject_items] carries into the new thread; on a [Resume] the thread
    already holds it. Bytes this process sends, not provider tokens. *)

val dynamic_tool_bytes : dynamic_tool list -> int
(** Bytes the tool declarations occupy in [thread/start]'s [dynamicTools]. Sums
    each name, description, and serialized input schema; the protocol wrapper
    keys are excluded because they are fixed per tool. *)

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Turn_input_write_failed of string
      (* The client and thread were initialized, but complete turn-input
         transmission is unconfirmed. Partial delivery must not be replayed
         as a proven pre-spawn failure. *)
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int option
      ; message : string
      }
  | Subscription_required of string
  | Unsupported_server_request of string
  | Context_window_exceeded of
      { message : string
      ; tool_effect_attempted : bool
      }
  | Turn_failed of string
  | Stopped_by_host of host_stop
  | Turn_interrupted
  | Runtime_shutting_down
      (** The MASC host entered graceful shutdown while this client was
          active. Kept distinct from {!Process_exited}: EOF is only the
          transport symptom here; host shutdown is the observed cause. *)
  | Process_exited of string
  | Timeout of
      { seconds : float
      ; turn_accepted : bool
        (** [true] when [turn/start] was accepted before the protocol went
            silent: the upstream turn may still be executing (and committing
            effects) server-side, so the outcome is ambiguous and must not
            trigger lane rotation. [false] means nothing was started upstream
            and retrying elsewhere is safe. *)
      }

val error_to_string : error -> string

val validate_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?thread_mode:thread_mode ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  prompt:string ->
  images:image_input list ->
  (unit, error) result
(** Validate every deterministic client-side admission condition. Keeper calls
    this before it durably claims a session; [run_turn] repeats the same check
    at the process boundary. *)

val probe_subscription :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  (probe_result, error) result
(** Start the official app-server and measure only [initialize] plus
    [account/read]. No thread or model turn is created. *)

type listed_model = { id : string; model : string; display_name : string; is_default : bool }
val list_models :
  mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock -> cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config -> (listed_model list, error) result
(** Account admission followed by paginated model/list, without thread/start or
    turn/start. The CLI owns cache policy; callers needing refresh use an isolated
    connection home without a model cache. This response has no context window. *)

val run_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?reasoning_effort:Llm_provider.Reasoning_effort.t ->
  ?thread_mode:thread_mode ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?history:history_message list ->
  ?developer_context:string list ->
  (* Explicit developer items appended on Start and Resume before turn/start.
     They retain developer authority and persist in the thread; this is not
     a temporary context replacement or an idempotent delivery API. Callers
     own retry/reconciliation and must not infer token savings from IPC bytes.
     Empty by default; Keeper production projection is unchanged. *)
  ?on_prompt_sent:(unit -> unit) ->
  (* Called after the complete turn-input message is written to the CLI.
      This is transport evidence, not provider acceptance. Never called for
      preparation, spawn, handshake, or incomplete input-write failures. *)
  ?on_thread_ready:(thread_id:string -> (unit, string) result) ->
  ?on_turn_starting:(thread_id:string -> (unit, string) result) ->
  ?on_turn_started:(thread_id:string -> turn_id:string -> (unit, string) result) ->
  ?on_stream_event:(stream_event -> unit) ->
  config ->
  prompt:string ->
  images:image_input list ->
  (turn_result, error) result
(** [config.admission_timeout_s] finitely bounds initialization, account
    admission, thread preparation, and the complete [turn/start] write. The
    model's [config.timeout_s] takes authority only after that dispatch
    succeeds. *)
