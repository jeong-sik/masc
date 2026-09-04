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
      ; root_layout : string list
      }

(* Both outcomes carry the reviewer's stated reason. [Approve] used to be
   nullary, and the parser below read [reason] and then dropped it, so an
   approval reached the ledger as a bare token while a rejection arrived with
   its argument. [Goal_verification_agent] had to re-read the reason out of the
   tool call through a ref to commit a goal proof at all; carrying it here is
   what that workaround was standing in for. The string may be empty — the
   schema asks for one on both outcomes but only [Reject] refuses without it,
   and turning an approval into a failure is a gate this does not add. *)
type verdict =
  | Approve of string
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
     on_runtime_attempt_error:
       (runtime_id:string -> attempt:int -> Agent_core.Error.t -> unit) ->
     unit -> (verdict option, Agent_core.Error.t) result) Atomic.t
  = Atomic.make (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
      Error (Agent_core.Error.Internal "Workspace_hooks: run_llm_reviewer_fn not connected"))

(** Issue #8436: the verdict vocabulary is owned by this variant. Witness
    function below ensures every variant maps to a name in
    [valid_verdict_strings]. Adding a 3rd constructor will fail compilation
    in [verdict_constructor_name]. The [report_review_verdict] tool schema in
    [config/tools/report_review_verdict.toml] declares the same enum as a
    literal, and [test_anti_rationalization_empty_reject] mirrors the two. *)
let verdict_constructor_name = function
  | Approve _ -> "APPROVE"
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
  ; evaluator_error_retryable : bool option
  }

(* ================================================================ *)
(* LLM verification prompt                                          *)
(* ================================================================ *)

(* Review prose lives in [config/prompts/verification.md] and its slots. This module picks
   the template and supplies the data it renders — a tool-name list, a root
   listing, a numbered item list — and holds no review instructions of its own.
   Two things go wrong when the prose sits here instead: a code change that
   alters what the evaluator can do leaves the sentence describing it stale
   (the required-evidence checklist kept saying artifacts were the only
   readable thing for as long as the lookup surface existed), and an operator
   cannot correct a sentence without a rebuild. *)

let numbered items =
  items |> List.mapi (fun index item -> sprintf "%d. %s" (index + 1) item)
        |> String.concat "\n"
;;

let render key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> Ok ("\n" ^ String.trim text ^ "\n")
  | Error detail -> Error (sprintf "prompt %s: %s" key detail)
;;

let contract_section = function
  | None | Some [] -> Ok ""
  | Some items ->
    render Prompt_names.verification_contract [ "contract_items", numbered items ]
;;

(* required_evidence items are requirements from the task contract, not
   evidence this reviewer fetched. Order-preserving dedup keeps an item listed
   twice from appearing twice. *)
let evidence_section ~required_evidence =
  let items =
    List.fold_left
      (fun acc raw ->
         let item = String.trim raw in
         if item = "" || List.mem item acc then acc else acc @ [ item ])
      []
      required_evidence
  in
  match items with
  | [] -> Ok ""
  | items ->
    render
      Prompt_names.verification_required_evidence
      [ "evidence_items", numbered items ]
;;

(* Unavailable or partial roots are rejected while constructing the lookup
   surface. Reaching this renderer with no entries therefore means the
   authority measured a readable, empty root. The empty-marker sentence lives
   in verification.md ([lookup.root_layout_empty]); the two-space indent is
   layout, not prose. *)
let root_layout_lines = function
  | [] ->
    (match
       Prompt_registry.render_prompt_template
         Prompt_names.verification_lookup_root_layout_empty
         []
     with
     | Ok text -> Ok ("  " ^ String.trim text)
     | Error detail ->
       Error
         (sprintf
            "prompt %s: %s"
            Prompt_names.verification_lookup_root_layout_empty
            detail))
  | entries -> Ok (entries |> List.map (fun entry -> "  " ^ entry) |> String.concat "\n")
;;

let tool_names schemas =
  schemas
  |> List.map (fun (schema : Types_core.tool_schema) -> schema.name)
  |> String.concat ", "
;;

let lookup_section = function
  | No_lookup_surface -> render Prompt_names.verification_lookup_none []
  | Lookup_tools { schemas; dispatch = _; root_layout } ->
    let ( let* ) = Result.bind in
    let* lookup_root_layout = root_layout_lines root_layout in
    render
      Prompt_names.verification_lookup_producer_tree
      [ "lookup_tools", tool_names schemas; "lookup_root_layout", lookup_root_layout ]
;;

