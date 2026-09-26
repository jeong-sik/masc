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
  ; model : string option
    (** [session/start]'s [modelId]. [None] takes the host's default. *)
  ; native : Runtime_native_tools.posture
    (** Built-in tool posture (RFC-0390). [Native_full] selects [allowAll]
        and starts the host with its whole built-in surface.

        [Native_none] and [Native_read] run the same MASC-tools-only
        session. The host starts with [--disable-write --disable-shell], the
        session selects [promptUnmatched], and MASC answers each approval
        the host raises itself: a call whose subject is a tool named exactly
        like one of the session's MASC tools ({!session_mcp_server}) is
        allowed once, and every other call is rejected. Muse Code offers no
        read-only built-in set MASC could grant, so [Native_read] is
        stricter here than on the other clients, not looser.

        MSP lets a client select a mode but never state a rule
        ([ApprovalMode] is closed, "select, never create"). A call the
        host's own rules already allow therefore runs without an approval
        reaching MASC; under an operator profile that asks nothing, such as
        [:unrestricted], that can include a built-in read. MASC never
        answers with a choice that saves a rule in the operator's files
        ([approvedForSession], [approvedPolicyAmendment]). *)
  ; admission_timeout_s : float
    (** Finite bound on the handshake, the session start or resume, the
        session callback and the complete [turn/start] write. *)
  ; timeout_s : float option
    (** Maximum silence between protocol messages while the model turn runs.
        Every message resets it. It is disarmed when the host opens a tool
        item, because the host may write nothing until that item completes;
        only [wall_clock_ceiling_s] bounds that wait. Model text arms it
        again even if a tool item stays open, as a backgrounded task's item
        does while the turn goes on. [None] removes it after dispatch. *)
  ; wall_clock_ceiling_s : float option
    (** Whole-turn ceiling measured from spawn. [None] selects
        {!Runtime_wall_clock.default_ceiling_s}. *)
  }

val default_timeout_s : float
val default_config : unit -> config

type session_mcp_server =
  { name : string
    (** The session's [mcpServers] key. The host shows the model each of
        this server's tools as [mcp__<name>__<tool>]. *)
  ; server : Runtime_muse_msp.mcp_server
  ; tool_names : string list
    (** The tools this server lists for the session, named by the same
        source that answers its [tools/list]. Under [Native_none] and
        [Native_read] they are the only calls an approval is granted
        for. *)
  }

type session_mode =
  | Start
  | Resume of { session_id : string }

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
  | Session_model_mismatch of
      { requested : string
      ; reported : string
      }
      (** The host named another model for the session than [config.model],
          on [session/start] or on [session/resume] (which cannot select a
          model). A session whose [modelId] is [null] is not refused: the
          schema reads [null] as a record that omits the model, not as
          another model. The caller starts a new session when its model
          changes. *)
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

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string option  (** The session's model as the host reported it. *)
  ; text : string  (** The last completed agent message of the turn. *)
  ; usage : Runtime_muse_msp.token_usage option
  ; tool_calls : int
  ; approvals_decided : int
    (** Decisions this client made that the host accepted. One the host had
        already resolved, or one still unanswered when the turn ended, is
        not counted. *)
  ; resumed : bool
  ; server_version : string
  }

type stream_event =
  | Turn_started of
      { session_id : string
      ; turn_id : string
      ; model : string option
      }
  | Text_delta of
      { item_id : string  (** The agent-message item the text belongs to. *)
      ; text : string
      }
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Approval_decided of
      { tool_name : string
      ; subject : Runtime_muse_msp.approval_subject_kind
      ; decision : Runtime_muse_msp.approval_decision
      }
      (** An [approval/request] the host raised, answered from the posture:
          [Native_full] approves once; [Native_none] and [Native_read]
          approve once a call to one of the session's MASC tools and reject
          any other. Emitted when the host accepts the [approval/decide],
          not when it is written. *)
  | Approval_resolved_by_host of
      { tool_name : string
      ; subject : Runtime_muse_msp.approval_subject_kind
      ; resolution : Runtime_muse_msp.approval_resolution option
      }
      (** The host closed the approval before this client's decision landed
          and answered [approvalAlreadyResolved] with the winning resolution,
          such as its own policy's. The turn goes on. *)
  | Subscription_usage_observed of Runtime_muse_msp.subscription_usage
      (** A [usage/changed] notification, for the operator view only. *)
  | Usage_reported of
      { session_id : string
      ; turn_id : string
      ; usage : Runtime_muse_msp.token_usage
      }
      (** The turn's summed usage from [turn/completed], emitted before the
          terminal is judged so a failed turn still reports it. *)
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
  :  ?session_mode:session_mode
  -> ?mcp_servers:session_mcp_server list
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
(** [workspace_root] is the absolute directory the session works in.
    [mcp_servers] are added to this session only, and their [tool_names]
    are the MASC tools a MASC-tools-only session allows. A non-empty list
    requests [sessionMcp] at the handshake and fails with
    {!Capability_not_granted} when the host withholds it.

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
