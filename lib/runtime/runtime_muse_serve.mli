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
    (** Prepared managed config for the home of the account the call runs on.
        Keeper prepares this before claiming a session so its revision enters
        the binding. When absent with a declared home, run and usage read
        prepare it before spawn. *)
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
val credential_backend_entry : string
(** The explicit file-backed credential selection shared by runtime children
    and operator sign-in commands. It keeps credentials in the selected
    XDG config home instead of macOS Keychain. *)

val login_environment : account_home:string -> string array
(** Native login writes HOME/.config/muse/auth.json. All HOME/XDG roots are
    selected explicitly, with ambient provider API credentials excluded. Like
    every Muse child, it runs with [TBH_CREDENTIAL_BACKEND=file], so the token
    is written into that file instead of the macOS Keychain. *)

val login_argv : cli_path:string -> string list
(** The official client's sign-in command, run with {!login_environment}. *)

(** How the host ended a turn, as far as a resume depends on it: a completed
    turn ran its work; a failed, cancelled or host-died one did not finish
    it. *)
type turn_ending =
  | Ended_completed
  | Ended_uncompleted

(** A turn the host ended, named by its id. *)
type ended_turn =
  { turn_id : string
  ; ending : turn_ending
  }

(** The last ended turns a resumed session may report ([lastTurn] of
    [session/resume]). [None] is a host that reported no ended turn: a
    started session, or a resume without [lastTurn]. The host's
    completed-turn count is not compared: it counts again from each
    compaction boundary, while turn ids stay stable. *)
type resume_last_turn =
  | Exactly of ended_turn option
      (** The last turn MASC knows of: the one the host reported when the
          session opened, or a turn whose ending MASC saw. *)
  | Last_or_dispatched of { last : ended_turn option; dispatched : string option }
      (** A turn was dispatched after [last] and MASC did not see how it
          ended: the host reports [last], or the dispatched turn however it
          ended. While MASC does not know that turn's id ([dispatched =
          None]), any turn the host reports may be it. *)
  | Last_or_uncompleted of { last : ended_turn option; failed : string option }
      (** A retry re-sends [failed]'s work: the host reports [last], or
          [failed] ended without completing ([None]: any turn that ended
          without completing). A host that completed it already ran that
          work, and a host that reports no last turn shows nothing about it,
          so both are refused. *)

type session_mode =
  | Start
  | Resume of { session_id : string; expected_last_turn : resume_last_turn }
      (** Resume only when the host reports a last turn [expected_last_turn]
          admits, before selecting the model or approval mode, persisting
          admission or dispatching a turn. *)

(** Where [muse serve] keeps its native XDG data, cache, state and runtime
    directories and its temporary files. HOME and the managed authentication
    config stay the selected account's. The caller makes the root with
    {!ensure_storage_dirs}; the root must be absolute. *)
type storage =
  | Stateless of string
      (** A directory made for this one call. The caller removes it after
          [run_turn] has reaped its process, so no session survives to be
          resumed, and [Resume] is refused before spawn. *)
  | Keeper_owned of string
      (** The one directory a Keeper's Muse turns share (RFC-0495). It holds
          the session the Keeper remembers, so it takes [Start] and [Resume]. *)

val ensure_storage_dirs : string -> unit
(** Makes a storage root and its [data], [cache], [state], [run] and [tmp]
    children with mode [0o700], keeping any that already exist. Other
    failures raise [Unix.Unix_error]. *)

type mcp_server =
  { name : string
  ; server : Runtime_muse_msp.mcp_server
  ; tool_names : string list
  }

(** What MASC knows about the session's workspace directory. Only
    {!origin_of_masc_directory} makes [Masc_private]. *)
type workspace_origin = private
  | Masc_private
      (** MASC made the directory for this client, puts nothing in it, and
          found it holding no entry when the turn read it. *)
  | Other_tree
      (** Any other directory: a Keeper's shared tree, or a directory MASC
          made that holds files, such as ones an earlier session with native
          writes left. *)

val other_tree : workspace_origin

