(** Keeper_memory_llm_summary_outcome — closed sum naming each path
    out of {!Keeper_memory_llm_summary.summarize_with_provider}.

    Until this module existed, the three failure modes (timeout, HTTP
    error, empty/whitespace-only response) each logged at warn but
    were not aggregated as a counter, so operators could not see
    "what fraction of summary attempts succeed" or
    "which provider is regressing".  Successful summaries left no
    record at all.  Additionally, {!summarize_with_providers}
    returning [None] after exhausting every provider in the cascade
    was *silent* — no log, no metric, just a missing summary on the
    consolidation path.

    This module attaches a typed contract to each branch so the
    counter label is governed at compile time. *)

type t =
  | Ok_summary
      (** Provider returned a non-empty, non-whitespace summary text. *)
  | Timed_out
      (** [Eio.Time.with_timeout_exn] raised before the provider
          completed.  Counter increment + warn already exists. *)
  | Http_error
      (** Provider returned a non-2xx response or transport-level
          failure (deserialised by [Oas_compat.Http_client]). *)
  | Empty_response
      (** Provider returned 2xx but [response_text] collapsed to
          empty after trim — usually a model that produced only
          whitespace or refused the task. *)

val to_label : t -> string
