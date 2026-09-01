(** LLM judge for a canary run's recall reply — pure prompt composition and
    strict reply parsing. The provider call lives in bin/keeper_canary_run.ml
    (this library stays network- and Eio-free, per lib/keeper_canary/dune).

    The judgment contract rides in the prompt and the parser fails loud.
    Provider-native structured output (response_format / json_schema) is
    deliberately not requested: capability declarations lie (ollama.com cloud
    accepted json_schema and silently ignored it, 2026-07-02 probe), and
    failing before HTTP on undeclared support made whole presets unusable
    (#22768, reverted). Fusion_judge reached the same conclusion — see
    fusion_judge.mli. *)

type per_fact = {
  category : string;  (** Matches the run's {!Keeper_canary_facts.fact}. *)
  recalled : bool;
      (** The judge's call on whether the recall reply demonstrates this
          fact's value, allowing semantic equivalence (reformatting,
          re-ordering) but not omission or contradiction. *)
}

type judgment = {
  judge_runtime : string;
      (** The runtime id that produced this judgment. The caller is
          responsible for picking a different provider family than the
          keeper under test. *)
  per_fact : per_fact list;
      (** In the run's fact order, one entry per established fact. *)
  recalled_count : int;
  all_recalled : bool;
  rationale : string;  (** Non-empty free-text justification. *)
}

val system_prompt : unit -> string

val compose_prompt :
  facts:Keeper_canary_facts.fact list -> recall_reply:string -> string
(** The user-turn prompt: the established facts (category and exact value),
    the keeper's recall reply verbatim, and the JSON output contract. *)

val parse_reply :
  judge_runtime:string ->
  facts:Keeper_canary_facts.fact list ->
  string ->
  (judgment, string) result
(** Strict parse of the judge's reply. Accepts an optional markdown code
    fence around the JSON (same tolerance as Fusion_judge_parse) but
    nothing else: the object must carry exactly the run's categories (each
    once, no extras), boolean [recalled] per fact, and a non-empty
    [rationale]. [per_fact] is returned re-ordered to the run's fact
    order regardless of the judge's ordering. *)

val judgment_to_yojson : judgment -> Yojson.Safe.t
