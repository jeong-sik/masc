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
    what a verdict means. With [No_lookup_surface] nothing the request asserts
    can be checked against the producer's tree: a completion is judged on the
    submitted excerpt alone, and a stop on its stated reason alone. Both are
    described to the judge in their own question's words, so the surface is
    the same value and the prose about it is not. This module deliberately
    does not build the surface itself: the tools that read a producer's tree
    belong above the containment primitives, not inside the review protocol.
    Every advertised filesystem tool is bound to the one producer named by the
    review request. *)
type lookup_surface =
  | No_lookup_surface
  | Lookup_tools of
      { schemas : Types_core.tool_schema list
      ; dispatch : name:string -> args:Yojson.Safe.t -> (string, string) result
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
                than implying an empty tree. *)
      }

(** Both outcomes carry the reviewer's stated reason. The string may be empty:
    the tool schema asks for one on either outcome, but only [Reject] is
    refused without it. *)
type verdict =
  | Approve of string
  | Reject of string

val verdict_constructor_name : verdict -> string

(** The verdict vocabulary the [report_review_verdict] tool schema must
    advertise, owned by the {!verdict} variant. The TOML declaration in
    [config/tools/report_review_verdict.toml] carries it as a literal; the
    mirror test in [test_anti_rationalization_empty_reject] pins the two
    together (RFC prompts-and-tool-definitions-outside-ocaml §2.2). *)
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
  ; evaluator_error_retryable : bool option
        (** [Some true] when a verdict-less exhausted lane observed at least
            one typed retryable {!Agent_core.Error.t}; a later non-retryable
            fallback cannot mask that transient candidate. [Some false] when
            typed evaluator errors existed but all were non-retryable. [None]
            for a produced verdict, an invalid-verdict-only reply, or a prompt
            or slot resolution failure. [None] is not "retry": nothing about
            those outcomes says a repeat of the same request would end
            differently. This was once a plain [bool] defaulting to [true],
            which is why an [Invalid_verdict] review re-ran on the maintenance
            pulse forever without telling anyone. *)
  }

val run
  :  ?evaluator_runtime:string
  -> ?generator_runtime:string
  -> ?on_verdict:(review_result -> unit)
  -> ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?sw:Eio.Switch.t option
  -> log_info:(string -> unit)
  -> log_warn:(string -> unit)
  -> render_prompt:(unit -> (string, string) result)
  -> lookup:lookup_surface
  -> base_path:string
  -> unit
  -> review_result
(** Run one review over an already-rendered prompt. This is the whole of what
    a verification lane shares: evaluator slot resolution, frozen-order slot
    failover, the model call, and the structured verdict channel. What the
    prompt says, and what subject the log lines name, belong to the lane.

    [~render_prompt] is called after the slots resolve, so a render failure is
    still reported against the slot that would have run.

    Task completion review is {!review}. Goal proof review renders its own
    template and calls this directly: the two lanes judge different things and
    share no prompt variables. *)

(** The question the completion authority is asked, and the material it
    needs. Only a completion reaches this module: a cancel claim is the
    operator's to close (RFC-0415 §4.1) and the system lane hands it on
    without a prompt. *)

(** The evidence posture of a completion submission, as the judge sees it.
    [Note_only]: zero artifacts it can open — every item a note or an unusable
    reference. [Usable_artifacts n]: [n] readable, untruncated artifacts. The
    arithmetic is the judge prompt's rules 3 and 4 made typed, so the prose
    cannot drift from what the snapshot holds. *)
type evidence_posture =
  | Note_only
  | Usable_artifacts of int

type verdict_question =
  { completion_contract : string list option
  ; required_evidence : string list
  ; evidence_posture : evidence_posture
        (** Computed at the review site from the fixed snapshot. The question
            picker reads no store. *)
  ; few_shot_block : string
        (** Operator disagreements returned to the judge as examples, filled
            at the review site where the calibration ledger is read. *)
  }

val review
  :  ?evaluator_runtime:string
  -> ?generator_runtime:string
  -> ?on_verdict:(review_result -> unit)
  -> ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?sw:Eio.Switch.t option
  -> question:verdict_question
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
    failover. *)

(** Render the review prompt {!Prompt_names.verification} with the sections
    the [question] and the [lookup] surface supply.

    There is no inline fallback prompt; an error keeps the Task nonterminal. *)
val build_prompt
  :  question:verdict_question
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
      -> on_runtime_attempt_error:
        (runtime_id:string -> attempt:int -> Agent_core.Error.t -> unit)
      -> unit
      -> (verdict option, Agent_core.Error.t) result)
       Atomic.t
(** The system agent supplies its owning workspace BasePath explicitly; this
    callback must not substitute a process-global BasePath. *)
