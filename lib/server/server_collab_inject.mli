(** Guest injection for collab host sessions (RFC-0471 stack 4).

    Control guests steer the shared keeper through the same durable paths
    every other surface uses: prompts enter the Owner FIFO via
    {!Keeper_owner_registry.submit_operation} (built exactly like
    {!Gate_keeper_backend.dispatch} builds them — Gate surface, external
    speaker, [Needs_append] user row), aborts name the session's latest
    observed operation through the mailbox-linearized interrupt, and
    transcript fetches page the chat store.

    This module never settles approvals: no path here reaches
    {!Keeper_approval_queue.resolve_with_policy} or the tool approval gate.
    A guest prompt that trips an approval parks the keeper turn until the
    host settles it on a host surface; guests watch that wait through the
    live [Tool_approval_requested] event like any other turn event. (v1
    rule, RFC-0471 §2.6.)

    Read-only enforcement lives in {!Server_collab_host} (it owns the
    per-peer capability table); every function here assumes an authorized
    caller. *)

type prompt_error =
  | Prompt_empty
  | Prompt_too_large of int
  (** Carries the trimmed prompt size in bytes. *)
  | Prompt_continuation_failed of string
  | Prompt_submit_failed of string

val max_prompt_bytes : int
(** [65536]. Trimmed prompts past this size are rejected before they
    reach the Owner queue: one guest must not wedge a keeper turn with a
    megabyte paste. *)

val prompt_error_to_string : prompt_error -> string

val submit_prompt
  :  base_dir:string
  -> keeper:string
  -> room:string
  -> peer:int
  -> label:string option
  -> text:string
  -> (string, prompt_error) result
(** [submit_prompt ~base_dir ~keeper ~room ~peer ~label ~text] queues one
    guest prompt as a durable chat operation and returns its operation id.
    [room] is the raw 16-byte room id (encoded into the channel workspace
    and surface address here); [peer] names the guest speaker
    ([guest-<peer>], [label] as display name when given). Runs on the
    caller's fiber like the chat-stream submit path. *)

type abort_outcome =
  | Aborted of string
  (** The named operation was signalled; carries its id. *)
  | Nothing_running
  (** No operation to stop: none tracked, already terminal, or settling. *)
  | Abort_failed of string

val abort_current
  :  base_dir:string
  -> keeper:string
  -> latest_op:string option
  -> abort_outcome
(** [abort_current ~base_dir ~keeper ~latest_op] interrupts the session's
    latest observed operation by exact id, so a stale abort can never
    cancel its successor. [None] (the session has seen no operation) is
    [Nothing_running], never a blind whole-keeper interrupt. *)

type transcript = {
  text : string;
  total_bytes : int;
  capped : bool;
}

val max_fetch_bytes : int
(** [1048576]. Guest [max_bytes] clamps into [[0; max_fetch_bytes]];
    [0] probes the size ([text] empty, [total_bytes] exact). *)

val fetch_transcript : base_dir:string -> keeper:string -> max_bytes:int -> transcript
(** [fetch_transcript ~base_dir ~keeper ~max_bytes] renders the keeper's
    newest chat-store tail window as scrollback text ([ROLE[name]:
    content] lines, oldest first) and returns its newest [max_bytes]:
    from a line boundary when the window holds a newline, else a hard
    byte cut retreated to a UTF-8 scalar boundary (a budget smaller than
    one line cannot align and still fit). [total_bytes] is the full
    rendered size of the walked window; [capped] reports older history
    exists past the window, so the caller can say the transcript
    continues past what came back. Needs an Eio context (the store read
    runs in a systhread). *)

type injector = {
  submit_prompt :
    base_dir:string
    -> keeper:string
    -> room:string
    -> peer:int
    -> label:string option
    -> text:string
    -> (string, prompt_error) result;
  abort_current :
    base_dir:string -> keeper:string -> latest_op:string option -> abort_outcome;
  fetch_transcript : base_dir:string -> keeper:string -> max_bytes:int -> transcript;
}
(** The three injection entries as a record so tests stub the keeper
    registry without one. *)

val default_injector : injector
(** The production injector: {!submit_prompt}, {!abort_current},
    {!fetch_transcript}. *)
