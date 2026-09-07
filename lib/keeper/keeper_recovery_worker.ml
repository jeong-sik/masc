module Work = Keeper_recovery_work
module Projection = Keeper_recovery_projection
module Invocation = Agent_core.Tool_contract.Invocation

let ( let* ) = Result.bind

type requirement_binding =
  { reference_id : string
  ; positions : Projection.requirement list
  }

type page_encoding = Keeper_artifact_read.page_encoding =
  | Utf_8
  | Base64
[@@deriving yojson]

type read_receipt =
  { tool_use_id : string
  ; turn : int
  ; planned_index : int
  ; runtime_id : string option
  ; recovery_source_sha256 : string
  ; artifact_sha256 : string
  ; offset : int
  ; next_offset : int
  ; total_bytes : int
  ; encoding : page_encoding
  ; returned_content_sha256 : string
  }
[@@deriving yojson]

type proposal_receipt =
  { work_id : string
  ; owner_claim_id : string
  ; tool_use_id : string
  ; runtime_id : string option
  ; source_sha256 : string
  ; proposal_artifact_sha256 : string
  ; work_revision : string
  ; lock_release_error : string option
  }
[@@deriving yojson]

type observation =
  | Page_produced of read_receipt
  | Proposal_persisted of proposal_receipt

type cause =
  | Store_error of Work.error
  | Requirement_binding_invalid of string
  | Source_observation_failed of string
  | Invalid_submission of string
  | Projection_rejected of Projection.error
  | Runtime_error of Agent_core.Error.t
  | No_proposal_submitted

let cause_to_string = function
  | Store_error e -> Work.error_to_string e
  | Requirement_binding_invalid s -> "recovery requirement binding: " ^ s
  | Source_observation_failed s -> "recovery source unavailable: " ^ s
  | Invalid_submission s -> "invalid recovery proposal: " ^ s
  | Projection_rejected e -> Projection.error_to_string e
  | Runtime_error e -> Agent_core.Error.to_string e
  | No_proposal_submitted -> "worker finished without a typed proposal submission"
;;

type failed =
  { cause : cause
  ; reads : read_receipt list
  ; terminal_record : (Work.t Work.mutation, Work.error) result option
  ; execution : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result option
  ; claim_lock_release_error : string option
  }

type submitted =
  { work : Work.t
  ; validated : Projection.validated
  ; receipt : proposal_receipt
  ; reads : read_receipt list
  ; execution : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result
  ; claim_lock_release_error : string option
  }

type outcome =
  | Proposal_recorded of submitted
  | Stopped of failed

let digest s = Digestif.SHA256.(to_hex (digest_string s))
let lock_error = Option.map File_lock_eio.durable_lock_error_to_string

let object_fields expected = function
  | `Assoc fields
    when List.sort String.compare (List.map fst fields)
         = List.sort String.compare expected -> Ok fields
  | _ -> Error (Invalid_submission "object fields do not match the proposal schema")
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> Ok s
  | _ -> Error (Invalid_submission (name ^ " must be a string"))
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int n) -> Ok n
  | _ -> Error (Invalid_submission (name ^ " must be an integer"))
;;

let decode_step json =
  let* fields = object_fields [ "kind"; "first_atom"; "last_atom"; "text" ] json in
  let* kind = string_field "kind" fields in
  let* first = int_field "first_atom" fields in
  let* last = int_field "last_atom" fields in
  match kind, List.assoc_opt "text" fields with
  | "retain", Some `Null when first = last -> Ok (Projection.Retain first)
  | "retain", _ ->
    Error (Invalid_submission "retain requires first_atom=last_atom and text=null")
  | "summarize", Some (`String text) ->
    Ok (Projection.Summarize { first_atom = first; last_atom = last; text })
  | "summarize", _ -> Error (Invalid_submission "summarize requires text")
  | _ -> Error (Invalid_submission "kind must be retain or summarize")
;;

let decode_proposal json =
  let* fields = object_fields [ "source_sha256"; "steps" ] json in
  let* source_sha256 = string_field "source_sha256" fields in
  let* steps =
    match List.assoc_opt "steps" fields with
    | Some (`List xs) ->
      List.fold_left
        (fun acc x ->
           let* acc = acc in
           let* step = decode_step x in
           Ok (step :: acc))
        (Ok [])
        xs
      |> Result.map List.rev
    | _ -> Error (Invalid_submission "steps must be an array")
  in
  Ok Projection.{ source_sha256; steps }
