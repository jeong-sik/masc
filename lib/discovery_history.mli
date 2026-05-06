(** Discovery_history — time-series persistence of LLM endpoint probe results.

    Records Discovery probe snapshots to [{base_path}/.masc/discovery/YYYY-MM/DD.jsonl].
    Call {!record_probe} after each cache refresh to build a timeline.

    @since 2.259.0 *)

val record_probe :
  base_path:string -> Llm_provider.Discovery.endpoint_status list -> unit
(** Append probe results for all endpoints to today's JSONL file.
    Logs and counts I/O failures while preserving best-effort persistence. *)

(** #10404: probe records previously stored only the head model in
    [model_id], silently discarding additional models loaded on the
    same endpoint.  [models] now carries the full list; [model_id]
    stays populated with the head for backward compatibility with
    existing JSONL readers that index by it. *)
type probe_record = {
  ts : float;
  endpoint_url : string;
  healthy : bool;
  model_id : string option;
  models : string list;
  ctx_size : int option;
  total_slots : int option;
  busy_slots : int option;
  idle_slots : int option;
}

val record_to_json : probe_record -> Yojson.Safe.t
(** Serialise a probe record.  Exposed for unit tests; production code
    calls it through [record_probe]. *)

val read_recent :
  base_path:string -> count:int -> Yojson.Safe.t list
(** Read the most recent [count] probe entries in chronological order. *)

val read_range :
  base_path:string -> since:string -> until:string -> Yojson.Safe.t list
(** Read entries whose day-file falls within [[since, until]] (YYYY-MM-DD). *)

val prune :
  base_path:string -> days:int -> unit
(** Delete discovery day-files older than [days] days. *)

module For_testing : sig
  val observe_failure : site:string -> base_path:string -> exn -> unit
end
