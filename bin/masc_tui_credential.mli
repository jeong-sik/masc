(** What this client is called, and what it says when the server refuses it.

    Held in one module because both are single facts spread across surfaces:
    the name reaches the request header, the credential filename, and the
    command an operator is told to run, and the refusal sentence reaches the
    chat line, the roster line, and every JSON read. *)

val agent_name : string
(** The name this client authenticates under. Also the stem of the file
    [masc login] persists its bearer to. *)

val token_env_var : string
(** The environment variable that overrides the stored bearer. *)

val login_command : string
(** The command that mints and persists a bearer for {!agent_name}. *)

val self_mint_expiry_hours : int
(** How long a bearer this client mints for itself lasts. Longer than the
    workspace's operator-session window, which is a day and would refuse a
    session left running overnight; shorter than forever, which would leave an
    admin secret on disk that nothing retires. *)

type server_reason =
  | Expired  (** The bearer was known and has expired. *)
  | Insufficient_role
      (** The bearer was accepted but its role does not reach this route. *)
  | Rejected  (** Any other refusal, including one whose body names no code. *)

val server_reason_of_body : string -> server_reason
(** The server's reason, read from the [auth_error_code] of a 401/403 body and
    compared against the codes the server writes ({!Masc_error}). A body that
    is not JSON, or carries no code this client acts on, is {!Rejected}. *)

val refusal_cause : credential_sent:bool -> server_reason -> string
(** Why the server refused, as a lowercase clause a caller can place in its own
    sentence. [credential_sent] is whether the request carried a bearer at all:
    without one the operator has none to present and the reason is not
    consulted; with one, the clause says what the server found wrong with it. *)

val remedy : string
(** The action that clears any of these refusals, as a lowercase clause. *)

val refusal : credential_sent:bool -> server_reason -> string
(** {!refusal_cause} and {!remedy} as one clause, for callers with no context
    of their own to add. *)

(** {1 Where the bearer comes from} *)

type plan =
  | Use of string
      (** A bearer is already available. *)
  | Mint
      (** The workspace is here, demands a bearer, and this client has none. *)
  | Go_without
      (** The workspace admits requests without one. *)
  | No_workspace
      (** There is no workspace at this base path to mint into. *)

val plan :
  env_token:string option ->
  workspace_token:string option ->
  workspace_requires_token:bool ->
  workspace_initialized:bool ->
  plan
(** Which bearer to carry, from three facts and nothing else. The environment
    wins so one run can be pointed at a different credential; the file
    [masc login] wrote is next. With neither, a workspace that demands a bearer
    gets one minted, and a workspace that does not is left alone -- minting
    there would add a durable secret nobody asked for and would not be needed
    to reach anything. *)

type outcome =
  | Held
  | Minted
  | Not_required
  | Workspace_pending
      (** This base path holds no workspace to mint into. A server answering
          here makes one, so this client takes the decision again rather than
          asking the operator for anything. *)
  | Mint_failed of string
      (** The workspace is here and would not take a credential. The mint is
          local file work, so this does not clear itself. *)

val outcome_notice : outcome -> string option
(** What to tell the operator, or [None] when there is nothing worth saying.
    A fresh mint is worth saying: a server already running rebuilds its
    credential index on a timer, so the first reads after one can still be
    refused, and an operator who is not told will read that as a broken
    credential. {!Workspace_pending} says what is missing and that this client
    takes it again; it carries no command, because on a first install the
    state clears itself within a second or two and a command offered there
    teaches the operator to distrust the line. Only {!Mint_failed} names
    {!remedy}. *)

val outcome_needs_retry : outcome -> bool
(** Whether the decision is worth taking again once a server answers at this
    base path. True only for {!Workspace_pending}: minting is gated on a
    workspace that already exists, and on a first install this client runs
    before any server has made one, so the boot decision is taken against an
    empty base path. The other outcomes are settled -- a later workspace does
    not change a bearer already held, already minted, not required, or a mint
    that failed against a workspace that was already there. *)

val outcome_level : outcome -> string
(** How loudly {!outcome_notice} is said, as the event level the caller logs it
    under. Only {!Mint_failed} is an "error": it is a fault the operator has to
    act on. A first install's {!Workspace_pending} is the ordinary path one step
    earlier and reads as "system", as do a held, minted, or not-required
    bearer. Reporting the pending workspace as an error made a working first
    start read as a broken one. *)
