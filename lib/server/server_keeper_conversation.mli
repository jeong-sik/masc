(* HIGH-RISK-UNREVIEWED: this store holds what a person asked their Keeper and
   what it answered, and it names the vendor session the next turn resumes. A
   wrong path reads the conversation of another person or resumes it. Read it
   against plan S1b-3. *)

(** The record of a person's conversations with their own Keepers (plan
    S1b-3).

    {b Where.} [<.masc>/accounts/<namespace>/keeper-conversations/], under the
    runtime root of the person, beside the homes of their accounts. A
    conversation is one directory, named by an id this module draws. A Keeper
    name makes no path.
    - [index.jsonl] has one [started] row per conversation: its id, the
      Keeper, the account it began on, and when. It holds no text.
    - [<conversation_id>/turns.jsonl] has the rows of the turns: [asked] with
      the message, then [answered] with the text, the model and the vendor
      session, or [failed] with the kind of the failure. A turn with only
      [asked] is one the server stopped in.
    - [<conversation_id>/cwd/] is the directory every turn of the
      conversation starts its client in.

    {b The conversation of a Keeper} is the one its last [started] row names.
    Nothing else stores it.

    {b Reading.} A row that is not one of these, with exactly its fields, is
    not repaired or skipped: the read is refused, and so is the turn. There
    is one format of the rows. A change of it is a hard cut: the records are
    removed with it, and a binary from before the change refuses the turns of
    a conversation that has a row of the new format.

    {b The session of a conversation} is the one its last [answered] row
    names. A [failed] row names none and changes none, so the turn after a
    failed one resumes the same session. Nothing tells a session the vendor
    no longer has from another turn without an answer, so this module starts
    no session in place of one: the person starts a new conversation
    ({!start}), and its first turn starts a session of its own.

    {b An answer that was not recorded.} When the [answered] row of a turn
    is not written, the turn keeps its [asked] row alone, the caller does not
    give the answer out, and the next turn resumes the session of the
    [answered] row before it. The vendor session holds that turn though the
    record has no end of it.

    {b Directories} are made with mode 0700. One that is already there is
    used only when it is a directory of that mode: a file, a link or another
    mode refuses the turn.

    {b Writing.} Rows are appended with
    {!Fs_compat.append_private_jsonl_durable_stable_result}. One lock of the
    process orders reading the index and starting a conversation. The rows of
    one conversation are ordered by the caller, which runs one call of an
    account at a time, and a conversation stays on the account it began on. *)

(** The type that a purge record of the authorization log names a
    conversation by (plan S1b-3c). *)
module Conversation_id = Authz_types.Conversation_id

(** The directory of the conversations of one person. *)
type root

(** It reads and makes nothing. *)
val root
  :  base_path:string
  -> namespace:Authz_types.Account_home_namespace.t
  -> root

type conversation =
  { conversation_id : Conversation_id.t
  ; provider_account_id : Authz_types.Provider_account_id.t
      (** The account the conversation began on. The vendor session lies in
          the home of this account, so no other account continues it. *)
  }

(** Why a turn that started its client has no answer, as the person was told.
    It names no path and no detail of the client. *)
type failure =
  | Not_signed_in
  | No_quota
  | Silent
  | Not_started
  | Configuration_refused
  | No_answer

(** The name of the failure, as the record spells it. *)
val failure_to_string : failure -> string

(** Whether the client of a failed turn was started with the message, so the
    vendor session may hold it though the record has no answer. *)
val reached_client : failure -> bool

type file =
  | Index
  | Turns

type error =
  | Not_written of string
      (** A directory was not made or a row was not appended. The detail can
          name a path of the server. *)
  | Not_read of string  (** The detail can name a path of the server. *)
  | Row_not_understood of
      { file : file
      ; row : int  (** Counted from 1. *)
      }
  | Id_not_drawn of Authz_id.error