;;

let proposal_tool_name = "keeper_recovery_propose"

let proposal_schema =
  let int = `Assoc [ "type", `String "integer"; "minimum", `Int 0 ] in
  let step =
    `Assoc
      [ "type", `String "object"
      ; "additionalProperties", `Bool false
      ; ( "required"
        , `List
            (List.map (fun s -> `String s) [ "kind"; "first_atom"; "last_atom"; "text" ])
        )
      ; ( "properties"
        , `Assoc
            [ ( "kind"
              , `Assoc
                  [ "type", `String "string"
                  ; "enum", `List [ `String "retain"; `String "summarize" ]
                  ] )
            ; "first_atom", int
            ; "last_atom", int
            ; "text", `Assoc [ "type", `List [ `String "string"; `String "null" ] ]
            ] )
      ]
  in
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "required", `List [ `String "source_sha256"; `String "steps" ]
    ; ( "properties"
      , `Assoc
          [ "source_sha256", `Assoc [ "type", `String "string" ]
          ; "steps", `Assoc [ "type", `String "array"; "items", step ]
          ] )
    ]
;;

let require_positions work bindings =
  let ids = List.map (fun b -> b.reference_id) bindings in
  if
    List.sort String.compare ids
    <> List.sort String.compare (Work.required_source_refs work)
    || List.exists (fun b -> b.positions = []) bindings
  then
    Error
      (Requirement_binding_invalid
         "every owner-required reference needs exactly one nonempty binding")
  else Ok (List.concat_map (fun b -> b.positions) bindings)
;;

let invocation env =
  match Agent_core.Tool.Execution_env.invocation env with
  | Some i when String.trim (Invocation.tool_use_id i) <> "" -> Ok i
  | _ -> Error (Invalid_submission "exact Tool invocation identity unavailable")
;;

let rec append_atomic cell value =
  let before = Atomic.get cell in
  if not (Atomic.compare_and_set cell before (value :: before))
  then append_atomic cell value
;;

let reads cell =
  List.sort
    (fun a b -> compare (a.turn, a.planned_index) (b.turn, b.planned_index))
    (Atomic.get cell)
;;

let tool_failure name start cause =
  Tool_result.make_err
    ~tool_name:name
    ~class_:Tool_result.Workflow_rejection
    ~start_time:start
    (cause_to_string cause)
;;

