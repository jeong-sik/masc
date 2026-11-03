(** The host end of a microVM guest agent connection (RFC
    microvm-guest-agent-over-socket, section 3.5): one connection carries one
    request.

    {!run} connects to the socket a VM published with
    [container run --publish-socket], waits for the agent's hello, asks
    [accept] whether this agent may run the request, then sends one
    request-kind byte and the request frame and reads chunks until the exit
    chunk.

    Nothing is written before a hello is accepted. A connection made before
    the agent listens may end at once or stay silent (measured: 9 boots gave 5
    hellos, 3 immediate ends and one connection silent for 12 minutes), so a
    connection that ends or gives no hello within {!hello_wait_sec} is closed
    and a new one is made, until the connect budget runs out. Giving up on a
    connection before the request was written cannot have started anything.

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
      }  (** the budget ran out after the request was written *)
  | Broken of
      { reason : string
      ; stdout : string
      ; stderr : string
      }
      (** the request was written and the stream ended or broke before an
          exit chunk, or the exit chunk reports the shim ended on a signal *)

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
    before a hello is accepted. The chunk callbacks get the shim's stdout and
    stderr bytes as they arrive; the outcome carries all of them. [accept] is
    {!refusal} with the Keeper's [expected] ids in production. *)