let build_prompt
      ?(few_shot_block = "")
      ?completion_contract
      ?(required_evidence = [])
      ~(lookup : lookup_surface)
      (req : review_request) : (string, string) result =
  let ( let* ) = Result.bind in
  let desc = req.task_description in
  let calibration_section =
    if few_shot_block = "" then "" else "\n" ^ few_shot_block ^ "\n"
  in
  let* verification_contract_section = contract_section completion_contract in
  let* required_evidence_section = evidence_section ~required_evidence in
  let* lookup_section = lookup_section lookup in
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
    ; "lookup_section", lookup_section
    ; "calibration_section", calibration_section
    ]
  in
  Prompt_registry.render_prompt_template Prompt_names.verification vars
;;

(* ================================================================ *)
(* Structured Review Verdict: Tool Schema + JSON Parsing (ADR D3)   *)
(* ================================================================ *)

(** JSON schema for the report_review_verdict tool, read from
    [config/tools/report_review_verdict.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2). Forces the LLM to call
    a tool with typed parameters; verdict is constrained to APPROVE/REJECT by
    the TOML enum literal, which the mirror test in
    [test_anti_rationalization_empty_reject] pins to [valid_verdict_strings]
    (the variant SSOT). Decoded once at module initialization; a missing or
    undecodable file refuses the boot. *)
let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

(* What to say on each verdict lives in config/prompts/verification.md, not
   in the schema — model-facing prose belongs in the prompt files (RFC
   prompts-and-tool-definitions-outside-ocaml), and the ratchet on this file
   enforces that. *)
let report_review_verdict_schema : Masc_domain.tool_schema =
  schema_of_name "report_review_verdict"
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
    | "APPROVE" -> Ok (Approve reason)
    | "REJECT" ->
      (* A tool result the reviewer LLM reads back, so the sentence is a
         managed prompt; the pure parse errors below stay inline (RFC §6
         mechanically-derived validation). *)
      if String.equal (String.trim reason) ""
      then Error (Tool_guidance.to_string Tool_guidance.Reject_verdict_requires_reason)
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

