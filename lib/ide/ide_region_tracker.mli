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

val regions_file
  :  base_dir:string
  -> codebase:string
  -> unit
  -> string
(** Append-only region store path under the codebase's store directory. *)

val append_region
  :  base_dir:string
  -> codebase:string
  -> code_region
  -> unit
(** Append one region to the codebase's [regions.jsonl]. *)

val ingest_tool_call
  :  base_dir:string
  -> codebase:string
  -> keeper_id:string
  -> turn:int
  -> Yojson.Safe.t
  -> unit
(** Inspect a tool_call JSON record. If it is a file-writing tool,
    extract regions and append them to the codebase's
    [regions.jsonl]. Non-matching tool_calls are silently ignored. *)

val read_regions
  :  base_dir:string
  -> codebase:string
  -> ?file_path:string
  -> unit
  -> code_region list
(** Read regions from the codebase's store.

    [?file_path] filters by [file_path] field; when omitted every
    region is returned. Streaming-friendly: lines whose JSON does not
    parse as a {!code_region} are silently skipped (matches the
    forgiving semantics of the existing HTTP route). *)
