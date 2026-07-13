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

type verdict =
  | Approve
  | Reject of string

let outcome_observer_fn
  : (outcome:string -> runtime:string -> unit) Atomic.t
  = Atomic.make (fun ~outcome:_ ~runtime:_ -> ())

let run_llm_reviewer_fn
  : (?sw:Eio.Switch.t ->
     evaluator_runtime:string ->
     prompt:string ->
     report_tool_schema:Types_core.tool_schema ->
     unit -> (verdict option, Agent_sdk.Error.sdk_error) result) Atomic.t
  = Atomic.make (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Error (Agent_sdk.Error.Internal "Workspace_hooks: run_llm_reviewer_fn not connected"))

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

(* required_evidence + verify_gate_evidence are the artifacts the task
   contract demands the completion notes provide.  task-1664: previously only
   [completion_contract] reached the LLM prompt, so a task with
   required_evidence=["PR link"] could be approved on narrative notes with no
   artifact.  Surface them as a distinct checklist the evaluator judges
   item-by-item.  Order-preserving dedup keeps an artifact listed in both
   source lists from appearing twice. *)
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
       The task contract requires the completion notes to supply or reference \
       each evidence artifact listed below. Judge every item independently: \
       decide whether the notes provide concrete, verifiable evidence for it (an \
       actual reference, link, path, or command output — not a restatement of the \
       requirement or a promise to produce it later). Reject if any item is \
       missing, a placeholder, or unsubstantiated.\n\
       %s\n\
       </required_evidence>\n"
      (items |> List.mapi render_item |> String.concat "\n")
;;

let build_prompt ?(few_shot_block = "") ?completion_contract
      ?(required_evidence = []) ?(verify_gate_evidence = [])
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
    ; "calibration_section", calibration_section
    ]
  in
  Prompt_registry.render_prompt_template "verification.anti_rationalization" vars
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
      let r =
        if reason = "" then "completion notes did not address the task" else reason
      in
      Ok (Reject r)
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
(* Cross-model runtime selection (#3067)                             *)
(* ================================================================ *)

(** Default evaluator runtime name. Override via [~evaluator_runtime]
    to force a specific evaluator profile. Without an override, the
    concrete profile comes from [routes.cross_verifier].

    Cross-model evaluation is more effective than same-model different-role
    because different model architectures have different blindspots.
    See: Anthropic "Harness Design" blog analysis. *)
(* Function, not a module-level value: [Runtime.get_default_runtime_id] fail-fasts
   until [Runtime.init_default] runs at startup (RFC-0206 §2.1). A module-level
   binding evaluates at load time and crashes boot; defer to call time.

   Prefer [\[runtime\].cross_verifier] when set: the evaluator requests a JSON
   structured verdict, so it must run on a JSON-capable model independent of the
   fleet default. When the default runtime cannot emit JSON the evaluator may
   return empty output; routing it explicitly keeps the gate live and restores
   cross-model separation. [None] = inherit the global default (legacy). *)
let default_evaluator_runtime () =
  match (Atomic.get Workspace_hooks.get_cross_verifier_runtime_id_fn) () with
  | Some id -> id
  | None -> (Atomic.get Workspace_hooks.get_default_runtime_id_fn) ()
;;

(* ================================================================ *)
(* Core: review                                                     *)
(* ================================================================ *)

let unresolved_evaluator_runtime = "unresolved"

let resolve_evaluator_runtime = function
  | Some runtime when String.trim runtime <> "" -> Ok runtime
  | Some _ -> Error "task completion evaluator runtime is empty"
  | None ->
    (try
       let runtime = default_evaluator_runtime () in
       if String.trim runtime = ""
       then Error "default task completion evaluator runtime is empty"
       else Ok runtime
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "task completion evaluator runtime resolution failed: %s"
            (Printexc.to_string exn)))
;;

let review
      ?evaluator_runtime
      ?generator_runtime
      ?(completion_contract : string list option)
      ?(required_evidence = [])
      ?(verify_gate_evidence = [])
      ?(on_verdict : review_result -> unit = fun _ -> ())
      ?(few_shot_block = "")
      ?(sw : Eio.Switch.t option = None)
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
  match resolve_evaluator_runtime evaluator_runtime with
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
      }
  | Ok evaluator_runtime ->
    (match
       build_prompt
         ~few_shot_block
         ?completion_contract
         ~required_evidence
         ~verify_gate_evidence
         req
     with
     | Error detail ->
       (Atomic.get outcome_observer_fn)
         ~outcome:"unavailable"
         ~runtime:evaluator_runtime;
       task_warn
         "[task-completion-review] prompt unavailable runtime=%s: %s"
         evaluator_runtime
         detail;
       emit
         { verdict = None
         ; evaluator_runtime
         ; generator_runtime
         ; gate = Evaluator_unavailable
         ; fallback_reason = Some detail
         }
     | Ok prompt ->
       (match generator_runtime with
        | Some generator when String.equal generator evaluator_runtime ->
          task_warn
            "[task-completion-review] generator and evaluator runtime are both %s"
            evaluator_runtime
        | None | Some _ -> ());
       let reviewer_result =
         try
           (Atomic.get run_llm_reviewer_fn)
             ?sw
             ~evaluator_runtime
             ~prompt
             ~report_tool_schema:report_review_verdict_schema
             ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error
             (Agent_sdk.Error.Internal
                (Printf.sprintf
                   "task completion evaluator raised unexpectedly: %s"
                   (Printexc.to_string exn)))
       in
       (match reviewer_result with
        | Ok (Some verdict) ->
          (match verdict with
           | Approve ->
             task_info
               "[task-completion-review] LLM approved runtime=%s"
               evaluator_runtime
           | Reject reason ->
             task_info
               "[task-completion-review] LLM rejected runtime=%s reason=%s"
               evaluator_runtime
               reason);
          emit
            { verdict = Some verdict
            ; evaluator_runtime
            ; generator_runtime
            ; gate = Structured_tool
            ; fallback_reason = None
            }
        | Ok None ->
          let detail =
            "task completion evaluator did not call report_review_verdict exactly once"
          in
          (Atomic.get outcome_observer_fn)
            ~outcome:"invalid_verdict"
            ~runtime:evaluator_runtime;
          task_warn "[task-completion-review] %s" detail;
          emit
            { verdict = None
            ; evaluator_runtime
            ; generator_runtime
            ; gate = Invalid_verdict
            ; fallback_reason = Some detail
            }
        | Error error ->
          let detail = Agent_sdk.Error.to_string error in
          (Atomic.get outcome_observer_fn)
            ~outcome:"unavailable"
            ~runtime:evaluator_runtime;
          task_warn
            "[task-completion-review] evaluator unavailable runtime=%s; task remains nonterminal: %s"
            evaluator_runtime
            detail;
          emit
            { verdict = None
            ; evaluator_runtime
            ; generator_runtime
            ; gate = Evaluator_unavailable
            ; fallback_reason = Some detail
            }))
;;
