(** Prompt_runtime_drift — compare live prompt config with the repo seed.

    The live runtime normally reads prompts from [<base>/.masc/config/prompts],
    while the versioned seed lives under the running MASC repo's
    [config/prompts].  This module makes that split visible to health and
    dashboard surfaces without changing prompt resolution precedence. *)

type file_status =
  | In_sync
  | Modified
  | Missing_runtime
  | Runtime_only

type file_drift =
  { key : string
  ; status : file_status
  ; runtime_path : string option
  ; repo_path : string option
  ; runtime_digest : string option
  ; repo_digest : string option
  }

type summary =
  { status : string
  ; runtime_prompt_dir : string
  ; repo_prompt_dir : string option
  ; repo_head_commit : string option
  ; repo_head_commit_source : string option
  ; runtime_file_count : int
  ; repo_file_count : int
  ; modified_count : int
  ; missing_runtime_count : int
  ; runtime_only_count : int
  ; checked_count : int
  ; drifts : file_drift list
  }

val summarize : ?limit:int -> unit -> summary
(** Build a bounded summary. [limit] caps the number of per-file drift rows
    retained in [drifts], not the aggregate counts. *)

val prompt_key_status_json : string -> Yojson.Safe.t
(** Per-prompt diagnostic for dashboard prompt blocks. *)

val to_yojson : summary -> Yojson.Safe.t
val warning_messages : summary -> string list
val log_if_drift : summary -> unit

val write_source_stamp : prompt_markdown_dir:string -> unit
(** Best-effort write of [.masc-prompt-source.json] into the live prompt dir,
    recording the running repo commit and current prompt digests. *)
