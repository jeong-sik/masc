(** The Tools surface's storage reading: the host disk as the server measured
    it, the server's last cleanup pass, and each Keeper's last cleanup
    attempt.

    It only reads. Nothing here asks the server to clean, and no number is
    judged against a limit.

    The cleanup results live in the server's memory since its last start, so
    the pane says how long the server has been up beside them: a step that
    has failed for two days reads as "failed since the start" after every
    restart. *)

type tone =
  | Heading
  | Plain
  | Dim
  | Warn
  | Bad

(** The rows that ask for a look, then the others.

    A failed attempt comes before one that ran to its end and left entries
    behind ({!Masc.Keeper_cleanup_status.concern}). Within each of the two,
    and among the others, rows are in Keeper name order and then in the
    order of the step list. *)
val arrange :
  Masc.Keeper_cleanup_status.row list ->
  Masc.Keeper_cleanup_status.row list * Masc.Keeper_cleanup_status.row list

(** The pane's lines. [uptime] is the server's own text for how long it has
    been up, and [timestamp] draws a Unix time. Text from the server is made
    single-line for the terminal. *)
val lines :
  timestamp:(float -> string) ->
  uptime:string option ->
  Masc.Tui_decode_tools.storage ->
  (tone * string) list
