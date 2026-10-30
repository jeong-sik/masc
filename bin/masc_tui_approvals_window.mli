(** The Approvals queue's window: which rows it draws and what its line says. *)

val overflows : body_rows:int -> total:int -> bool
(** A queue longer than the rows it has, with a row to spare for the line that
    says which rows are drawn. *)

val hides_rows : body_rows:int -> total:int -> bool
(** Some rows are not drawn, whether or not there is a row for the line. *)

val rows : body_rows:int -> total:int -> int
(** The rows the queue's window draws: [body_rows], less the one the window
    line takes when it is drawn. *)

val note : scroll:int -> height:int -> total:int -> string
(** The window line: the rows drawn over the total, and how many lie each way. *)
