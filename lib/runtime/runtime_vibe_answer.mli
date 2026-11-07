(** Runtime_vibe_answer — the reply a finished Vibe run gave.

    A one-shot caller (a Fusion panelist, [masc lane-cli-probe]) asks one
    question and reads one answer. This module takes that answer from a
    {!Runtime_vibe_cli.run}: the text of the transcript's last entry, when
    [export.json] says the run [finished] and that entry is an assistant
    message. Every retained finished run (m0, m6-m8, m10-m14) ends that way.
    Pure; it reads the decoded run and spawns nothing. *)

(** Each {!Runtime_vibe_headless.outcome} except [finished]. *)
type stop =
  | Usage_error
  | Config_error
  | Infrastructure_failure
  | Turn_limit
  | Token_limit
  | Price_limit
  | Deadline
  | Terminated
  | Length
  | Refusal
  | Aborted
  | Unrecognized_outcome of string

val outcome_of_stop : stop -> Runtime_vibe_headless.outcome

type error =
  | Not_finished of
      { stop : stop
      ; run_error : Runtime_vibe_headless.run_error option
      }
      (** Vibe stopped without finishing. A limit counts here even when the
          transcript holds a reply (m7 stopped at [token_limit] after one). *)
  | No_output  (** [finished] with an empty stdout. *)
  | No_assistant_reply
      (** The transcript does not end in an assistant message with content:
          it is empty, or its last entry is a user message, reasoning, an
          effect, or an assistant message with no parts. An earlier
          assistant message is not taken for the reply. *)
  | Unrecognized_last_role of string
      (** The last entry is a message whose role the decoder does not know. *)
  | Unrecognized_last_entry of string
      (** The last entry has a kind the decoder does not know. *)
  | Unrecognized_reply_part of string
      (** The reply holds a part the decoder does not know; its text is not
          dropped silently. *)

val error_to_string : error -> string

val of_run : Runtime_vibe_cli.run -> (string, error) result
(** The text parts of the last entry, joined in order. *)
