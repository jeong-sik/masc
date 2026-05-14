(** IDE region tracker — extract code regions from Keeper tool_calls.

    Parses [write_file], [edit_file], and [apply_patch] tool_call
    arguments into line-range records.  A region represents the set of
    lines a Keeper touched in a single tool invocation.

    Regions are stored in [.masc-ide/regions.jsonl] and surfaced by
    the IDE as overlay hints (who owns this code?). *)

open Ide_annotation_types

val parse_hunk_header : string -> int option
(** [parse_hunk_header line] extracts start_line from a
    unified diff hunk header like [@@ -1,5 +2,7 @@].  Returns [None]
    if the line does not match the hunk pattern. *)

val extract_regions_from_diff :
  keeper_id:string ->
  file_path:string ->
  turn:int ->
  diff_text:string ->
  code_region list
(** Parse unified diff text into one [code_region] per hunk.
    [turn] is the keeper turn number for provenance. *)

val extract_region_from_full_file :
  keeper_id:string ->
  file_path:string ->
  turn:int ->
  content:string ->
  code_region
(** When a Keeper uses [write_file] with full content, the region is
    the entire file (lines 1 to line count of [content]). *)

val ingest_tool_call :
  base_dir:string -> keeper_id:string -> turn:int -> Yojson.Safe.t -> unit
(** Inspect a tool_call JSON record.  If it is a file-writing tool,
    extract regions and append them to [.masc-ide/regions.jsonl].
    Non-matching tool_calls are silently ignored. *)
