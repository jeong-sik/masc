(** The reply text one Keeper chat operation's journal holds, rebuilt for the
    failure row of a reply that was cut (steer or Ctrl+X) while it streamed.

    The text follows the fold the server's channel connectors apply to the
    same events when they turn them into a channel message
    (lib/keeper/keeper_chat_discord.ml, lib/keeper/keeper_chat_slack.ml):
    - [run_started] starts the text over, with fresh ownership;
    - [agent_core_runtime_attempt_started] retires the admitted response and
      starts the text over;
    - [text_delta] is appended unless its response was superseded, under
      the rules of lib/keeper/keeper_chat_response_ownership.ml;
    - [run_finished] and [event_error] end the reply, and nothing after them
      is read;
    - every other event leaves the text as it is. *)

open Masc_tui_core
open Masc_tui_protocol

type ownership
(** Live and journal response-ownership state mirroring
    [Keeper_chat_response_ownership.t]. *)

val fresh_ownership : ownership

type admission =
  | Append of ownership
  | Drop  (** The bytes of a superseded response. *)

val admit : ownership -> Wire_chat_journal.text_owner -> admission
val retire_attempt : ownership -> ownership

type t

val max_pages : int
(** Maximum journal pages read for a single cut reply ([100]) before failing
    with {!Page_limit_exceeded}. *)

type page_error =
  | Cursor_did_not_advance of {
      previous : Wire_chat_journal.from;
      next : Wire_chat_journal.cursor;
    }
  | Page_limit_exceeded of { max_pages : int }

val page_error_to_string : page_error -> string

val start : t
(** Nothing read yet. *)

val no_journal : t
(** The server keeps no journal for the operation: nothing to show and
    nothing to ask. *)

val apply_page_checked : Wire_chat_journal.page -> t -> (t, page_error) result
(** Fold the page's events, rejecting a repeated/non-advancing [next] cursor or
    more than {!max_pages} pages so a broken server cannot loop HTTP requests
    forever. A reply that already ended returns [Ok t]. *)

val apply_page : Wire_chat_journal.page -> t -> t
(** Fold the page's events. A reply that already ended ignores the page; a
    non-advancing cursor or page-cap breach stops reading. *)

val next_page : t -> Wire_chat_journal.from option
(** The page to read next, [None] once the reply ended or the journal's
    last page was read. *)

val pending_page : t Observed.t -> Wire_chat_journal.from option
(** The page a slot waits for: the journal's start while the slot holds no
    value, {!next_page} of the value otherwise. *)

val text : t -> string option
(** The rebuilt text, once reading ended and when it is not empty. *)
