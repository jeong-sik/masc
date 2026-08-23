(** What this client is called, and what it says when the server refuses it.

    Held in one module because both are single facts spread across surfaces:
    the name reaches the request header, the credential filename, and the
    command an operator is told to run, and the refusal sentence reaches the
    chat line, the roster line, and every JSON read. *)

val agent_name : string
(** The name this client authenticates under. Also the stem of the file
    [masc login] persists its bearer to. *)

val login_command : string
(** The command that mints and persists a bearer for {!agent_name}. *)

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
