open Base

(** Tool_unified — Unified query interface across catalog, registry,
    and dispatch.

    Combines:
    - {!Tool_catalog}: visibility, lifecycle, metadata
    - {!Tool_registry}: call statistics (count, success, failure, duration)
    - {!Tool_dispatch}: registration status, read-only, join-required *)

(** {1 Types} *)

type tool_info = {
  name : string;
  visibility : Tool_catalog.visibility;
  lifecycle : Tool_catalog.lifecycle;
  is_registered : bool;
  is_read_only : bool;
  is_join_required : bool;
  call_stats : Tool_registry.call_stats option;
}

(** {1 Per-tool lookup} *)

(** [tool_info name] assembles the combined view for a single tool. *)
val tool_info : string -> tool_info

val tool_info_to_json : tool_info -> Yojson.Safe.t

(** {1 Dashboard summary} *)

(** [summary_report ()] aggregates total/top-20 call counts,
    never-called tools, visibility distribution, dispatch registration
    counts, and cascade metrics for the dashboard. *)
val summary_report : unit -> Yojson.Safe.t
