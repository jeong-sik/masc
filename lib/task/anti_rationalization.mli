(** Configured-LLM task-completion review. Only the structured
    [report_review_verdict] tool call can produce [Approve] or [Reject]. Missing
    configuration, provider failure, prompt-render failure, and missing or
    malformed tool calls remain typed non-verdict outcomes. *)

type review_request =
  { task_title : string
  ; task_description : string
  ; completion_notes : string
  ; agent_name : string
  ; task_id : string
  ; evidence_refs : string list
  }

(** What the evaluator may look at besides the submitted evidence snapshot
    (RFC-0361 D1).

    Stated per review rather than defaulted, because the two cases differ in
    what a verdict means. With [No_lookup_surface] the submitter's references
    are the upper bound of what could be checked, and an approval says only
    that the submitted excerpt reads as real work. This module deliberately
    does not build the surface itself: the tools that read a producer's tree
    belong above the containment primitives, not inside the review protocol. *)
type lookup_scope =
  | Producer_tree
      (** Every advertised filesystem tool is already bound to the one
          producer named by the review request. *)
  | Producer_forest of { producers : string list }
      (** Filesystem calls must select one producer from this closed set. Used
          by Goal proof review, where linked Tasks may have different
          performers and therefore different owned trees. *)

type lookup_surface =
  | No_lookup_surface
  | Lookup_tools of
      { schemas : Types_core.tool_schema list
      ; dispatch : name:string -> args:Yojson.Safe.t -> (string, string) result
      ; scope : lookup_scope
      ; root_layout : string list
            (** Paths the lookup tools actually resolve against, listed from
                disk at review time and relative to the root they are rooted
                at. The evaluator is otherwise told only that the tools point
                at "the producer's tree" and has to guess the shape: an
                evaluator that assumed a repository root spent 77 consecutive
                failed reads on [dune-project], [.git], [lib/], [README.md],
                [Makefile], [src] and [bin] against a sandbox root whose real
                entries were [repos/], [artifacts/], [mind/] and [poc/]
                (masc task-403, vrf-8bac5f46, 2026-08-21). Empty when the
                root could not be listed — the prompt then says so rather
                than implying an empty tree. For a [Producer_forest] scope
                this is the forest root, so a producer name is one of the
                entries. *)
      }

type verdict =
  | Approve
  | Reject of string

val verdict_constructor_name : verdict -> string
val valid_verdict_strings : string list

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

val gate_to_string : gate -> string

type review_result =
  { verdict : verdict option
  ; evaluator_runtime : string
  ; generator_runtime : string option
  ; gate : gate
  ; fallback_reason : string option
  }

val review
  :  ?evaluator_runtime:string
  -> ?generator_runtime:string
  -> ?completion_contract:string list
  -> ?required_evidence:string list
  -> ?on_verdict:(review_result -> unit)
  -> ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?few_shot_block:string
  -> ?prompt_name:string
  -> ?sw:Eio.Switch.t option
  -> lookup:lookup_surface
  -> base_path:string
  -> review_request
  -> review_result
(** [base_path] is the workspace BasePath selected by the caller. The review
    must not rediscover it from process-global environment state.

    Without [~evaluator_runtime], the evaluator slots come from the published
    [verifier_exact] exact-output lane (RFC-0361 D7(a)) and are tried in frozen
    declaration order: a slot that fails or returns no valid verdict tool call
    yields to the next slot, and the terminal result describes the last
    attempt. An explicit [~evaluator_runtime] is a single-slot lane with no
    failover.

    [~prompt_name] selects the prompt-registry template rendered for the
    review; it defaults to {!Prompt_names.verification} (the task completion
    review). The goal verification lane (RFC-0387) passes its own templates —
    provider selection, failover, and the verdict channel are unchanged. *)

(** Render the single prompt-registry SSOT. There is no inline fallback prompt;
    an error keeps the Task nonterminal. [~prompt_name] defaults to
    {!Prompt_names.verification}; other callers (RFC-0387 goal verification)
    select their own registered template. *)
val build_prompt
  :  ?few_shot_block:string
  -> ?completion_contract:string list
  -> ?required_evidence:string list
  -> ?prompt_name:string
  -> lookup:lookup_surface
  -> review_request
  -> (string, string) result

val parse_review_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val outcome_observer_fn : (outcome:string -> runtime:string -> unit) Atomic.t

val run_llm_reviewer_fn
  :  (base_path:string
      -> ?sw:Eio.Switch.t
      -> evaluator_runtime:string
      -> prompt:string
      -> report_tool_schema:Types_core.tool_schema
      -> lookup:lookup_surface
      -> on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
      -> unit
      -> (verdict option, Agent_core.Error.t) result)
       Atomic.t
(** The system agent supplies its owning workspace BasePath explicitly; this
    callback must not substitute a process-global BasePath. *)
