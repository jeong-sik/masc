(** Task-detail lookup for the Overview surface. Pure over its arguments so
    the detail view's fallback contract stays testable without the TUI
    executable's state record. *)

val detail_row :
  detail_id:string option ->
  tasks:Masc_domain.task list ->
  Masc_domain.task option
