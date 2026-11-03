(** The host end of a microVM guest agent connection (RFC
    microvm-guest-agent-over-socket, section 3.5): one connection carries one
    request.

    {!run} connects to the socket a VM published with
    [container run --publish-socket], waits for the agent's hello, asks
    [accept] whether this agent may run the request, then sends one
    request-kind byte and the request frame and reads chunks until the exit
    chunk.

    Nothing is written before a hello is accepted. A connection made before
    the agent listens may end at once or stay silent (one stayed silent for 12
    minutes; docs/evidence/2026-11-03-microvm-request-transport), so a
    connection that ends or gives no hello within {!hello_wait_sec} is closed
    and a new one is made, until the connect budget runs out. Giving up on a
    connection before the request was written cannot have started anything.
    An agent whose first chunk cannot be read, or is not a hello, is not
    retried: it is there and speaks something else.

    Each connection lives in its own switch, so a failed attempt holds no
    descriptor past itself. The outcome keeps a local process's output bound
    (the head and the tail, {!Common.max_process_capture_head_bytes} and
    {!Common.max_process_capture_tail_bytes}); the chunk callbacks get every
    byte.

    Closing the connection is the cancel: the agent closes the shim's stdin
    and the shim stops its payload. A budget that runs out closes it. *)

type expected =
  { uid : int
  ; gid : int
  }
(** The Keeper uid and gid the agent must have dropped to. *)

type refusal =
  | Other_relay_version of { agent : int }
  | Root_writable
  | Other_owner of
      { uid : int
      ; gid : int
      }
  | New_privileges_allowed

val refusal : expected:expected -> Exec_ssh_protocol.Relay.hello -> refusal option
(** Why this host does not use an agent that sent this hello, or [None]. The
    facts are checked in a fixed order: relay version, read-only root, owner,
    [no_new_privs]. *)

val refusal_to_string : refusal -> string

type request =
  | Run of { frame : string }  (** a request frame, {!Exec_ssh_protocol.encode_request} *)
  | Probe  (** the shim's [--probe] answer *)

type not_sent =
  | Unreachable of
      { attempts : int
      ; last : string  (** what the last attempt saw *)
      }  (** no accepted hello within the connect budget *)
  | Refused of refusal
  | Incompatible of string
      (** an agent answered with a first chunk this host cannot read, or one
          that is not a hello *)
  | Bad_budget of
      { connect_budget_sec : float
      ; budget_sec : float
      }  (** a caller passed a budget that is not finite and positive *)

type outcome =
  | Not_sent of not_sent  (** nothing was written to the agent *)
  | Exited of
      { code : int  (** the shim's exit code *)
      ; stdout : string
      ; stderr : string
      }
  | Timed_out of
      { stdout : string
      ; stderr : string
      }  (** the budget ran out after the request started going out *)
  | Broken of
      { reason : string
      ; stdout : string
      ; stderr : string
      }
      (** the request started going out and the stream ended or broke
          before an exit chunk, or the exit chunk reports the shim ended on a
          signal *)

val hello_wait_sec : float
(** How long one connection waits for its hello. *)

val run :
  net:[> 'tag Eio.Net.ty ] Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  ?on_stdout_chunk:(string -> unit) ->
  ?on_stderr_chunk:(string -> unit) ->
  accept:(Exec_ssh_protocol.Relay.hello -> refusal option) ->
  socket:string ->
  connect_budget_sec:float ->
  budget_sec:float ->
  request ->
  outcome
(** [budget_sec] bounds the whole call; [connect_budget_sec] bounds the part
    before a hello is accepted. A budget that is not finite and positive ends
    the call as [Bad_budget] with no attempt: a caller's mistake, never read
    as an agent that is missing. The chunk callbacks get the
    shim's stdout and stderr bytes as they arrive; the outcome keeps them
    bounded as above. [accept] is {!refusal} with the Keeper's [expected] ids
    in production. *)
