(** The Context inspector's async answers and how each changes the pane.
    These functions perform no terminal or network IO. *)

(** [Masc_tui_async_protocol.async_msg] carries these in [Context_msg]. *)
type msg =
  | Context_inspector_loaded of
      int * string * Masc_tui_context_inspector.reading
      (** The pane's read generation, the Keeper it reads, and the reading. *)
  | Context_inspector_part_loaded of
      Masc_tui_context_inspector.part_key Masc_tui_fetched.request
      * (string, string) result
      (** One part of the provider input the pane shows. *)

(** The protocol and the loop decide by kind, not by answer: whether an answer
    is a read, whether it waits for input, whether it carries an operation
    receipt, what is left to clean up when its workspace has changed, and
    whether it is stamped with the workspace that asked. A new answer that
    takes an existing kind takes all of that kind's decisions without a
    compile error. An answer that needs another decision adds a kind, and
    then each match on the kind stops compiling until it decides. *)
type answer_kind =
  | Read  (** Reads the workspace that asked, and is stamped with it. *)

val answer_kind : msg -> answer_kind

val apply : Masc_tui_types.state -> msg -> unit
(** Apply one answer to the pane. An answer for a read the pane has moved past
    changes nothing. *)
