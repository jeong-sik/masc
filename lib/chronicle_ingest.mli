(** Chronicle_ingest — git log → candidate epoch pipeline.
    @since Project Chronicle Phase 2 *)

(** Git capture hook for test isolation. *)
type git_capture_hook =
  workdir:string -> string list -> (Unix.process_status * string) option

val set_git_capture_hook_for_tests : git_capture_hook -> unit
val clear_git_capture_hook_for_tests : unit -> unit

(** A single commit parsed from git log output. *)
type commit_event =
  { sha : string
  ; parents : string list
  ; author_date : string
  ; subject : string
  ; files : string list
  }
[@@deriving show]

(** A candidate epoch produced by grouping commits. *)
type candidate_epoch =
  { id : string
  ; label : string
  ; start_commit : string
  ; end_commit : string
  ; start_date : string
  ; end_date : string
  ; file_paths : string list
  ; commit_count : int
  }
[@@deriving show]

(** Ingest a commit range and group into candidate epochs.

    @param time_window_days  days within which ungrouped commits
                             are clustered (default 7)
    @param workdir  git repository working directory
    @param from  start commit SHA (exclusive)
    @param to_  end commit SHA (inclusive) *)
val ingest_range :
  ?time_window_days:int ->
  workdir:string ->
  from:string ->
  to_:string ->
  unit ->
  candidate_epoch list

(** Ingest incrementally since the last indexed commit.

    Returns [[]] if [HEAD] equals [last_commit]. *)
val ingest_since :
  ?time_window_days:int ->
  workdir:string ->
  last_commit:string ->
  unit ->
  candidate_epoch list

(** Low-level: parse raw git log into commit events.

    Visible for testing. *)
val parse_git_log : string -> commit_event list

(** Group commit events into candidate epochs.

    Groups commits by the configured time window.

    Visible for testing. *)
val group_events :
  ?time_window_days:int ->
  commit_event list ->
  candidate_epoch list