let execution_result name start (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed () ->
    Tool_result.make_ok
      ~tool_name:name
      ~start_time:start
      ?data:execution.data
      ?metadata:execution.metadata
      ()
  | Tool_result.Failed class_ ->
    Tool_result.make_err
      ~tool_name:name
      ~class_
      ~start_time:start
      ?data:execution.data
      ?metadata:execution.metadata
      execution.raw_output
  | Tool_result.Deferred () ->
    Tool_result.make_deferred
      ~tool_name:name
      ~start_time:start
      ?data:execution.data
      ?metadata:execution.metadata
      ()
;;

let run
      ~config
      ~work_id
      ~expected_revision
      ~instance_id
      ~runtime_id
      ~purpose
      ~requirements
      ~observe_current_source
      ?(on_observation = fun _ -> ())
      ?raw_trace
      ?event_bus
      ?trace_link
      ?on_event
      ?on_runtime_observation
      ?on_request_wire_observation
      ?on_request_attribution
      ?on_official_client_result_handoff
      ?on_runtime_attempt_error
      ~sw
      ~net
      ()
  =
  let preflight =
    let* work =
      Work.load ~config ~id:work_id |> Result.map_error (fun e -> Store_error e)
    in
    let* work = Option.to_result ~none:(Store_error Work.Not_found) work in
    let* required = require_positions work requirements in
    let* () =
      if String.trim purpose = ""
      then Error (Requirement_binding_invalid "purpose is empty")
      else Ok ()
    in
    let* claim =
      Work.claim ~config ~id:work_id ~expected_revision ~instance_id
      |> Result.map_error (fun e -> Store_error e)
    in
    Ok (required, claim)
  in
  match preflight with
  | Error cause ->
    Stopped
      { cause
      ; reads = []
      ; terminal_record = None
      ; execution = None
      ; claim_lock_release_error = None
      }
  | Ok (required, claim) ->
    let work, owner = claim.Work.value in
    let claim_lock_release_error = lock_error claim.lock_release_error in
    let observed_reads = Atomic.make [] in
    let current_runtime = Atomic.make None in
    let published = ref None in
    let last_rejection = ref None in
    let settle cause execution =
      let failure =
        match cause with
        | Store_error (Work.Artifact_missing _ | Work.Artifact_read_failed _)
        | Source_observation_failed _ ->
          Work.Source_access_unavailable (cause_to_string cause)
        | Invalid_submission _ | Projection_rejected _ ->
          Work.Proposal_invalid (cause_to_string cause)
        | _ -> Work.Worker_failed (cause_to_string cause)
      in
      let terminal_record =
        Work.fail
          ~config
          ~id:work_id
          ~owner
          ~expected_revision:(Work.revision work)
          failure
      in
      Stopped
        { cause
        ; reads = reads observed_reads
        ; terminal_record = Some terminal_record
        ; execution
        ; claim_lock_release_error
        }
    in
    let observe_source () =
      try observe_current_source () with
      | Sys_error detail -> Error detail
      | Unix.Unix_error (error, operation, path) ->
        Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message error))
    in
    let execute () =
      let preparation =
        let* () =
          Work.verify_artifacts config work |> Result.map_error (fun e -> Store_error e)
        in
        let* snapshot =
          observe_source () |> Result.map_error (fun e -> Source_observation_failed e)
        in
        let* () =
          if
            Keeper_checkpoint_ref.equal
              (Work.source work)
              (Keeper_checkpoint_store.exact_snapshot_reference snapshot)
          then Ok ()
          else Error (Projection_rejected Projection.Source_changed)
        in
        let* source =
          Domain_pool_ref.submit_cpu_or_inline (fun () ->
            Projection.index ~source:snapshot ~required)
          |> Result.map_error (fun e -> Projection_rejected e)
        in
        Ok (snapshot, source)
      in
      match preparation with
      | Error cause -> settle cause None
      | Ok (snapshot, source) ->
        let artifact_schema = Keeper_runtime_schemas_toml.artifact_read in
        let artifact_tool =
          Tool_bridge.agent_core_tool_of_masc_with_execution_env
            ~descriptor:
              (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
            ~base_path:config.Workspace.base_path
            ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
            ~name:artifact_schema.name
            ~description:artifact_schema.description
            ~input_schema:artifact_schema.input_schema
            (fun env args ->
               let start = Time_compat.now () in
               match invocation env with
               | Error cause -> tool_failure artifact_schema.name start cause
               | Ok i ->
                 let execution, page =
                   Keeper_artifact_read.handle_with_page ~base_path:config.base_path ~args
                 in
                 Option.iter
                   (fun (page : Keeper_artifact_read.page) ->
                      let receipt =
                        { tool_use_id = Invocation.tool_use_id i
                        ; turn = Invocation.turn i
                        ; planned_index = Invocation.planned_index i
                        ; runtime_id = Atomic.get current_runtime
                        ; recovery_source_sha256 = Work.source_artifact_sha256 work
                        ; artifact_sha256 = page.sha256
                        ; offset = page.offset
                        ; next_offset = page.next_offset
                        ; total_bytes = page.total_bytes
                        ; encoding = page.encoding
                        ; returned_content_sha256 = digest page.content
                        }
                      in
                      append_atomic observed_reads receipt;
                      on_observation (Page_produced receipt))
                   page;
                 execution_result artifact_schema.name start execution)
        in
        let proposal_tool =
          Tool_bridge.agent_core_tool_of_masc_with_execution_env
            ~descriptor:
              (Agent_core.Tool.terminal_descriptor
                 Agent_core.Tool_contract.Effect_outcome_unknown)
            ~base_path:config.base_path
            ~name:proposal_tool_name
            ~description:
              "Submit one source-bound proposal. Cover atoms in order exactly once. \
               retain: first_atom=last_atom, text=null. summarize: inclusive range and \
               nonempty text. Required/open Tool atoms must remain original. This \
               records a proposal, not an applied recovery."
            ~input_schema:proposal_schema
            (fun env input ->
               let start = Time_compat.now () in
               let result =
                 let* i = invocation env in
                 let* proposal = decode_proposal input in
                 let* validated =
                   Domain_pool_ref.submit_cpu_or_inline (fun () ->
                     Projection.validate ~source proposal)
                   |> Result.map_error (fun e -> Projection_rejected e)
                 in
                 let* current =
                   observe_source ()
                   |> Result.map_error (fun e -> Source_observation_failed e)
                 in
                 let* _ =
                   Projection.bind_exact ~current_source:current validated
                   |> Result.map_error (fun e -> Projection_rejected e)
                 in
                 let proposal_bytes =
                   Yojson.Safe.to_string
                     (`Assoc
                         [ "proposal", Projection.proposal_to_yojson proposal
                         ; ( "proposal_invocation"
                           , `Assoc
                               [ "tool_use_id", `String (Invocation.tool_use_id i)
                               ; "turn", `Int (Invocation.turn i)
                               ; "planned_index", `Int (Invocation.planned_index i)
                               ; "owner_claim_id", `String (Work.owner_claim_id owner)
                               ; ( "runtime_id"
                                 , match Atomic.get current_runtime with
                                   | None -> `Null
                                   | Some id -> `String id )
                               ] )
                         ; ( "handler_page_receipts"
                           , `List
                               (List.map read_receipt_to_yojson (reads observed_reads)) )
                         ])
                 in
                 let* saved =
                   Work.record_proposal
                     ~config
                     ~id:work_id
                     ~owner
                     ~expected_revision:(Work.revision work)
                     ~current_source:current
                     ~claimed_required_refs:(Work.required_source_refs work)
                     ~claimed_stimulus_ids:(Work.pending_stimulus_ids work)
                     ~proposal_bytes
                   |> Result.map_error (fun e -> Store_error e)
                 in
                 let stored = saved.Work.value in
                 let* artifact =
                   match Work.status stored with
                   | Work.Proposal_recorded p -> Ok (Work.projection_artifact_sha256 p)
                   | _ ->
                     Error (Invalid_submission "storage did not return a proposal record")
                 in
                 let receipt =
                   { work_id
                   ; owner_claim_id = Work.owner_claim_id owner
                   ; tool_use_id = Invocation.tool_use_id i
                   ; runtime_id = Atomic.get current_runtime
                   ; source_sha256 = (Work.source work).sha256
                   ; proposal_artifact_sha256 = artifact
                   ; work_revision = Work.revision stored
                   ; lock_release_error = lock_error saved.lock_release_error
                   }
                 in
                 published := Some (stored, validated, receipt);
                 on_observation (Proposal_persisted receipt);
                 Ok receipt
               in
               match result with
               | Ok receipt ->
                 Tool_result.make_ok
                   ~tool_name:proposal_tool_name
                   ~start_time:start
                   ~data:(proposal_receipt_to_yojson receipt)
                   ()
               | Error cause ->
                 last_rejection := Some cause;
                 tool_failure proposal_tool_name start cause)
        in
        let manifest =
          `Assoc
            [ "work_id", `String work_id
            ; "purpose", `String purpose
            ; "source_sha256", `String (Work.source_artifact_sha256 work)
            ; ( "source_bytes"
              , `Int
                  (String.length
                     (Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot)) )
            ; "source_watermark", `String (Work.source_watermark work)
            ; ( "required_refs"
              , `List (List.map (fun s -> `String s) (Work.required_source_refs work)) )
            ; ( "pending_stimulus_ids"
              , `List (List.map (fun s -> `String s) (Work.pending_stimulus_ids work)) )
            ; ( "atoms"
              , `List (List.map Projection.atom_to_yojson (Projection.atoms source)) )
            ]
        in
        let tools = [ artifact_tool; proposal_tool ] in
        let execution =
          Keeper_turn_driver.run_named
            ~runtime_id
            ~keeper_name:(Work.keeper_name work)
            ~base_path:config.base_path
            ~session_id:("recovery-" ^ Work.owner_claim_id owner)
            ~system_prompt:
              "Read the canonical source and its referenced artifacts with \
               keeper_artifact_read as needed; pages are not a proof of understanding. \
               Produce a faithful source-bound transmission proposal with \
               keeper_recovery_propose. Keep all required and pending atoms original. \
               Never claim the original Keeper task is complete."
            ~goal:(Yojson.Safe.to_string manifest)
            ~tools
            ~agent_core_tools:tools
            ~tool_requirement:Keeper_required_tools.Required
            ~cache_system_prompt:true
            ?raw_trace
            ?event_bus
            ?trace_link
            ?on_event
            ?on_runtime_observation
            ?on_request_wire_observation
            ?on_request_attribution
            ?on_official_client_result_handoff
            ~on_official_client_tool_boundary:(fun () ->
              let open Keeper_official_client_host in
              match !published, !last_rejection with
              | Some _, _ ->
                Ok
                  (Some
                     (Terminal_tool_boundary
                        { tool_name = proposal_tool_name; outcome = Terminal_completed }))
              | None, Some cause ->
                Ok
                  (Some
                     (Terminal_tool_boundary
                        { tool_name = proposal_tool_name
                        ; outcome =
                            Terminal_failed
                              { failure_class = Tool_result.Workflow_rejection
                              ; effect_disposition = Tool_result.Effect_outcome_unknown
                              ; diagnostic = cause_to_string cause
                              }
                        }))
              | None, None -> Ok None)
            ?on_runtime_attempt_error
            ~on_runtime_attempt:(fun (attempt : Keeper_turn_driver.runtime_attempt) ->
              Atomic.set current_runtime (Some attempt.runtime_id))
            ~sw
            ~net
            ()
        in
        (match !published with
         | Some (work, validated, receipt) ->
           Proposal_recorded
             { work
             ; validated
             ; receipt
             ; reads = reads observed_reads
             ; execution
             ; claim_lock_release_error
             }
         | None ->
           let cause =
             match !last_rejection, execution with
             | Some cause, _ -> cause
             | None, Error e -> Runtime_error e
             | None, Ok _ -> No_proposal_submitted
           in
           settle cause (Some execution))
    in
    (try execute () with
     | Eio.Cancel.Cancelled _ as exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       (match !published with
        | Some _ -> ()
        | None ->
          Eio.Cancel.protect (fun () ->
            try
              match
                Work.cancel
                  ~config
                  ~id:work_id
                  ~owner
                  ~expected_revision:(Work.revision work)
                  ~reason:"recovery worker scope cancelled"
              with
              | Ok mutation ->
                Option.iter
                  (fun error ->
                     Log.Keeper.warn
                       "recovery cancellation recorded, lock release failed: %s"
                       (File_lock_eio.durable_lock_error_to_string error))
                  mutation.Work.lock_release_error
              | Error e ->
                Log.Keeper.warn
                  "recovery cancellation settlement failed: %s"
                  (Work.error_to_string e)
            with
            | Sys_error detail ->
              Log.Keeper.warn "recovery cancellation I/O failed: %s" detail
            | Unix.Unix_error (error, operation, path) ->
              Log.Keeper.warn
                "recovery cancellation %s(%s) failed: %s"
                operation
                path
                (Unix.error_message error)));
       Printexc.raise_with_backtrace exn backtrace)
;;
