(** Runtime_vibe_answer — the reply a finished Vibe run gave.

    A one-shot caller (a Fusion panelist, [masc lane-cli-probe]) asks one
    question and reads one answer. This module takes that answer from a
    {!Runtime_vibe_cli.run}: the text of the last assistant message in the
    transcript, when [export.json] says the run [finished]. Pure; it reads
    the decoded run and spawns nothing. *)

type error =
  | Not_finished of
      { outcome : Runtime_vibe_headless.outcome
      ; run_error : Runtime_vibe_headless.run_error option
      }
      (** Vibe stopped without finishing. A limit counts here even when the
          transcript holds a reply (m7 stopped at [token_limit] after one). *)
  | No_output  (** [finished] with an empty stdout. *)
  | No_assistant_reply  (** No assistant message with text in the transcript. *)
  | Unrecognized_reply_part of string
      (** The last assistant message holds a part the decoder does not know;
          its text is not dropped silently. *)

val error_to_string : error -> string

val of_run : Runtime_vibe_cli.run -> (string, error) result
(** The text parts of the last assistant message, joined in order. *)