let run
      ?evaluator_runtime
      ?generator_runtime
      ?(on_verdict : review_result -> unit = fun _ -> ())
      ?(on_tool_result : input:Yojson.Safe.t -> Tool_result.result -> unit = fun ~input:_ _ -> ())
      ?(sw : Eio.Switch.t option = None)
      ~(log_info : string -> unit)
      ~(log_warn : string -> unit)
      ~(render_prompt : unit -> (string, string) result)
      ~(lookup : lookup_surface)
      ~base_path
      ()
  : review_result
  =
  let emit result =
    on_verdict result;
    result
  in
  let task_info fmt = Stdlib.Format.ksprintf log_info fmt in
  let task_warn fmt = Stdlib.Format.ksprintf log_warn fmt in
  match resolve_evaluator_slots evaluator_runtime with
  | Error reason ->
    (Atomic.get outcome_observer_fn)
      ~outcome:"unavailable"
      ~runtime:unresolved_evaluator_runtime;
    task_warn "%s; no verdict committed" reason;
    emit
      { verdict = None
      ; evaluator_runtime = unresolved_evaluator_runtime
      ; generator_runtime
      ; gate = Evaluator_unavailable
      ; fallback_reason = Some reason
      ; evaluator_error_retryable = None
      }
  | Ok [] ->
    (* [resolve_evaluator_slots] never yields an empty list; this arm keeps the
       match total without inventing a runtime. *)
    (Atomic.get outcome_observer_fn)
      ~outcome:"unavailable"
      ~runtime:unresolved_evaluator_runtime;
    let reason = "verifier_exact exact-output lane resolved to no admitted slots" in
    task_warn "%s; no verdict committed" reason;
    emit
      { verdict = None
      ; evaluator_runtime = unresolved_evaluator_runtime
      ; generator_runtime
      ; gate = Evaluator_unavailable
      ; fallback_reason = Some reason
      ; evaluator_error_retryable = None
      }
  | Ok (first_slot :: rest_slots) ->
    (match render_prompt () with
     | Error detail ->
       (Atomic.get outcome_observer_fn)
         ~outcome:"unavailable"
         ~runtime:first_slot;
       task_warn
         "prompt unavailable runtime=%s: %s"
         first_slot
         detail;
       emit
         { verdict = None
         ; evaluator_runtime = first_slot
         ; generator_runtime
         ; gate = Evaluator_unavailable
         ; fallback_reason = Some detail
         ; evaluator_error_retryable = None
         }
     | Ok prompt ->
       (match generator_runtime with
        | Some generator when List.exists (String.equal generator) (first_slot :: rest_slots) ->
          task_warn
            "generator runtime %s is one of the verifier_exact lane slots"
            generator
        | None | Some _ -> ());
       (* Frozen-order slot failover, the same contract as the other exact
          lanes: each slot is tried at most once, in declaration
          order, and a slot that produces no usable verdict — provider error or
          a reply without exactly one valid verdict tool call — yields to the
          next slot. The terminal runtime/reason describes the last attempt,
          while retryability aggregates every typed evaluator error: one
          transient slot must not be masked by a later statically unavailable
          fallback. The same aggregation includes typed failures from the
          runtime candidates inside each slot, while the slot's terminal error
          remains the operator-facing reason. A single-slot lane still reports
          exactly what the pre-lane path reported. *)
       let run_attempt slot =
         let nested_retryable_error_seen = ref false in
         try
           let result =
             (Atomic.get run_llm_reviewer_fn)
               ~base_path
               ?sw
               ~evaluator_runtime:slot
               ~prompt
               ~report_tool_schema:report_review_verdict_schema
               ~lookup
               ~on_tool_result
               ~on_runtime_attempt_error:
                 (fun ~runtime_id:_ ~attempt:_ error ->
                    if Agent_core.Error.is_retryable error
                    then nested_retryable_error_seen := true)
               ()
           in
           result, !nested_retryable_error_seen
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           ( Error
               (Agent_core.Error.Internal
                  (Printf.sprintf
                     "review evaluator raised unexpectedly: %s"
                     (Printexc.to_string exn)))
           , !nested_retryable_error_seen )
       in
       let rec attempt ~retryable_error_seen slot remaining =
         match run_attempt slot with
         | Ok (Some verdict), _nested_retryable_error_seen ->
           (match verdict with
            | Approve reason ->
              task_info
                "LLM approved runtime=%s reason=%s"
                slot
                reason
            | Reject reason ->
              task_info
                "LLM rejected runtime=%s reason=%s"
                slot
                reason);
           emit
             { verdict = Some verdict
             ; evaluator_runtime = slot
             ; generator_runtime
             ; gate = Structured_tool
             ; fallback_reason = None
             ; evaluator_error_retryable = None
             }
         | Ok None, nested_retryable_error_seen ->
           let detail =
             "evaluator did not call report_review_verdict exactly once"
           in
           (Atomic.get outcome_observer_fn)
             ~outcome:"invalid_verdict"
             ~runtime:slot;
           (match remaining with
            | next :: rest ->
              task_warn
                "%s runtime=%s; failing over to next verifier_exact slot %s"
                detail
                slot
                next;
              attempt ~retryable_error_seen next rest
            | [] ->
              task_warn "%s" detail;
              emit
                { verdict = None
                ; evaluator_runtime = slot
                ; generator_runtime
                ; gate = Invalid_verdict
                ; fallback_reason = Some detail
                ; evaluator_error_retryable =
                    (if retryable_error_seen || nested_retryable_error_seen
                     then Some true
                     else None)
                })
         | Error error, nested_retryable_error_seen ->
           let detail = Agent_core.Error.to_string error in
           let retryable =
             nested_retryable_error_seen
             || Agent_core.Error.is_retryable error
           in
           (Atomic.get outcome_observer_fn)
             ~outcome:"unavailable"
             ~runtime:slot;
           (match remaining with
            | next :: rest ->
              task_warn
                "evaluator unavailable runtime=%s retryable=%b; failing over to next verifier_exact slot %s: %s"
                slot
                retryable
                next
                detail;
              attempt
                ~retryable_error_seen:(retryable_error_seen || retryable)
                next
                rest
            | [] ->
              let exhausted_retryable = retryable_error_seen || retryable in
              task_warn
                "evaluator unavailable runtime=%s retryable=%b; no verdict committed: %s"
                slot
                exhausted_retryable
                detail;
              emit
                { verdict = None
                ; evaluator_runtime = slot
                ; generator_runtime
                ; gate = Evaluator_unavailable
                ; fallback_reason = Some detail
                ; evaluator_error_retryable =
                    Some exhausted_retryable
                })
       in
       attempt ~retryable_error_seen:false first_slot rest_slots)
;;

(* The Task lane: its own prompt variables, its own log subject. Everything
   after the prompt string is the shared {!run}. *)
let review
      ?evaluator_runtime
      ?generator_runtime
      ?(completion_contract : string list option)
      ?(required_evidence = [])
      ?on_verdict
      ?on_tool_result
      ?(few_shot_block = "")
      ?(sw : Eio.Switch.t option = None)
      ~(lookup : lookup_surface)
      ~base_path
      (req : review_request)
  : review_result
  =
  run
    ?evaluator_runtime
    ?generator_runtime
    ?on_verdict
    ?on_tool_result
    ~sw
    ~log_info:(fun message ->
      Log.Task.info "task_id=%s [task-completion-review] %s" req.task_id message)
    ~log_warn:(fun message ->
      Log.Task.warn "task_id=%s [task-completion-review] %s" req.task_id message)
    ~render_prompt:(fun () ->
      build_prompt ~few_shot_block ?completion_contract ~required_evidence ~lookup req)
    ~lookup
    ~base_path
    ()
;;
