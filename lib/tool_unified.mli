
(** Tool_unified — Unified query interface across catalog, registry,
    and dispatch.

    Combines:
    - {!Tool_catalog}: visibility, lifecycle, metadata
    - {!Tool_registry}: call statistics (count, success, failure, duration)
    - {!Tool_dispatch}: registration status, read-only *)

(** {1 Types} *)

type tool_info = {
  name : string;
  visibility : Tool_catalog.visibility;
  lifecycle : Tool_catalog.lifecycle;
  is_registered : bool;
  is_read_only : bool;
  call_stats : Tool_registry.call_stats option;
}

(** {1 Per-tool lookup} *)

(** [tool_info name] assembles the combined view for a single tool. *)
val tool_info : string -> tool_info

val tool_info_to_json : tool_info -> Yojson.Safe.t

(** {1 Dashboard summary} *)

(** [summary_report ?runtime_metrics ()] aggregates call counts and latency
    from {!Tool_metrics}, plus never-called tools, visibility distribution,
    dispatch registration counts, and optional runtime metrics for the
    dashboard.

    Every per-tool row carries [public_names] beside [name]: the counters are
    keyed by the internal name, and that is the one name a request never
    contains, so without the public names a count cannot be lined up against
    the tool schemas a turn carried. The list is empty for a tool no model can
    call, and holds more than one name when a descriptor set projects the same
    internal tool several times.

    [top_20] is the head of [by_tool], which carries every tool that has been
    called. Deciding which schemas are worth their place in a request needs the
    whole distribution, not its head, so both are reported: [top_20] keeps its
    existing shape for readers that only want the busiest tools. [never_called]
    names the visible tools with no calls at all, which [never_called_count]
    previously only counted. *)
val summary_report :
  ?runtime_metrics:(unit -> Yojson.Safe.t) -> unit -> Yojson.Safe.t
