(** Planning_eio — task PDCA planning module (Plan / Do / Check / Act).

    Per-task planning context persisted as Markdown under
    \[<masc_dir>/planning/<task_id>/\] with PDCA-section structure:

    - Plan: task_plan (current goal).
    - Do: notes (observations / progress).
    - Check: errors (failures with resolved flag).
    - Act: deliverable (final output).

    Pure synchronous module — no Eio scheduling primitives despite
    the [_eio] suffix.  All operations return
    [(planning_context, string) result] for fail-loud propagation.

    Internal: filesystem helpers ([ensure_dir],
    [read_file_content], [write_file_content]), text helpers
    ([find_substring_from], [normalize_placeholder],
    [extract_markdown_section]), markdown parser
    ([parsed_full_context] type + [parse_full_context_markdown]),
    [now_iso] timestamp helper, [planning_dir] /
    [current_task_file] path builders, [format_error_entry]
    renderer.  All consumed only inside this module. *)

(** {1 Types} *)

type error_entry = {
  timestamp : string;
  error_type : string;
  message : string;
  context : string option;  [@default None]
  resolved : bool;
}
[@@deriving yojson]

type planning_context = {
  task_id : string;
  task_plan : string;
  notes : string list;  [@default []]
  errors : error_entry list;  [@default []]
  deliverable : string;  [@default ""]
  created_at : string;
  updated_at : string;
}
[@@deriving yojson]

(** {1 Construction} *)

val create_context : task_id:string -> planning_context
(** [create_context ~task_id] returns a fresh empty context with
    [created_at = updated_at = now_iso ()] and all fields empty. *)

(** {1 Lifecycle (return updated context on success)} *)

val init :
  Coord.config -> task_id:string -> (planning_context, string) result
(** [init config ~task_id] creates the planning directory and an
    empty Markdown skeleton.  Returns [Error _] when the directory
    already has content. *)

val load :
  Coord.config -> task_id:string -> (planning_context, string) result
(** [load config ~task_id] reads the persisted planning markdown
    and parses sections via the internal markdown parser.  Returns
    [Error _] when the directory does not exist or the markdown
    is malformed. *)

val update_plan :
  Coord.config ->
  task_id:string ->
  content:string ->
  (planning_context, string) result
(** [update_plan config ~task_id ~content] replaces the [task_plan]
    field and refreshes [updated_at]. *)

val add_note :
  Coord.config ->
  task_id:string ->
  note:string ->
  (planning_context, string) result
(** [add_note config ~task_id ~note] appends [note] to the
    [notes] list and refreshes [updated_at]. *)

val add_error :
  Coord.config ->
  task_id:string ->
  error_type:string ->
  message:string ->
  ?context:string ->
  unit ->
  (planning_context, string) result
(** [add_error config ~task_id ~error_type ~message ?context ()]
    appends a new {!error_entry} with [resolved = false]. *)

val resolve_error :
  Coord.config ->
  task_id:string ->
  index:int ->
  (planning_context, string) result
(** [resolve_error config ~task_id ~index] flips the [resolved]
    flag of the error at the given list index.  Returns [Error _]
    when the index is out of range. *)

val set_deliverable :
  Coord.config ->
  task_id:string ->
  content:string ->
  (planning_context, string) result
(** [set_deliverable config ~task_id ~content] writes the final
    deliverable string. *)

(** {1 Current task tracking}

    The "current task" is a process-local hint stored at
    [current_task_file config].  Used by the dashboard / CLI to
    show which task the operator is focused on. *)

val get_current_task : Coord.config -> string option
(** [get_current_task config] returns the persisted current task
    id, or [None] when no current task is set. *)

val set_current_task : Coord.config -> task_id:string -> unit
(** [set_current_task config ~task_id] persists the current task
    id.  Side effect only — no return value. *)

val clear_current_task : Coord.config -> unit
(** [clear_current_task config] removes the persisted current task
    file. *)

val resolve_task_id :
  Coord.config -> task_id:string -> (string, string) result
(** [resolve_task_id config ~task_id] returns the canonical task
    id.  Empty input falls back to {!get_current_task}; returns
    [Error _] when neither yields a task id. *)

(** {1 Rendering} *)

val get_context_markdown : planning_context -> string
(** [get_context_markdown ctx] renders [ctx] as the Markdown
    document that round-trips through {!load}.  Sections in PDCA
    order with the canonical headings expected by the parser. *)

(** {1 Test-visible helpers}
    Pinned for behaviour-tests under {!test/test_planning_eio}. *)

val find_substring_from :
  string -> needle:string -> from:int -> int option
(** [find_substring_from haystack ~needle ~from] returns
    [Some i] for the first occurrence of [needle] at offset
    [i >= from] in [haystack], or [None] when not found.  Returns
    [None] when [from] exceeds [String.length haystack]. *)
