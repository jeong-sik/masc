(** Discovery_history — time-series persistence of LLM endpoint probe results.

    Records Discovery probe snapshots to [{base_path}/.masc/discovery/YYYY-MM/DD.jsonl].
    Call {!record_probe} after each cache refresh to build a timeline.

    @since 2.259.0 *)

val record_probe :
  base_path:string -> Llm_provider.Discovery.endpoint_status list -> unit
(** Append probe results for all endpoints to today's JSONL file.
    Silently catches I/O failures (best-effort persistence). *)

val read_recent :
  base_path:string -> count:int -> Yojson.Safe.t list
(** Read the most recent [count] probe entries in chronological order. *)

val read_range :
  base_path:string -> since:string -> until:string -> Yojson.Safe.t list
(** Read entries whose day-file falls within [[since, until]] (YYYY-MM-DD). *)

val prune :
  base_path:string -> days:int -> unit
(** Delete discovery day-files older than [days] days. *)
