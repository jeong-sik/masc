(** Metadata gap detection for mission briefing sections.

    Briefing facts can carry "missing" sentinel strings ("unassigned",
    "unknown", "not_recorded"). This module turns those sentinels into
    structured gap records and counts/filters them per briefing section
    (Communication / Alignment / Watch). *)

type section =
  | Communication
  | Alignment
  | Watch
(** Briefing section bucket. Constructors are public because
    {!Briefing_sections} uses [open Briefing_gaps] and references
    them unqualified. *)

val collect_metadata_gaps :
  sessions:Yojson.Safe.t list ->
  keepers:Yojson.Safe.t list ->
  agents:Yojson.Safe.t list ->
  Yojson.Safe.t list
(** Scan the three briefing fact lists for sentinel-marked gaps and
    return at most 8 gap records (session goal missing, communication
    mode missing, keeper last reply missing, active agent without
    focus). *)

val count_metadata_gaps_for_section :
  section:section -> Yojson.Safe.t list -> int
(** Count entries in [gaps] whose [kind] field maps to [section]. *)

val evidence_of_metadata_gaps :
  section:section -> Yojson.Safe.t list -> string list
(** Return up to 2 [summary] strings from gaps that map to [section],
    suitable for inline evidence rows. *)
