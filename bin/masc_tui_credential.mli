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

val refusal_cause : credential_sent:bool -> string
(** Why the server refused, as a lowercase clause a caller can place in its own
    sentence. [credential_sent] is whether the request carried a bearer at all:
    without one the operator has none to present, with one the server rejected
    what it was given. Only the first is fixed by providing a token. *)

val remedy : string
(** The action that clears either refusal, as a lowercase clause. *)

val refusal : credential_sent:bool -> string
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
  | Unavailable of string  (** Why no bearer could be obtained. *)

val no_workspace_detail : string
(** The [Unavailable] detail for a base path with no workspace in it. *)

val outcome_notice : outcome -> string option
(** What to tell the operator, or [None] when there is nothing worth saying.
    A fresh mint is worth saying: a server already running rebuilds its
    credential index on a timer, so the first reads after one can still be
    refused, and an operator who is not told will read that as a broken
    credential. *)
