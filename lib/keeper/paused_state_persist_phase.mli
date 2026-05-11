(** Paused_state_persist_phase — closed sum for the [phase] label on
    [metric_keeper_paused_state_persist_errors].

    Replaces 3 hardcoded string literals scattered across 6 emit sites
    in [server_dashboard_http_keeper_api.ml]
    (`"boot_resume_persist"` / `"boot_resume_check"` / `"directive"`).
    Each phase corresponds to a distinct write path; closing the set
    forces every emit site through the compiler. *)

type t =
  | Boot_resume_persist
  (** Persist-time failure during boot-time resume of a previously
          paused keeper (writing the resumed state record). *)
  | Boot_resume_check
  (** Read-back failure during boot-time resume (verifying the
          persisted state). *)
  | Directive
  (** Failure persisting an operator-issued pause/resume directive
          (e.g. POST /dashboard/api/keepers/:name/pause). *)

val to_label : t -> string
