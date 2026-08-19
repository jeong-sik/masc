(** LLM task-completion review.

    Every completion verdict comes from the configured evaluator. The complete
    task description, completion notes, contract, and evidence references are
    passed to that evaluator without a local semantic classifier. Evaluator
    failure, missing tool calls, and malformed output are explicit unavailable
    outcomes. Only an actual structured model verdict may approve or reject.

    @since v2.145.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type review_request =
  { task_title : string
  ; task_description : string
  ; completion_notes : string
  ; agent_name : string
  ; task_id : string
  ; evidence_refs : string list
  }

type lookup_surface =
  | No_lookup_surface
  | Lookup_tools of
      { schemas : Types_core.tool_schema list
      ; dispatch : name:string -> args:Yojson.Safe.t -> (string, string) result
      }

type verdict =
  | Approve
  | Reject of string

let outcome_observer_fn
  : (outcome:string -> runtime:string -> unit) Atomic.t
  = Atomic.make (fun ~outcome:_ ~runtime:_ -> ())

let run_llm_reviewer_fn
  : (base_path:string ->
     ?sw:Eio.Switch.t ->
     evaluator_runtime:string ->
     prompt:string ->
     report_tool_schema:Types_core.tool_schema ->
     lookup:lookup_surface ->
     on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
     unit -> (verdict option, Agent_core.Error.t) result) Atomic.t
  = Atomic.make (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ () ->
      Error (Agent_core.Error.Internal "Workspace_hooks: run_llm_reviewer_fn not connected"))

(** Issue #8436: schema enum used to be hand-rolled as a 2-element
    string list. Payload-bearing [Reject _] prevents the simple
    [List.map] trick. Witness function below ensures every variant
    maps to a name in [valid_verdict_strings]. Adding a 3rd
    constructor will fail compilation in [verdict_constructor_name]. *)
let verdict_constructor_name = function
  | Approve -> "APPROVE"
  | Reject _ -> "REJECT"
;;

let valid_verdict_strings = [ "APPROVE"; "REJECT" ]

type gate =
  | Structured_tool
  | Invalid_verdict
  | Evaluator_unavailable

let gate_to_string = function
  | Structured_tool -> "structured_tool"
  | Invalid_verdict -> "invalid_verdict"
  | Evaluator_unavailable -> "evaluator_unavailable"
;;

type review_result =
  { verdict : verdict option
  ; evaluator_runtime : string
  ; generator_runtime : string option
  ; gate : gate
  ; fallback_reason : string option
  ; retryable : bool
  }

(* ================================================================ *)
(* LLM verification prompt                                          *)
(* ================================================================ *)

let contract_section = function
  | None | Some [] -> ""
  | Some items ->
    let render_item idx item =
      sprintf "%d. %s" (idx + 1) item
    in
    sprintf
      "\n\
       <verification_contract>\n\
       The completion notes must satisfy every contract item below. Reject if \
       the notes do not provide concrete evidence for any item.\n\
       %s\n\
       </verification_contract>\n"
      (items |> List.mapi render_item |> String.concat "\n")
;;

(* required_evidence + verify_gate_evidence are requirements from the task
   contract, not evidence fetched by this reviewer.  Surface them as a
   distinct checklist the evaluator judges item-by-item against the immutable
   typed submit-time snapshot.  A URL, host path, commit, or board reference
   remains only a requirement unless its relevant contents were materialized
   as an [artifact:] snapshot.  Order-preserving dedup keeps a requirement
   listed in both source lists from appearing twice. *)
let evidence_section ~required_evidence ~verify_gate_evidence =
  let items =
    List.fold_left
      (fun acc raw ->
         let item = String.trim raw in
         if item = "" || List.mem item acc then acc else acc @ [ item ])
      []
      (required_evidence @ verify_gate_evidence)
  in
  match items with
  | [] -> ""
  | items ->
    let render_item idx item =
      sprintf "%d. %s" (idx + 1) item
    in
    sprintf
      "\n\
       <required_evidence>\n\
       The task contract requires support for every item listed below. Judge each \
       item independently against the typed submit-time snapshot: only available, \
       non-truncated [artifact:] content is inspectable proof. A URL, host path, \
       commit, board reference, command claim, or narrative note is not proof that \
       this system agent fetched or executed anything. Reject if the required \
       support is missing, unavailable, truncated, a placeholder, or \
       unsubstantiated.\n\
       %s\n\
       </required_evidence>\n"
      (items |> List.mapi render_item |> String.concat "\n")
;;

(* What the evaluator is told it can see. The two branches are different claims
   about the same review, and stating the wrong one is not cosmetic: telling a
   toolless evaluator to go look produces an approval justified by a check it
   never ran, and telling a tool-carrying one that the snapshot is all there is
   reproduces the gap this surface was added to close. *)
let lookup_section = function
  | No_lookup_surface ->
    "\n\
     Inspectable proof exists only in the typed `submitted_evidence_access` \
     snapshot inside `completion_notes`. You have no tool that opens anything \
     else, so a reference you cannot read there is a reference you cannot \
     verify.\n"
  | Lookup_tools { schemas; dispatch = _ } ->
    sprintf
      "\n\
       <live_lookup>\n\
       You hold the producer's own tools, pointed at the producer's tree: %s. \
       They run inside that producer's sandbox — the same jail the producer \
       worked in — and they are not restricted to reading.\n\n\
       The snapshot is what was true when the work was submitted. A lookup is what \
       is true now. Both are evidence, and disagreement between them is also \
       evidence: a file the snapshot shows and the tree no longer contains was \
       not durable.\n\n\
       Present is not the same as durable. Work that exists only as an \
       uncommitted change survives until the next task cleans that working tree, \
       and reading the file cannot tell you which of the two you are looking at. \
       Ask what differs from the last commit before treating a file's contents as \
       the completed work.\n\n\
       A claim about behaviour is not settled by reading the code that makes it. \
       If the submitter says a build succeeds or a test passes, run it. You are \
       judging the work, not the description of the work.\n\n\
       Because these tools can change the tree, one rule binds you: do not repair \
       what you are judging. If a build fails, that is a finding, not a task. \
       Fixing it and then approving produces work no one verified — yours. Every \
       call you make is recorded against this review, so a verdict reached after \
       you changed the tree is visible as exactly that.\n\n\
       A note claiming a path, a commit, or a command result is still not proof by \
       itself. The difference is that you can now check the claims that name \
       something in the producer's tree, so approving without checking an \
       available one is your omission rather than the submitter's.\n\
       </live_lookup>\n"
      (schemas
       |> List.map (fun (schema : Types_core.tool_schema) -> schema.name)
       |> String.concat ", ")
;;

let build_prompt ?(few_shot_block = "") ?completion_contract
      ?(required_evidence = []) ?(verify_gate_evidence = [])
      ~(lookup : lookup_surface)
      (req : review_request) : (string, string) result =
  let desc = req.task_description in
  let calibration_section =
    if few_shot_block = "" then "" else "\n" ^ few_shot_block ^ "\n"
  in
  let verification_contract_section = contract_section completion_contract in
  let required_evidence_section =
    evidence_section ~required_evidence ~verify_gate_evidence
  in
  let evidence_refs_json =
    req.evidence_refs
    |> List.map (fun reference -> `String reference)
    |> fun values -> Yojson.Safe.to_string (`List values)
  in
  let vars =
    [ "task_title", req.task_title
    ; "task_description", desc
    ; "agent_name", req.agent_name
    ; "completion_notes", req.completion_notes
    ; "verification_contract_section", verification_contract_section
    ; "evidence_section", required_evidence_section
    ; "evidence_refs", evidence_refs_json
    ; "lookup_section", lookup_section lookup
    ; "calibration_section", calibration_section
    ]
  in
  Prompt_registry.render_prompt_template
    Prompt_names.verification
    vars
;;

(* ================================================================ *)
(* Structured Review Verdict: Tool Schema + JSON Parsing (ADR D3)   *)
(* ================================================================ *)

(** JSON schema for the report_review_verdict tool.
    Forces the LLM to call a tool with typed parameters.
    verdict is constrained to APPROVE/REJECT by enum. *)
let report_review_verdict_schema : Masc_domain.tool_schema =
  { name = "report_review_verdict"
  ; description =
      "Report your review verdict. You MUST call this tool with your assessment. verdict \
       must be exactly APPROVE or REJECT."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "verdict"
                , `Assoc
                    [ "type", `String "string"
                    ; (* Issue #8436: derived from Variant SSOT. Hand-rolled enum
             risks dropping a constructor on extension. *)
                      "enum", `List (List.map (fun s -> `String s) valid_verdict_strings)
                    ; ( "description"
                      , `String
                          "APPROVE if notes describe real work, REJECT if vague or \
                           avoidant" )
                    ] )
              ; ( "reason"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Brief explanation (required for REJECT)"
                    ] )
              ] )
        ; "required", `List [ `String "verdict" ]
        ]
  }
;;

(** Parse review verdict from tool call JSON arguments (deterministic). *)
let parse_review_verdict_from_json (args : Yojson.Safe.t) : (verdict, string) result =
  try
    let verdict_str =
      match Json_util.assoc_member_opt "verdict" args with
      | Some (`String value) -> value
      | _ -> ""
    in
    let reason =
      try (match Json_util.assoc_member_opt "reason" args with Some (`String s) -> s | _ -> "") with
      | Yojson.Safe.Util.Type_error _ -> ""
    in
    match verdict_str with
    | "APPROVE" -> Ok Approve
    | "REJECT" ->
      if String.equal (String.trim reason) ""
      then Error "REJECT verdict requires a non-empty reason"
      else Ok (Reject reason)
    | other -> Error (sprintf "unexpected review verdict value: %s" other)
  with
  | Yojson.Safe.Util.Type_error (msg, _) -> Error (sprintf "review verdict JSON type error: %s" msg)
  (* RFC-0106 — cancellation MUST propagate; the file's other parsers
     (see line ~244) already do this, so the catch-all here was an
     N-of-M omission within the same module. *)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (sprintf "review verdict JSON parse error: %s" (Printexc.to_string exn))
;;

(* ================================================================ *)
(* Cross-model runtime selection (#3067, RFC-0361 D7(a))             *)
(* ================================================================ *)

(** [\[runtime.exact_output_lanes.verifier_exact\]] — the dedicated exact-output
    lane every completion-authority judgement call runs on. The lane's admitted
    slots, in frozen declaration order, are the single provider-selection SSOT:
    the retired [\[runtime\].cross_verifier] single-runtime binding is absorbed
    into the lane's first slot, and there is no second selector path (no
    cross_verifier read, no [\[runtime\].default] fallback).

    Cross-model evaluation is more effective than same-model different-role
    because different model architectures have different blindspots.
    See: Anthropic "Harness Design" blog analysis. *)
let verifier_exact_lane_id = "verifier_exact"

(** Ordered evaluator slot list for one review. An explicit
    [~evaluator_runtime] override is a single-slot lane (tests,
    [--evaluator-runtime]); without one the published [verifier_exact] lane
    supplies the frozen declaration order. The verdict channel is the
    [report_review_verdict] tool call, so every slot needs a tool-calling
    model — no wire response format is requested
    ([Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config]). *)
let resolve_evaluator_slots = function
  | Some runtime when String.trim runtime <> "" -> Ok [ runtime ]
  | Some _ -> Error "task completion evaluator runtime is empty"
  | None ->
    (try
       match (Atomic.get Workspace_hooks.get_verifier_exact_lane_slot_ids_fn) () with
       | Ok [] ->
         Error "verifier_exact exact-output lane resolved to no admitted slots"
       | Ok slots -> Ok slots
       | Error detail -> Error detail
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "verifier_exact exact-output lane resolution failed: %s"
            (Printexc.to_string exn)))
;;

(* ================================================================ *)
(* Core: review                                                     *)
(* ================================================================ *)

let unresolved_evaluator_runtime = "unresolved"

let review
      ?evaluator_runtime
      ?generator_runtime
      ?(completion_contract : string list option)
      ?(required_evidence = [])
      ?(verify_gate_evidence = [])
      ?(on_verdict : review_result -> unit = fun _ -> ())
      ?(on_tool_result : input:Yojson.Safe.t -> Tool_result.result -> unit = fun ~input:_ _ -> ())
      ?(few_shot_block = "")
      ?(sw : Eio.Switch.t option = None)
      ~(lookup : lookup_surface)
      ~base_path
      (req : review_request)
  : review_result
  =
  let emit result =
    on_verdict result;
    result
  in
  let task_info fmt =
    Stdlib.Format.ksprintf
      (fun message -> Log.Task.info "task_id=%s %s" req.task_id message)
      fmt
  in
  let task_warn fmt =
    Stdlib.Format.ksprintf
      (fun message -> Log.Task.warn "task_id=%s %s" req.task_id message)
      fmt
  in
  match resolve_evaluator_slots evaluator_runtime with
  | Error reason ->
    (Atomic.get outcome_observer_fn)
      ~outcome:"unavailable"
      ~runtime:unresolved_evaluator_runtime;
    task_warn "[task-completion-review] %s; task remains nonterminal" reason;
    emit
      { verdict = None
      ; evaluator_runtime = unresolved_evaluator_runtime
      ; generator_runtime
      ; gate = Evaluator_unavailable
      ; fallback_reason = Some reason
      ; retryable = true
      }
  | Ok [] ->
    (* [resolve_evaluator_slots] never yields an empty list; this arm keeps the
       match total without inventing a runtime. *)
    (Atomic.get outcome_observer_fn)
      ~outcome:"unavailable"
      ~runtime:unresolved_evaluator_runtime;
    let reason = "verifier_exact exact-output lane resolved to no admitted slots" in
    task_warn "[task-completion-review] %s; task remains nonterminal" reason;
    emit
      { verdict = None
      ; evaluator_runtime = unresolved_evaluator_runtime
      ; generator_runtime
      ; gate = Evaluator_unavailable
      ; fallback_reason = Some reason
      ; retryable = true
      }
  | Ok (first_slot :: _ as slots) ->
    (match
       build_prompt
         ~few_shot_block
         ?completion_contract
         ~required_evidence
         ~verify_gate_evidence
         ~lookup
         req
     with
     | Error detail ->
       (Atomic.get outcome_observer_fn)
         ~outcome:"unavailable"
         ~runtime:first_slot;
       task_warn
         "[task-completion-review] prompt unavailable runtime=%s: %s"
         first_slot
         detail;
       emit
         { verdict = None
         ; evaluator_runtime = first_slot
         ; generator_runtime
         ; gate = Evaluator_unavailable
         ; fallback_reason = Some detail
         ; retryable = true
         }
     | Ok prompt ->
       (match generator_runtime with
        | Some generator when List.exists (String.equal generator) slots ->
          task_warn
            "[task-completion-review] generator runtime %s is one of the verifier_exact lane slots"
            generator
        | None | Some _ -> ());
       (* Frozen-order slot failover, the same contract as the librarian /
          compaction lanes: each slot is tried at most once, in declaration
          order, and a slot that produces no usable verdict — provider error or
          a reply without exactly one valid verdict tool call — yields to the
          next slot. The terminal result describes the last attempt, so a
          single-slot lane reports exactly what the pre-lane path reported. *)
       let run_attempt slot =
         try
           (Atomic.get run_llm_reviewer_fn)
             ~base_path
             ?sw
             ~evaluator_runtime:slot
             ~prompt
             ~report_tool_schema:report_review_verdict_schema
             ~lookup
             ~on_tool_result
             ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error
             (Agent_core.Error.Internal
                (Printf.sprintf
                   "task completion evaluator raised unexpectedly: %s"
                   (Printexc.to_string exn)))
       in
       let rec attempt slot remaining =
         match run_attempt slot with
         | Ok (Some verdict) ->
           (match verdict with
            | Approve ->
              task_info
                "[task-completion-review] LLM approved runtime=%s"
                slot
            | Reject reason ->
              task_info
                "[task-completion-review] LLM rejected runtime=%s reason=%s"
                slot
                reason);
           emit
             { verdict = Some verdict
             ; evaluator_runtime = slot
             ; generator_runtime
             ; gate = Structured_tool
             ; fallback_reason = None
             ; retryable = true
             }
         | Ok None ->
           let detail =
             "task completion evaluator did not call report_review_verdict exactly once"
           in
           (Atomic.get outcome_observer_fn)
             ~outcome:"invalid_verdict"
             ~runtime:slot;
           (match remaining with
            | next :: rest ->
              task_warn
                "[task-completion-review] %s runtime=%s; failing over to next verifier_exact slot %s"
                detail
                slot
                next;
              attempt next rest
            | [] ->
              task_warn "[task-completion-review] %s" detail;
              emit
                { verdict = None
                ; evaluator_runtime = slot
                ; generator_runtime
                ; gate = Invalid_verdict
                ; fallback_reason = Some detail
                ; retryable = true
                })
         | Error error ->
           let detail = Agent_core.Error.to_string error in
           let retryable = Agent_core.Error.is_retryable error in
           (Atomic.get outcome_observer_fn)
             ~outcome:"unavailable"
             ~runtime:slot;
           (match remaining with
            | next :: rest ->
              task_warn
                "[task-completion-review] evaluator unavailable runtime=%s retryable=%b; failing over to next verifier_exact slot %s: %s"
                slot
                retryable
                next
                detail;
              attempt next rest
            | [] ->
              task_warn
                "[task-completion-review] evaluator unavailable runtime=%s retryable=%b; task remains nonterminal: %s"
                slot
                retryable
                detail;
              emit
                { verdict = None
                ; evaluator_runtime = slot
                ; generator_runtime
                ; gate = Evaluator_unavailable
                ; fallback_reason = Some detail
                ; retryable
                }))
       in
       attempt first_slot (List.tl slots))
;;
