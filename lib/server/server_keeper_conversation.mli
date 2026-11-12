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
    not repaired or skipped: the read is refused, and so is the turn.

    {b Writing.} Rows are appended with
    {!Fs_compat.append_private_jsonl_durable_stable_result}. One lock of the
    process orders reading the index and starting a conversation. The rows of
    one conversation are ordered by the caller, which runs one call of an
    account at a time, and a conversation stays on the account it began on. *)

module Conversation_id : Authz_id.S

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

(** Start a conversation of the Keeper on the account. The conversations it
    had stay as they are. [draw] gives the id, and [now_ms] the time of the
    row. *)
val start
  :  root
  -> Authz_types.Keeper_id.t
  -> Authz_types.Provider_account_id.t
  -> draw:(unit -> string)
  -> now_ms:(unit -> int)
  -> (conversation, error) result

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
