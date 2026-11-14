(** Exact Memory OS prompt rendering. *)

val render_facts : Keeper_memory_os_types.fact list -> string
val render_fact : Keeper_memory_os_types.fact -> string

val facts_payload_bytes :
  ordinary_facts:Keeper_memory_os_types.fact list -> source_lines:string list -> int
(** Bytes of the joined facts lines. Commit callers reserve source lines with
    [verified=false], the longest rendering recall can emit for them. *)

(** Whether the file-source store adds lines to the payload. *)
type facts_source_usage =
  | No_source_memory
  | Source_memory of { bytes : int }
      (** {!facts_payload_bytes} of the source lines alone. *)

(** One measurement of the payload the commit budget counts. [total_bytes] is
    {!facts_payload_bytes} of the ordinary facts and the source lines together,
    the number {!check_facts_budget} compares with [maximum_bytes]; the parts
    are the same function over each side alone, so [total_bytes] exceeds their
    sum by the one newline that joins them when both are present. *)
type facts_budget =
  { maximum_bytes : int
  ; ordinary_bytes : int
  ; source : facts_source_usage
  ; total_bytes : int
  }

val measure_facts_budget :
  maximum_bytes:int
  -> ordinary_facts:Keeper_memory_os_types.fact list
  -> source_lines:string list
  -> facts_budget
(** The Librarian prompt shows this measurement and the commit checks it, so
    the two cannot disagree about one set of facts and source lines. *)

val facts_budget_fits : facts_budget -> bool
(** Whether [total_bytes] fits [maximum_bytes]. A set that does not fit can
    only commit by shrinking ({!check_facts_budget}), so a pass that proposes
    no change cannot commit it. *)

val check_facts_budget :
  previous_bytes:int
  -> ordinary_facts:Keeper_memory_os_types.fact list
  -> source_lines:string list
  -> (unit, string) result
(** Reject an over-budget proposed current set before either store commits,
    except when it strictly reduces an already over-budget set. This permits
    incremental retraction after a configured cap is lowered. The comparison
    is {!facts_budget_fits} over {!measure_facts_budget} with the configured
    maximum. *)
