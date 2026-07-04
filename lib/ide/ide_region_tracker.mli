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
  tool_name:string ->
  diff_text:string ->
  code_region list
(** Parse unified diff text into one [code_region] per hunk.
    [turn] and [tool_name] preserve the tool-call provenance. *)

val extract_region_from_full_file :
  keeper_id:string ->
  file_path:string ->
  turn:int ->
  tool_name:string ->
  content:string ->
  code_region
(** When a Keeper provides full content, the region is the entire file
    (lines 1 to line count of [content]) while preserving the original
    tool-call provenance. *)

val regions_file
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> unit
  -> string
(** Append-only region store path under the chosen
    {!Ide_paths.partition}. Default [partition] is
    {!Ide_paths.Legacy_default}. *)

val append_region
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> code_region
  -> unit
(** Append one region to the chosen partition's [regions.jsonl].
    Default [partition] is {!Ide_paths.Legacy_default}. *)

val ingest_tool_call
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> keeper_id:string
  -> turn:int
  -> Yojson.Safe.t
  -> unit
(** Inspect a tool_call JSON record. If it is a file-writing tool,
    extract regions and append them to the chosen partition's
    [regions.jsonl]. Non-matching tool_calls are silently ignored.
    Default [partition] is {!Ide_paths.Legacy_default}. *)

val read_regions
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> ?file_path:string
  -> unit
  -> code_region list
(** Read regions from the chosen partition.

    [?file_path] filters by [file_path] field; when omitted every
    region is returned. Streaming-friendly: lines whose JSON does not
    parse as a {!code_region} are silently skipped (matches the
    forgiving semantics of the existing HTTP route). *)
