(** Original Task inspection's async answers and how each changes the
    inspection. These functions perform no terminal or network IO. *)

(** [Masc_tui_async_protocol.async_msg] carries these in [Original_msg]. *)
type msg =
  | Original_task_read_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.task_snapshot, Masc_tui_original_task_read.error) result
      (** The recorded Task the inspection reads. *)
  | Original_task_history_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.history_snapshot, Masc_tui_original_task_read.error) result
      (** One page of that Task's stored history. *)
  | Original_task_evidence_done of Masc_tui_types.task_inspection_request
      * (Masc_tui_original_task_read.evidence_snapshot, Masc_tui_original_task_read.error) result
      (** The evidence submitted for one verification of that Task. *)

(** The protocol and the loop decide by kind, not by answer: whether an answer
    is a read, whether it waits for input, whether it carries an operation
    receipt, and what is left to clean up when its workspace has changed. A
    new answer that takes an existing kind takes all of that kind's decisions
    without a compile error. An answer that needs another decision adds a
    kind, and then each match on the kind stops compiling until it decides.
    The kind does not choose the workspace stamp. Every Original read is sent
    through a launcher that stamps its answer with the workspace that asked,
    so an answer that must go unstamped needs another way to be sent. *)
type answer_kind =
  | Read  (** Reads the workspace that asked, and is stamped with it. *)

val answer_kind : msg -> answer_kind

val apply : Masc_tui_types.state -> msg -> unit
(** Apply one answer to the inspection that asked. An answer for a read the
    inspection no longer waits on changes nothing. An awaited answer lands
    only while the workspace authority and read authority it was asked under
    are still the state's, its inspector is still the current one, and the
    read is still the source's current read. Otherwise it does not land, and
    every read of that inspection is suspended. *)
