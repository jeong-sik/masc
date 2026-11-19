(** How often a schedule wakes, in the words of the screen's language (RFC
    tui-one-screen-grammar §6.1, §6.2). *)

val text :
  ko:bool ->
  now:float ->
  summary:string ->
  (Schedule_domain.recurrence, string) result ->
  string
(** [한 번] / [once]; [매 5m] / [every 5m] with the interval as
    {!Masc_tui_value.Interval.text} gives it; [매일 23:55] / [daily 23:55] at
    the operator's clock on the day of [now]; a cron recurrence in its own
    notation. A recurrence this build could not read, or a daily one whose
    timezone the domain does not accept, keeps the server's [summary]. *)
