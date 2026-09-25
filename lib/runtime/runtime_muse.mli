(** A single-turn client for the official Muse CLI (Meta Muse Code).

    This is not a Meta HTTP provider. Muse owns authentication (its login
    or [META_API_KEY]/[MODEL_API_KEY]), its session and model loop. MASC
    owns the child lifetime, argv, and terminal projection.

    Wire: [muse exec --json] prints MSP session envelopes, one JSON object
    per line. Text accumulates from [run.output.delta] payloads
    ([run_output_delta]); the turn ends at [run.terminal.*] ([run_terminal]).
    Payloads outside this contract are ignored: the MSP surface is
    wire-open, so an unknown record never fails a turn. A terminal whose
    word is not ["completed"] fails the turn carrying the CLI's own
    terminal word and reason verbatim; an unknown terminal word is a
    protocol error, never a silent success. Usage is reported only when
    the terminal record carries complete counters; a partial or absent
    usage block means no usage event, never a zero-filled one.

    The terminal record's own text is the turn's answer. The deltas are
    display-only: a recorded run shows the full answer both as deltas and
    as the terminal text, so joining them would print it twice. *)

(** Muse's own [--reasoning-effort] vocabulary, spelled as the CLI takes
    it. There is no mapping here: the keeper layer selects a level, this
    client only spells it. *)
type effort =
  | Effort_none
  | Effort_minimal
  | Effort_low
  | Effort_medium
  | Effort_high
  | Effort_xhigh
  | Effort_max
  | Effort_ultra

val effort_to_string : effort -> string

(** Muse's own [--approval-mode] vocabulary. [On_request] is the CLI
    default. [Never] lets the client's built-in tools run without asking;
    the keeper layer admits it only for Yolo keepers, the same rule that
    guards native-full on the other official clients. *)
type approval_mode =
  | Untrusted
  | On_request
  | Never

val approval_mode_to_string : approval_mode -> string

type config =
  { cli_path : string
  ; cwd : string
        (** The keeper base path. It becomes both the child's working
            directory and its [--workspace] root. *)
  ; model : string option
        (** [None] omits [--model]: the CLI's configured default decides.
            [Some ""] is rejected, it is not a way to spell [None]. *)
  ; reasoning_effort : effort option
  ; approval_mode : approval_mode
  ; output_schema : Yojson.Safe.t option
        (** JSON Schema the CLI enforces on the turn's final answer.
            [None] leaves the answer unfenced. *)
  ; admission_timeout_s : float
        (** Finite bound for spawn until the first valid envelope record. *)
  ; timeout_s : float option
        (** Maximum silence between valid envelope records. [None] removes
            the deadline: the spawned client decides when its turn ends.
            The post-spawn pre-first-record phase stays bounded by
            [admission_timeout_s]. *)
  ; wall_clock_ceiling_s : float option
        (** Whole-turn wall-clock ceiling measured from spawn. *)
  }

val default_timeout_s : float
val default_config : cwd:string -> config

(** One image attached to a turn. Muse takes local file paths
    ([--image], repeatable), not inline payloads. *)
type image_input = { path : string }

(** Token counters read from a terminal record. Every field is present or
    there is no usage event at all: missing counters never read as zero. *)
type token_usage =
  { input_tokens : int
  ; output_tokens : int
  ; reasoning_tokens : int
  ; cached_tokens : int
  }

type stream_event =
  | Turn_started of
      { session_id : string
      ; turn_id : string option
      }
  | Text_delta of string
  | Usage_reported of
      { session_id : string
      ; usage : token_usage
      }
      (** The turn's spend from its terminal record, emitted before the
          terminal word decides success, so a failed turn still reports
          it. Absent when the record carries no complete usage block. *)
  | Turn_finished of { text : string }

(** Fold state over one child's envelope stream. *)
type progress =
  { session_id : string option
  ; turn_id : string option
  ; started : bool
  }

val empty_progress : progress

type session_mode =
  | Start
  | Resume of { session_id : string }
(** [Start] asks the CLI for a fresh session. [Resume] names the exact
    durable session ([--session-id]) and never starts a new one. *)

type turn_result =
  { session_id : string
  ; turn_id : string option
  ; text : string
  ; usage : token_usage option
  ; resumed : bool
        (** Echoes the requested [session_mode]: true when the turn ran
            under [Resume], however the server answered. *)
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Turn_failed of
      { terminal : string
      ; reason : string option
      ; usage : token_usage option
      }
  | Process_exited of
      { detail : string
      ; turn_admitted : bool
      }
      (** [turn_admitted] is false when the client died before the first
          valid envelope record, which means no turn was submitted and
          another candidate may still be tried. *)
  | Timeout of float

val error_to_string : error -> string

val apply_record : progress -> Yojson.Safe.t -> ((progress * stream_event list), error) result
(** Fold one parsed envelope line. Unknown payload kinds are ignored.
    A failed or cancelled terminal word ends the fold with [Turn_failed];
    an unknown terminal word ends it with [Protocol_error]. The first
    observed session and turn identity sticks: a later record naming a
    different one does not move the fold. *)

val command :
  prompt_file:string
  -> schema_file:string option
  -> images:image_input list
  -> session_mode:session_mode
  -> config
  -> (string list, error) result
(** Build CLI argv from prepared files. Prompt and schema bytes never
    occupy argv. Exposed because the flag set is a contract with the
    installed client: tests pin it. *)

val client_environment : unit -> string array
(** The credential-preserving environment the child receives: the login
    home plus the API-key variables the CLI reads. Nothing else from the
    operator shell leaks in. Values are read through
    [Env_config_core.raw_value_opt], so a variable the parent did not
    export but boot overrides define still reaches the child. *)

val effort_of_reasoning_effort : Llm_provider.Reasoning_effort.t -> effort
(** Total snap from the provider-neutral effort to the CLI's flag spelling.
    The CLI's [ultra] has no provider-neutral source and stays unreachable. *)

val run_turn :
  ?on_stream_event:(stream_event -> unit)
  -> ?session_mode:session_mode
  -> ?on_prompt_sent:(unit -> unit)
  -> ?on_session_ready:(session_id:string -> turn_id:string option -> unit)
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> config
  -> prompt:string
  -> images:image_input list
  -> (turn_result, error) result
(** Execute one turn through [muse exec --json].

    Supported credential environment variables are preserved. Credential
    validity and selected-model access are established by the actual turn:
    the CLI has no pre-turn admission surface.

    [on_prompt_sent] fires once the child is spawned with its prompt file:
    the argv and files are handed over, which is the transport evidence for
    this lane. Never fires for validation or spawn failures. [on_session_ready]
    fires on the turn's first envelope record carrying a session identity. *)

val serve_usage :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  (Yojson.Safe.t option, error) result
(** Ask a serve host for its subscription usage without a model turn:
    [muse serve] over stdio, [initialize], [initialized], [usage/read],
    then stdin EOF and reap. Returns the raw [usage] value, or [None] when
    the host answers [{}]: it truthfully observed nothing, which is not an
    error. No session log is written: the host runs under
    [--no-session-log].

    The JSON-RPC errors the host answers with are protocol errors carrying
    the host's own code and message; no prompt is ever sent on this
    connection, so there is nothing to redact. *)