(** For the log of the server: it can name a path. *)
val error_to_string : error -> string

(** Why a new conversation was not started. *)
type start_error =
  | Account_busy  (** A call of the account of the conversation it follows runs. *)
  | Record_failed of error

(** Start a conversation of the Keeper on the account. The conversations it
    had stay as they are. [draw] gives the id, and [now_ms] the time of the
    row.

    The conversation it follows gets no turn after it, so the start is the
    last writer of its file. Each turn of that conversation runs inside the
    call of its account, and so does the start. [one_call_of account ~busy f]
    runs [f] when no other call of [account] runs and gives [busy] otherwise,
    as {!Server_setup_account_login.one_call_of} does. Inside the call, a row
    a stopped server left half written in that conversation is cut, as its
    next turn would have cut it, and the [started] row of the new one is
    appended. The first conversation of a Keeper follows none and takes no
    call. *)
val start
  :  root
  -> Authz_types.Keeper_id.t
  -> Authz_types.Provider_account_id.t
  -> draw:(unit -> string)
  -> now_ms:(unit -> int)
  -> one_call_of:
       (Authz_types.Provider_account_id.t
        -> busy:start_error
        -> (unit -> (conversation, start_error) result)
        -> (conversation, start_error) result)
  -> (conversation, start_error) result

(** The conversation of the Keeper. A Keeper that has none starts one on the
    account, as {!start} does. The conversation of a Keeper that has one is
    answered whatever account it began on: the caller compares it. *)
val current_or_start
  :  root
  -> Authz_types.Keeper_id.t
  -> Authz_types.Provider_account_id.t
  -> draw:(unit -> string)
  -> now_ms:(unit -> int)
  -> (conversation, error) result

type listed =
  { conversation : conversation
  ; started_at_ms : int
  }

(** The conversations of the Keeper, in the order they were started. The last
    is the one its turns go on in. It reads the index alone and writes
    nothing, and a person with no record has none. A row a stopped server
    left half written refuses the read ([Not_read]) until a turn or a new
    conversation of the person cuts it. *)
val conversations : root -> Authz_types.Keeper_id.t -> (listed list, error) result

type outcome =
  | Answered of
      { text : string
      ; model : string
      ; session_id : string  (** The vendor session the turn ran in. *)
      ; at_ms : int
      }
  | Failed of
      { failure : failure
      ; at_ms : int
      }
  | Unrecorded
      (** The turn has its [asked] row alone: the server stopped in the
          turn, or the row of its end was not written. *)

type recorded =
  { message : string
  ; asked_at_ms : int
  ; outcome : outcome
  }

(** The turns of the conversation in order. An [answered] or a [failed] row
    that does not close the turn of the [asked] row before it is a row that
    is not understood. It writes nothing. A row a stopped server left half
    written refuses the read ([Not_read]) until the next turn of the
    conversation, or the {!start} of the one after it, cuts the row. *)
val turns : root -> conversation -> (recorded list, error) result

(** A conversation opened for one turn. *)
type turn

(** Read the turns of the conversation and make its directories. It writes no
    row. *)
val open_turn : root -> conversation -> (turn, error) result

(** The real path of the directory the client of the turn starts in. *)
val cwd : turn -> string

(** The vendor session of the last answered turn of the conversation. [None]
    is a conversation with no answered turn: its first turn, or one whose
    turns all failed. *)
val session_id : turn -> string option

(** A turn whose [asked] row is written. *)
type asked

(** Append the [asked] row of the turn. An error means the row was not
    written, and the caller starts no client. *)
val ask
  :  turn
  -> message:string
  -> draw:(unit -> string)
  -> now_ms:(unit -> int)
  -> (asked, error) result

val answered
  :  asked
  -> text:string
  -> model:string
  -> session_id:string
  -> now_ms:(unit -> int)
  -> (unit, error) result

val failed : asked -> failure -> now_ms:(unit -> int) -> (unit, error) result
