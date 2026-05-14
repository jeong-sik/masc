(** Keeper_relevance_check — structural keyword coverage verification. *)

type relevance_result = {
  input_keywords : string list;
  covered_keywords : string list;
  uncovered_keywords : string list;
  coverage_ratio : float;
}

val extract_keywords : string -> string list
(** Split text into lowercase keywords, removing stop words and short
    tokens. Duplicates are collapsed. *)

val check :
  ?min_coverage:float ->
  input_content:string ->
  reply_text:string ->
  unit ->
  relevance_result
(** [check ~input_content ~reply_text ()] extracts keywords from both
    strings and computes what fraction of input keywords appear in the
    reply.  [min_coverage] defaults to [0.3] but is currently unused
    (reserved for future threshold gating). *)

val is_relevant : relevance_result -> bool
(** [is_relevant r] is [true] when [r.coverage_ratio >= 0.3]. *)
