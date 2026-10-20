(** Exact Memory OS prompt rendering. *)

val render_facts : Keeper_memory_os_types.fact list -> string
val render_fact : Keeper_memory_os_types.fact -> string

val facts_payload_bytes :
  ordinary_facts:Keeper_memory_os_types.fact list -> source_lines:string list -> int
(** Bytes of the joined facts lines. Commit callers reserve source lines with
    [verified=false], the longest rendering recall can emit for them. *)

val facts_within_budget :
  ordinary_facts:Keeper_memory_os_types.fact list -> source_lines:string list -> bool
(** Whether {!facts_payload_bytes} fits the configured commit budget. A set
    that does not fit can only commit by shrinking ({!check_facts_budget}), so
    a pass that proposes no change cannot commit it. *)

val check_facts_budget :
  previous_bytes:int
  -> ordinary_facts:Keeper_memory_os_types.fact list
  -> source_lines:string list
  -> (unit, string) result
(** Reject an over-budget proposed current set before either store commits,
    except when it strictly reduces an already over-budget set. This permits
    incremental retraction after a configured cap is lowered. *)