val origin_of_masc_directory : string -> (workspace_origin, string) result
(** Reads a directory MASC made for the client. [Masc_private] when it holds
    no entry, [Other_tree] when it holds any. Error with the system's message
    when it cannot be read. Blocking: run it off the Eio scheduler. *)

val trusts_workspace
  :  config
  -> workspace_origin:workspace_origin
  -> mcp_servers:mcp_server list
  -> bool
(** Whether the host starts with [--trust-workspace], which makes it load the
    workspace's skills and rules. Muse Code connects a session's MCP servers
    only on a host started that way. True only when [mcp_servers] is not
    empty, the workspace is [Masc_private], and [config.native] disables
    native writes and shell, so the session cannot write a skill or a rule
    into the directory. In every other case the host starts without the flag and
    the session's MCP servers get no request. *)

type image_input = Runtime_official_client_tool.image_input =
  { media_type : string
  ; base64_data : string
  }

(** How [muse serve] ended, read from its documented exit codes. [None] in
    {!error.Process_exited} means no process exit status is available: either
    the process was not reaped within the grace period after its stdout
    closed, or the host synthesized {!Runtime_muse_msp.Terminal_host_died}
    without an exit status. *)
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

val host_died_error : reason:string -> error
(** The error for a [turn/completed] the host synthesized because it died
    mid-turn ({!Runtime_muse_msp.Terminal_host_died}): {!Process_exited}
    with the turn accepted. [reason] is the host's text, kept for the report
    only. *)

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
  ; text : string option
    (** The newest completed agent message whose phase reads as a final
        answer (see {!Runtime_muse_msp.message_phase}); a [Commentary]
        message is never the reply. [Some ""] is an explicit blank. [None]
        means the model gave no answer: a turn whose message MASC may have
        missed (a view gap during the turn, or a message still open at the
        terminal) is a [Protocol_error], never [Ok] with [None]. *)
  ; usage : Runtime_muse_msp.token_usage option
    (** Terminal aggregate, enriched with counted-once counts when the
        observed completions agree; otherwise the sum of this turn's unique
        completion events when the terminal omits usage. Never session totals. *)
  ; last_call_usage : Runtime_muse_msp.token_usage option
    (** The counts of this turn's newest model call ([session/tokenUsage]),
        with its counted-once [prompt_tokens]: what that request carried.
        [None] when the host reported no call, or when a view gap followed
        the newest call it reported. *)
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

(** What a turn that ended with a typed terminal ([completed] or [failed])
    shows it may have done outside the host's own session (RFC-0509). *)
type turn_items =
  | Turn_quiet
      (** The turn's contiguous durable range holds only [userMessage] and
          [reasoning] items, and live delivery saw no tool call and no
          answer open. *)
  | Turn_item_may_have_acted of Runtime_muse_msp.item_kind
      (** The first item seen whose kind can leave something outside the
          session: a tool call, a subagent, a workflow, a hook run, an
          answer, or a kind MASC does not know. Live delivery may name it
          without a durable read; it only ever refuses quiet. *)
  | Turn_items_unread of string
      (** The durable range could not be read, so nothing is proven. *)

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
  | Native_tool_finished of
      { observation : Runtime_native_tools.observation
      ; completion : Runtime_native_tools.completion
      ; args : string option
      ; visible_output : string option
      }
      (** MSP's completed item, including its declared status and exact
          argument/output text. These are vendor facts, not MASC receipts. *)
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
  | View_gap_observed
      (** Push delivery for the current session lost events, possibly including
          a compaction. Emitted even before [turn/start] is acknowledged;
          consumers can no longer certify the context held by that session. *)
  | Turn_terminal_received of Runtime_muse_msp.terminal
      (** The matching durable terminal has been decoded. Emitted
          before usage callbacks; [Turn_finished] still closes output afterward. *)
  | Turn_items_read of turn_items
      (** Once after [Turn_terminal_received] for a [failed] terminal, and
          for a [completed] terminal whose durable range was read. No other
          ending emits it. *)
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

val emit_stream_event : (stream_event -> unit) option -> stream_event -> unit
(** Invoke an optional stream observer, logging and dropping an ordinary
    callback failure so a buggy observer cannot abort the turn. Reserved
    controls (operator interrupt, [Eio.Time.Timeout], [Eio.Cancel.Cancelled],
    [Out_of_memory], [Stack_overflow], [Sys.Break]) still propagate. *)

val validate_turn
  :  ?session_mode:session_mode
  -> config
  -> workspace_root:string
  -> prompt:string
  -> images:image_input list
  -> (unit, error) result
(** Every deterministic client-side admission condition. [run_turn] repeats
    it before spawning. *)

type context_submission = private
  { request_id : int
  ; session_id : string
  ; write : Runtime_official_client_write.t
        (** The [turn/start] line: [Turn_text] slots in [params.input]. *)
  }

val context_submission_to_json : context_submission -> Yojson.Safe.t
(** Content-free proof of a complete [turn/start] write to [muse serve]
    stdin. Not the host's acceptance. *)

val run_turn
  :  storage:storage
  -> ?session_mode:session_mode
  -> ?mcp_servers:mcp_server list
  -> ?workspace_origin:workspace_origin
  -> ?reasoning_effort:Runtime_muse_msp.reasoning_effort
  -> ?on_session_ready:(session_id:string -> last_turn:ended_turn option -> (unit, string) result)
  -> ?on_prompt_sent:(unit -> unit)
  -> ?on_context_submission:(context_submission -> unit)
  -> ?on_stream_event:(stream_event -> unit)
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> account:_ Runtime_account_access.muse_authorized
  -> config
  -> workspace_root:string
  -> prompt:string
  -> images:image_input list
  -> (turn_result, error) result
(** [account] is the account the process starts on. A declared home selects
    the process's HOME and XDG config, data, cache, state and runtime roots,
    and ambient XDG roots are discarded. Managed preparation imports
    file-backed auth into a durable private generation, sets XDG_CONFIG_HOME
    there, and replaces TMPDIR with its private directory. This is not a
    separate macOS Keychain identity, and does not confine filesystem access.
    {!Runtime_account_access.Process_environment} keeps the environment of
    the caller, which protocol fixtures use.

    [storage] says where the host keeps its native files (see {!storage}).
    Native durability and completion notifications remain enabled for both.

    [workspace_root] is the absolute directory the session works in.
    [mcp_servers] are added to this session only. A non-empty list requests
    [sessionMcp] at the handshake and fails with {!Capability_not_granted}
    when the host withholds it. [workspace_origin] defaults to {!other_tree};
    {!trusts_workspace} decides from it whether the host is started to
    connect them.

    The returned workspace must match the request on both start and resume,
    and a start must report the explicitly selected model. A resumed session
    gets that model through [session/setModel], whatever model it reports,
    and is admitted when the host accepts it; a refused or failed selection
    fails the turn. Mismatches refuse admission before
    callbacks. A started session must
    hold no turns; a resumed one must report a last turn its
    [expected_last_turn] admits. Start must report the requested approval mode. Resume reapplies that mode after the
    model selection and verifies the returned effective mode before admitting
    the session.
    [on_session_ready] runs once the host has returned the session id, before
    the turn is written, so the caller can persist the id first. It receives
    the last turn the host reported for the session, [None] for a started
    one, which the caller stores to build the next resume's
    [expected_last_turn]. Its failure
    fails the turn. [on_prompt_sent] runs after the complete [turn/start]
    line is written. [on_context_submission] receives that line's receipt
    just before it; its non-reserved exceptions are logged as unavailable
    measurement and the turn continues. *)

val read_usage
  :  mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> account:_ Runtime_account_access.muse_authorized
  -> config
  -> (Runtime_muse_msp.subscription_usage option, error) result
(** Handshake plus [usage/read], with no session and no model call. [None]
    when the host has observed no usage yet. *)

val list_models :
  mgr:_ Eio.Process.mgr -> clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t -> account:_ Runtime_account_access.muse_authorized -> config ->
  (Runtime_muse_msp.model_catalog, error) result
(** Handshake plus [model/list], without session admission or model work.
    Ephemeral servers can provide metadata too. The reported catalog source
    is preserved; success is not authentication or invocation evidence. *)
