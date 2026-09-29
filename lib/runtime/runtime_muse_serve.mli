(** A single-turn Muse Code client over [muse serve].

    This is an official-client runtime boundary, not an
    {!Llm_provider.Llm_transport}. Muse Code owns its subscription login, the
    model turn and its built-in tools. MASC owns the process lifetime, the
    approval posture it declares for the session, and the projection of the
    turn's terminal. The wire is the Muse Session Protocol, decoded by
    {!Runtime_muse_msp}.

    One call spawns [muse serve], starts or resumes one session, runs one
    turn and stops the process. The session outlives the process: the host
    writes it under its own home, and a later call resumes it by id. *)

type config =
  { cli_path : string
  ; prepared_home : Runtime_muse_home.t option
    (** Prepared managed config for [account_home]. Keeper prepares this before
        claiming a session so its revision enters the binding. When absent
        with a selected account, run and usage read prepare it before spawn. *)
  ; account_home : string option
    (** [Some absolute_path] selects this process's HOME and XDG config,
        data, cache, state and runtime roots. Ambient XDG roots are discarded.
        [None] is the low-level caller environment used by protocol fixtures;
        product routing selects an explicit account. Managed preparation
        imports file-backed auth into a durable private generation, sets
        XDG_CONFIG_HOME there, and replaces TMPDIR with its private directory. This is not a separate
        macOS Keychain identity, and does not confine filesystem access. *)
  ; model : string option
    (** The model every turn runs on: [session/start]'s [modelId], and the
        [session/setModel] selection on every resumed session.
        [None] takes the host's default and is never checked. *)
  ; native : Runtime_native_tools.posture
    (** Built-in tool posture (RFC-0390), sent as the session's approval
        mode. Full uses [allowAll] under the managed sandbox profile. Read uses
        [promptUnmatched] and passes [--disable-write --disable-shell] to the
        host: native writes and shell execution are disabled independently
        of the selected home's rules. For the remaining tools those rules decide what runs,
        and any request outside the exact attached MCP tool list is denied. MSP has no switch that removes the built-in tools, so
        [Native_none] fails as config. *)
  ; admission_timeout_s : float
    (** Finite bound on the handshake, the session start or resume, the
        session callback and the complete [turn/start] write. *)
  ; timeout_s : float option
    (** Maximum silence between protocol messages while the model turn runs.
        Every message resets it. It is disarmed when the host opens a tool
        item, because the host may write nothing until that item completes.
        Model text arms it
        again even if a tool item stays open, as a backgrounded task's item
        does while the turn goes on. [None] removes it after dispatch. *)
  }

val default_timeout_s : float
val default_config : unit -> config
val login_environment : account_home:string -> string array
(** Native login writes HOME/.config/muse/auth.json. All HOME/XDG roots are
    selected explicitly, with ambient provider API credentials excluded. Like
    every Muse child, it runs with [TBH_CREDENTIAL_BACKEND=file], so the token
    is written into that file instead of the macOS Keychain. *)

val login_argv : cli_path:string -> string list
(** The official client's sign-in command, run with {!login_environment}. *)

type session_mode =
  | Start
  | Resume of { session_id : string; expected_turn_count : int }
      (** Resume only when the host reports this completed-turn count, before
          changing approval mode, persisting admission or dispatching a turn. *)

type mcp_server =
  { name : string
  ; server : Runtime_muse_msp.mcp_server
  ; tool_names : string list
  }

type image_input =
  { media_type : string
  ; base64_data : string
  }

(** How [muse serve] ended, read from its documented exit codes. [None] in
    {!error.Process_exited} means the process was not reaped within the
    grace period after its stdout closed. *)
type exit_status =
  | Exit_clean  (** 0 *)
  | Exit_unhandled  (** 1 *)
  | Exit_usage  (** 2: bad arguments; also a refused reasoning tier. *)
  | Exit_config_or_credential  (** 3 *)
  | Exit_session_lease_held  (** 4: another process holds the session. *)
  | Exit_sdk_surface_disabled  (** 5 *)
  | Exit_code of int  (** Any other code, which MSP calls a crash. *)
  | Exit_signal of int

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Turn_input_write_failed of string
      (** The session is ready but the [turn/start] write did not complete,
          so whether the host received the turn is unknown. *)
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int
      ; message : string
      }
  | Capability_not_granted of Runtime_muse_msp.capability
      (** The session needed a capability the host did not grant, such as
          [sessionMcp] for MASC's tool bridge. *)
  | Session_not_durable
      (** The host declared ephemeral sessions. Refused at initialization,
          before starting or resuming a session or sending a model turn. *)
  | Session_model_mismatch of
      { requested : string
      ; resumed : string option
      }
      (** A start reported another model than the explicitly requested one, or
          none. Refused before session persistence or turn dispatch. [resumed]
          is the model the start reported. A resumed session is not checked
          this way: its reported model is the host's metadata, so every resume
          selects the requested model through [session/setModel] instead. *)
  | Session_workspace_mismatch of
      { requested : string
      ; reported : string option
      }
      (** Start and resume must report the exact requested workspace before admission. *)
  | Session_approval_mode_mismatch of
      { requested : Runtime_muse_msp.approval_mode
      ; reported : Runtime_muse_msp.approval_mode option
      }
      (** The effective mode must match the native posture before session
          persistence or dispatch. [None] means start reported no mode. *)
  | Auth_required of string
      (** The host has no usable login ([authRequired]). *)
  | Turn_failed of Runtime_muse_msp.turn_error
  | Turn_cancelled
  | Unsupported_server_request of string
  | Runtime_shutting_down
  | Process_exited of
      { status : exit_status option
      ; detail : string
      ; turn_accepted : bool
        (** [false] when the process died before the [turn/start] line was
            written: no turn ran, so another candidate may be tried. [true]
            once it was written, because the host takes a command in
            durably before it answers. *)
      }
  | Timeout of
      { seconds : float
      ; turn_accepted : bool
        (** [true] once [turn/start] was written: the turn may still be
            running on the host, so the outcome is ambiguous. *)
      }

val error_to_string : error -> string

type call_model =
  | Named of string  (** The host named the model the call ran on. *)
  | Unnamed
      (** The host reported the call's usage without naming its model
          ([modelId] absent or null): the call's model is unknown. *)

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string option
    (** The model the session started on, as the host reported it, or the
        model [session/setModel] selected on a resumed session. *)
  ; text : string  (** The last completed agent message of the turn. *)
  ; usage : Runtime_muse_msp.token_usage option
    (** Terminal aggregate, enriched with counted-once counts when the
        observed completions agree; otherwise the sum of this turn's unique
        completion events when the terminal omits usage. Never session totals. *)
  ; tool_calls : int
  ; approvals_decided : int
  ; call_models : call_model list
    (** What the host reported for this turn's model calls
        ([session/tokenUsage]) in call order; a call that names the same model
        as the one before it, or like it names none, adds nothing. Empty when
        the host reported no call. [model] is what the session selected;
        these are what the calls ran on. *)
  ; resumed : bool
  ; server_version : string
  }

val reported_model : turn_result -> string option
(** The model to name the turn after. The last call's model when the host
    named it; [None] when the last call was [Unnamed], since that call's
    model is unknown; the session's selection, [model], when the host
    reported no call (hosts before 1.4.0 send no [session/tokenUsage]). *)

type stream_event =
  | Turn_started of
      { session_id : string
      ; turn_id : string
      ; model : string option
      }
  | Text_delta of { item_id : string; text : string }
  | Text_completed of { item_id : string; text : string }
      (** The full completed agent-message text, including items with no deltas. *)
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Approval_decided of
      { tool_name : string
      ; subject : Runtime_muse_msp.approval_subject_kind
      ; decision : Runtime_muse_msp.approval_decision
      }
      (** An [approval/request] the host sent despite the session's mode,
          answered from the posture: [Native_full] approves once,
          [Native_read] denies. *)
  | Subscription_usage_observed of Runtime_muse_msp.subscription_usage
      (** Provider subscription observation, including notifications received
          before request acknowledgement. Consumers may record its reported
          exhaustion/reset in the selected account's quota scope. *)
  | Compaction_observed of Runtime_muse_msp.compaction
      (** A [compaction] item of this turn completed: the host rewrote what
          the model sees. An automatic compaction of a single oversized input
          reaches the model as a short summary, and the turn still
          completes, so this event is the only trace of that loss. *)
  | Turn_terminal_received of Runtime_muse_msp.terminal
      (** The matching durable terminal has been decoded. Emitted
          before usage callbacks; [Turn_finished] still closes output afterward. *)
  | Model_call_reported of
      { session_id : string
      ; turn_id : string
      ; model : string option
      }
      (** The host reported one of this turn's model calls
          ([session/tokenUsage]) with [model] as the model it ran on, [None]
          when it named none, and the call before it reported something else.
          Emitted before [Usage_reported]. *)
  | Usage_reported of
      { session_id : string
      ; turn_id : string
      ; usage : Runtime_muse_msp.token_usage
      }
      (** The turn's summed usage from [turn/completed], emitted before the
          final success/failure projection so a failed turn still reports it. *)
  | Turn_finished of { text : string }

val validate_turn
  :  ?session_mode:session_mode
  -> config
  -> workspace_root:string
  -> prompt:string
  -> images:image_input list
  -> (unit, error) result
(** Every deterministic client-side admission condition. [run_turn] repeats
    it before spawning. *)

val run_turn
  :  ?storage_root:string
  -> ?session_mode:session_mode
  -> ?mcp_servers:mcp_server list
  -> ?reasoning_effort:Runtime_muse_msp.reasoning_effort
  -> ?on_session_ready:(session_id:string -> (unit, string) result)
  -> ?on_prompt_sent:(unit -> unit)
  -> ?on_stream_event:(stream_event -> unit)
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> config
  -> workspace_root:string
  -> prompt:string
  -> images:image_input list
  -> (turn_result, error) result
(** [storage_root] selects an absolute caller-owned per-call directory for native
    XDG data/cache/state/runtime and temporary files, preserving the selected HOME
    and managed authentication config. The caller creates its [data], [cache],
    [state], [run], and [tmp] children and removes the tree after this call has
    reaped its process. This stateless mode refuses resume before spawn; default
    calls keep the selected account's durable storage. Native durability and
    completion notifications remain enabled in both cases.

    [workspace_root] is the absolute directory the session works in.
    [mcp_servers] are added to this session only. A non-empty list requests
    [sessionMcp] at the handshake and fails with {!Capability_not_granted}
    when the host withholds it.

    The returned workspace must match the request on both start and resume,
    and a start must report the explicitly selected model. A resumed session
    gets that model through [session/setModel], whatever model it reports,
    and is admitted when the host accepts it; a refused or failed selection
    fails the turn. Mismatches refuse admission before
    callbacks. A started session must
    hold no turns; resume requires the expected retained count. Start must
    report the requested approval mode. Resume reapplies that mode after the
    model selection and verifies the returned effective mode before admitting
    the session.
    [on_session_ready] runs once the host has returned the session id, before
    the turn is written, so the caller can persist the id first. Its failure
    fails the turn. [on_prompt_sent] runs after the complete [turn/start]
    line is written. *)

val read_usage
  :  mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> config
  -> (Runtime_muse_msp.subscription_usage option, error) result
(** Handshake plus [usage/read], with no session and no model call. [None]
    when the host has observed no usage yet. *)

val list_models :
  mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> config ->
  (Runtime_muse_msp.model_catalog, error) result
(** Handshake plus [model/list], without session admission or model work.
    Ephemeral servers can provide metadata too. The reported catalog source
    is preserved; success is not authentication or invocation evidence. *)
