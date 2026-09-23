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
      (** The bearer was accepted but is not allowed to make this request.
          Usually its role, though the server sends the same code for every
          Forbidden. *)
  | Rejected  (** Any other refusal, including one whose body names no code. *)

val server_reason_of_body : string -> server_reason
(** The server's reason, read from the [auth_error_code] of a 401/403 body --
    at the top of a REST body, or under [error.data] of a JSON-RPC one -- and
    decoded with [Masc_error.Auth_error_code.of_string]. A body that is not
    JSON, or carries no code this client acts on, is {!Rejected}. *)

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

type stored_token =
  | Stored of string
      (** A bearer [masc login] persisted that the workspace has not ruled
          expired. Any other objection is the server's to make, and its
          refusal names the remedy. *)
  | Stored_expired
      (** A bearer was persisted and its credential record says it has
          expired. Carrying it would be refused on every read. *)
  | Stored_mismatched
      (** A bearer was persisted but its hash is not the one the credential
          record holds. The record moved on without the file. *)
  | Not_stored
      (** Nothing was persisted for this client. *)

type mint_reason =
  | First_token  (** This client held no bearer at all. *)
  | Replaces_expired  (** The bearer it held had expired. *)
  | Replaces_mismatched
      (** The stored bearer no longer matched its credential record: a mint
          that failed between its two writes, or another masc-tui's mint. *)

type plan =
  | Use of string
      (** A bearer is already available. *)
  | Mint of mint_reason
      (** The workspace is here, demands a bearer, and this client has none
          it can use. *)
  | Go_without
      (** The workspace admits requests without one. *)
  | No_workspace
      (** There is no workspace at this base path to mint into. *)

val plan :
  env_token:string option ->
  workspace_token:stored_token ->
  workspace_requires_token:bool ->
  workspace_initialized:bool ->
  plan
(** Which bearer to carry, from three facts and nothing else. The environment
    wins so one run can be pointed at a different credential; the file
    [masc login] wrote is next, unless it has expired. With no usable bearer, a
    workspace that demands one gets one minted, and a workspace that does not is left alone -- minting
    there would add a durable secret nobody asked for and would not be needed
    to reach anything. *)

type token_source =
  | From_environment  (** [MASC_TOKEN]: the operator's choice for this run. *)
  | From_workspace  (** The file [masc login] or a self-mint wrote. *)

type refresh =
  | Adopt of string
      (** The workspace holds a different bearer that verifies. *)
  | Remint of mint_reason
      (** The workspace holds nothing usable and this client may mint. *)
  | Keep_held
      (** Nothing this client can change: an environment bearer, or the
          workspace still holds the one the server refused. *)

val refresh_plan :
  source:token_source ->
  sent:string ->
  stored:stored_token ->
  workspace_requires_token:bool ->
  workspace_initialized:bool ->
  refresh
(** What to do after the server refused the bearer [sent]. A different bearer
    in the workspace was minted by another masc-tui and is adopted rather than
    minted over, so two clients converge on one bearer instead of refusing
    each other's. *)

type outcome =
  | Held
  | Minted of mint_reason
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
