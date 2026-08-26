(** Recorded file changes woven into Keeper chat tool details.

    The producer's canonical [execution_id] is the only join authority.
    Provider call ids, path, time, tool name, and list order are never used to
    recover a missing identity. The Changes surface and chat consume the same
    typed file-change projection, while keeping separate load caches. *)

type index

type prepared_change

type association =
  | No_recorded_change
  | Exact of prepared_change
  | Ambiguous of int

val empty : index

val index : Masc.Tui_decode.file_change list -> index
(** Prepare diff rows once per file-change snapshot and index them by nonblank
    canonical [execution_id]. Repeated ids remain ambiguous rather than being
    resolved by order or another correlation field. *)

val missing_execution_ids : index -> int
(** File-change rows the snapshot carried without a usable canonical identity.
    They cannot be joined and must make a surface report partial coverage. *)

val ambiguous_execution_ids : index -> int
(** Distinct canonical ids carried by more than one file-change row. No row in
    such a group is selected; the snapshot must report partial coverage. *)

val associate :
  index -> Masc_tui_keeper_chat_transcript.tool_activity -> association
(** Match [tool_activity.execution_id] to the canonical index. Missing ids and
    missing candidates answer [No_recorded_change]. *)

val rows :
  mode:Masc_tui_keeper_chat_transcript.tool_projection_mode ->
  max_line_cells:int ->
  index ->
  Masc_tui_keeper_chat_transcript.tool_projection ->
  string list
(** Add bounded recorded-change previews to an already-computed tool
    projection. Compact mode returns the producer projection unchanged. Full
    mode shows at most three previews per block and twelve source rows per
    preview; every source row is clipped to [max_line_cells]. Remaining
    annotations and source rows are counted explicitly.

    An [Edited] record is labelled as a replacement (or replace-all template),
    not a whole-file diff. A [Written] record is labelled as recorded body with
    previous content unavailable, because its producer never read [before]. *)
