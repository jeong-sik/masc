(** Task-completion production-dispatch oracle with controlled reviewer replies.

    The real completion-authority daemon commits injected typed verdicts.
    Success requires a completed Task, and the repair fixture reads a delivered
    rejection before explicitly dispatching changed evidence. No real-model
    quality or autonomous Keeper repair is claimed by these fixtures. *)

open Alcotest

module KET = struct
  include Masc.Keeper_tool_dispatch_runtime
  include Masc.Keeper_tool_dispatch_runtime.Compatibility
end
module KTE = Masc.Keeper_tool_execution
module Workspace = Masc.Workspace
module AR = Masc.Task.Anti_rationalization
module Publication_availability =
  Masc.Keeper_publication_recovery_availability

type reviewer_response =
  | Reviewer_verdict of AR.verdict
  | Reviewer_unavailable

let reviewer_response = ref (Reviewer_verdict (AR.Approve ""))
let reviewer_calls = ref []
let submitted_verifications = ref []

let reviewer ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () =
  reviewer_calls := !reviewer_response :: !reviewer_calls;
  match !reviewer_response with
  | Reviewer_verdict verdict -> Ok (Some verdict)
  | Reviewer_unavailable ->
    Error (Agent_core.Error.Internal "test evaluator unavailable")
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target
        |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end
      else Unix.unlink target
  in
  try rm path with _ -> ()

let make_meta ?(name = "keeper-completion-trust") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("trace_id", `String "completion-trust-harness-trace")
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"

let with_ws name fn =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () ->
      Masc.Eval_calibration.For_testing.reset_store ();
      Time_compat.clear_clock ();
      cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      (* Resubmission can contend with the authority's final workspace-lock
         release. The production lock retry needs the same Eio clock that
         server startup installs; never replace it with a blocking sleep. *)
      Time_compat.set_clock (Eio.Stdenv.clock env);
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      (* The production calibration store is process-wide. Each case owns a
         different workspace, so bind its store explicitly and reset it only
         after the case's switch has stopped all completion-authority fibers. *)
      Masc.Eval_calibration.For_testing.set_store
        ~base_dir:(Filename.concat dir "data/verdicts");
      check int "new workspace has no verdicts from earlier cases" 0
        Yojson.Safe.Util.(Masc.Eval_calibration.calibration_stats ()
                          |> member "total_verdicts" |> to_int);
      Eio.Switch.run @@ fun sw ->
      let config = Masc.Workspace.default_config dir in
      let meta = make_meta () in
      (* Effective producer metadata reads operational settings from the
         Keeper manifest; the runtime snapshot only carries runtime state. *)
      let keepers_dir =
        Filename.concat (Workspace.masc_root_dir config) "config/keepers"
      in
      Fs_compat.mkdir_p keepers_dir;
      Out_channel.with_open_text
        (Filename.concat keepers_dir (meta.name ^ ".toml"))
        (fun channel ->
          Out_channel.output_string channel
            "[keeper]\ninstructions = \"Submit task evidence for independent completion review.\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nnetwork_mode = \"none\"\n");
      (match Masc.Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error detail -> fail ("keeper meta fixture write failed: " ^ detail));
      let meta =
        match Masc.Keeper_meta_store.read_effective_meta config meta.name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "producer effective metadata fixture is missing"
        | Error detail -> fail ("producer effective metadata fixture is invalid: " ^ detail)
      in
      (* A registered Keeper owns a sandbox tree even when the controlled
         reviewer never dispatches its lookup tools. Resolve from effective
         TOML metadata, exactly as the production verification surface does. *)
      let producer_root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
      Fs_compat.mkdir_p producer_root;
      let lookup_tools =
        match Masc.Verification_authority_tools.create ~submitted_evidence:[] ~config ~producer:meta.name with
        | Ok tools -> tools
        | Error detail -> fail ("verification lookup fixture is invalid: " ^ detail)
      in
      let root_layout =
        match Masc.Verification_authority_tools.root_layout lookup_tools with
        | Ok layout -> layout
        | Error detail -> fail ("verification root fixture is unreadable: " ^ detail)
      in
      let lookup = AR.Lookup_tools
        { schemas = Masc.Verification_authority_tools.schemas lookup_tools
        ; dispatch = Masc.Verification_authority_tools.dispatch lookup_tools
        ; root_layout
        }
      in
      (* Preflight the same prompt contract as the daemon before waiting for
         an asynchronous verdict. No evidence files are fabricated: these
         tests submit notes, and an empty producer tree is valid evidence. *)
      (match AR.build_prompt
        ~question:{ completion_contract = None; required_evidence = [];
                    evidence_posture = AR.Note_only; few_shot_block = "" }
        ~lookup
        { task_title = "Completion fixture preflight"; task_description = "Controlled verdict dispatch";
          completion_notes = "Fixture notes"; agent_name = meta.name; task_id = "fixture-preflight";
          evidence_refs = []; evidence_images = [] } with
       | Ok prompt when String.trim prompt <> "" -> ()
       | Ok _ -> fail "completion review fixture rendered an empty prompt"
       | Error detail -> fail ("completion review prompt fixture is unavailable: " ^ detail));
      (match
         Masc.Keeper_owner_registry.install_from_store
           ~sw
           ~operation_runner:None
           ~on_turn_slot_released:None
           config
       with
       | Ok 1 -> ()
       | Ok count -> failf "expected one Keeper Owner fixture, got %d" count
       | Error error ->
         fail
           (Masc.Keeper_owner_registry.install_error_to_string error));
      ignore (Masc.Keeper_registry.For_testing.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.For_testing.unregister ~base_path:config.base_path meta.name)
        (fun () ->
          Masc_test_deps.with_publication_recovery_registry
            ~sw
            ~fs:(Eio.Stdenv.fs env)
            ~registry_root:dir
            (fun publication_recovery_registry ->
               let publication_recovery =
                 { Publication_availability.provider =
                     Masc_test_deps.publication_recovery_provider
                       publication_recovery_registry
                 ; keeper_name = meta.name
                 }
               in
               ignore (Workspace.init config ~agent_name:(Some meta.name));
               reviewer_calls := [];
               submitted_verifications := [];
               let clock = Eio.Stdenv.clock env in
               Masc.Completion_authority_agent.start ~sw ~clock ~config;
               let submitted = Atomic.get Workspace_hooks.verification_submitted_fn in
               Atomic.set Workspace_hooks.verification_submitted_fn
                 (fun config ~task ~assignee ~verification_id ->
                   submitted_verifications := verification_id :: !submitted_verifications;
                   submitted config ~task ~assignee ~verification_id);
               Fun.protect
                 ~finally:(fun () ->
                   Atomic.set Workspace_hooks.verification_submitted_fn submitted)
                 (fun () ->
                   fn ~sw ~net:(Eio.Stdenv.net env) ~clock ~config ~meta ~publication_recovery
                     ~ctx_work:(make_ctx ())))))

let outcome_label = function
  | Tool_result.Completed () -> "success"
  | Tool_result.Deferred () -> "deferred"
  | Tool_result.Failed _ -> "failure"

let parse_json raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error err -> fail ("invalid json: " ^ err)

(* Owner of a task if it is currently Claimed/InProgress, else None. *)
let assignee_of config task_id =
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> String.equal t.id task_id)
      (Workspace.get_tasks_raw config)
  with
  | Some
      { task_status =
          ( Masc_domain.Claimed { assignee; _ }
          | Masc_domain.InProgress { assignee; _ } )
      ; _
      } ->
    Some assignee
  | _ -> None

let attempt_done
      ?(evidence_refs = [ "note:completion-trust-harness" ])
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~task_id
      ~result
      ()
  =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~publication_recovery
    ~ctx_work
    ~name:"keeper_task_done"
    ~input:
      (`Assoc
        [ "task_id", `String task_id
        ; "result", `String result
        ; ( "evidence_refs"
          , `List (List.map (fun ref_ -> `String ref_) evidence_refs) )
        ])
    ()

let claim_via_dispatch
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~task_id
  =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~publication_recovery
    ~ctx_work
    ~name:"keeper_task_claim"
    ~input:(`Assoc [ ("task_id", `String task_id) ])
    ()

(* Controlled reviewers run in the production authority daemon. A deadline is
   a test failure, never permission to pass with an unreviewed submission. *)
let find_task config task_id =
  List.find_opt
    (fun (task : Masc_domain.task) -> String.equal task.id task_id)
    (Workspace.get_tasks_raw config)

let await_condition ~clock label condition =
  match Eio.Time.with_timeout clock 5.0 (fun () ->
    let rec loop () =
      if condition () then Ok ()
      else (Eio.Time.sleep clock 0.001; loop ())
    in
    loop ()) with
  | Ok () -> ()
  | Error `Timeout -> fail ("timed out waiting for " ^ label)

let await_authority_verdict ~clock config task_id =
  await_condition ~clock "committed authority verdict" (fun () ->
    match find_task config task_id with
    | Some { task_status = Masc_domain.AwaitingVerification _; _ } -> false
    | _ -> true);
  find_task config task_id

let single_submission () =
  match !submitted_verifications with
  | [ verification_id ] -> verification_id
  | ids -> failf "expected one submission identity, got %d" (List.length ids)

let check_submitted_evidence config verification_id expected =
  match Masc.Verification.load_request config.Workspace.base_path verification_id with
  | Error detail -> fail ("missing persisted verification request: " ^ detail)
  | Ok request ->
    (match Masc.Completion_authority_agent.For_testing.evidence_refs_of_output request.output with
     | Error detail -> fail ("invalid submitted evidence: " ^ detail)
     | Ok refs -> check (list string) "submitted evidence refs" expected refs)

(* Test A — non-owner completion is denied (RFC-0262 axis-2 ownership gate). *)
let test_completion_denied_for_non_owner () =
  with_ws "completion_trust_non_owner"
    (fun ~sw:_ ~net:_ ~clock:_ ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"foreign-owned task" ~priority:1
         ~description:"claimed by another agent");
    let foreign = "other-keeper" in
    (match Workspace.claim_task_r config ~agent_name:foreign ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e ->
       fail ("foreign claim setup failed: " ^ Masc_domain.masc_error_to_string e));
    (* pre-state: task-001 owned by a non-caller agent (else the reject below
       would be NotClaimed for the wrong reason). *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "pre-state: task owned by a non-caller agent" true
         (not (String.equal a meta.name))
     | None ->
       fail "task-001 must be Claimed/InProgress by the foreign agent before the attack");
    (* attack: caller (non-owner) tries to complete it, with substantive notes so
       the reject is unambiguously about ownership, not note length. *)
    let result =
      attempt_done ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
        ~result:"I finished another agent's task on their behalf"
        ()
    in
    check string "non-owner completion outcome" "failure"
      (outcome_label result.KTE.disposition);
    let json = parse_json result.KTE.raw_output in
    check bool "rejection is ok=false" false Yojson.Safe.Util.(member "ok" json |> to_bool);
    check string "ownership reject is a deterministic workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    (* keeper_task_done routes through submit_for_verification, whose denial
       comes from the transition layer under the generic rule id — the
       Done_action-only typed vocabulary ("task_done_requires_current_owner")
       no longer fires on this path. Restoring typed denials on submit must
       not break the resubmit-supersede contract
       (test_tool_task_coverage: "resubmit supersedes the pending
       verification") and is tracked separately; what this case pins is that
       a non-owner's completion attempt is deterministically rejected and
       moves nothing. *)
    check string "ownership reject rule_id" "task_transition_invalid_state"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: the rejected attempt did NOT advance the FSM. *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "task still owned by foreign agent after rejected completion" true
         (not (String.equal a meta.name))
     | None -> fail "task-001 must remain Claimed/InProgress after the rejected completion"))

(* Test B — completion of an unclaimed (Todo) task is denied. *)
let test_completion_denied_when_unclaimed () =
  with_ws "completion_trust_unclaimed"
    (fun ~sw:_ ~net:_ ~clock:_ ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"never claimed" ~priority:1
         ~description:"still in the backlog");
    (* task-001 is Todo; nobody claimed it. *)
    let result =
      attempt_done ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
        ~result:"pretending an unclaimed backlog item is finished"
        ()
    in
    check string "unclaimed completion outcome" "failure"
      (outcome_label result.KTE.disposition);
    let json = parse_json result.KTE.raw_output in
    check string "unclaimed reject is a workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    (* Same routing as the ownership case above: the transition layer denies
       todo -> submit_for_verification under the generic rule id (and
       test_tool_task_coverage pins that exact denial message). The typed
       "task_done_requires_claimed_or_started" belongs to the legacy
       Done_action path only. *)
    check string "unclaimed reject rule_id" "task_transition_invalid_state"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: task stays Todo. *)
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some { task_status = Masc_domain.Todo; _ } -> ()
    | _ -> fail "task-001 must remain Todo after the rejected completion")

(* Local note length and evidence shape never decide completion. *)
let test_short_notes_without_evidence_follow_llm_approval () =
  with_ws "completion_llm_short_notes"
    (fun ~sw:_ ~net:_ ~clock ~config ~meta ~publication_recovery ~ctx_work ->
    reviewer_response := Reviewer_verdict (AR.Approve "");
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"caller's own task" ~priority:1
         ~description:"the LLM reviews even a short completion claim");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim succeeds" "success"
      (outcome_label claim.KTE.disposition);
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"done"
        ~evidence_refs:[]
        ()
    in
    check string "evidence submission succeeds" "success"
      (outcome_label result.KTE.disposition);
    match await_authority_verdict ~clock config "task-001" with
    | Some { task_status = Masc_domain.Done _; _ } -> ()
    | Some task ->
      fail
        ("expected Done after controlled reviewer approval, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after completion")


(* Synthetic provider receipt, not a visual-quality verdict: real task dispatch
   and the authority daemon must deliver the persisted rendering through the
   production OpenAI-compatible HTTP encoder. *)
let test_rendered_image_reaches_verifier_http_request () =
  with_ws "completion_rendered_image"
    (fun ~sw ~net ~clock ~config ~meta ~publication_recovery ~ctx_work ->
      let png_base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
      in
      let png = Base64.decode_exn png_base64 in
      let root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
      let source = Filename.concat root "render.PNG" in
      Fs_compat.save_file source png;
      let captured = ref None in
      let socket = Eio.Net.listen net ~sw ~backlog:1
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let port = match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port | _ -> fail "fixture requires TCP" in
      let server = Cohttp_eio.Server.make ~callback:(fun _ _ body ->
        captured := Some (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)
                          |> Yojson.Safe.from_string);
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:{|{"id":"fixture","object":"chat.completion","model":"fixture-vision","choices":[{"index":0,"message":{"role":"assistant","content":"received"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|} ()) () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Cohttp_eio.Server.run socket server ~on_error:raise);
      let previous = Atomic.get AR.run_llm_reviewer_fn in
      let http_reviewer ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_
          ?goal_blocks ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
          ~on_runtime_attempt_error:_ () =
        match goal_blocks with
        | None -> Error (Agent_core.Error.Internal "rendering missing from verifier input")
        | Some blocks ->
          (* Replacing the producer file cannot alter the submitted evidence. *)
          Fs_compat.save_file source "changed after submission";
          let provider = Llm_provider.Provider_config.make
              ~kind:Llm_provider.Provider_config.OpenAI_compat
              ~model_id:"fixture-vision"
              ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
              ~request_path:"/v1/chat/completions"
              ~model_capabilities_override:
                { Llm_provider.Capabilities.openai_compat_chat_capabilities with
                  supports_image_input = true }
              () in
          (match Llm_provider.Complete.complete ~sw ~net ~config:provider
                   ~messages:[Agent_core.Types.user_msg_blocks blocks] () with
           | Ok _ -> Ok (Some (AR.Approve "synthetic image delivery receipt only"))
           | Error _ -> Error (Agent_core.Error.Internal "fixture HTTP request failed"))
      in
      Fun.protect ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn previous)
        (fun () ->
          Atomic.set AR.run_llm_reviewer_fn http_reviewer;
          ignore (Workspace.add_task config ~title:"rendered image evidence"
            ~priority:1 ~description:"Verify attachment transport, not image semantics");
          ignore (claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
            ~task_id:"task-001");
          let result = attempt_done ~config ~meta ~publication_recovery ~ctx_work
              ~task_id:"task-001" ~result:"Rendered fixture attached"
              ~evidence_refs:["artifact:render.PNG"] () in
          check string "real submission accepted" "success"
            (outcome_label result.KTE.disposition);
          (match await_authority_verdict ~clock config "task-001" with
           | Some { task_status = Masc_domain.Done _; _ } -> ()
           | _ -> fail "synthetic provider receipt did not commit");
          let request = match !captured with
            | Some request -> request | None -> fail "no provider HTTP request" in
          let open Yojson.Safe.Util in
          let parts = request |> member "messages" |> to_list
            |> List.concat_map (fun message -> match member "content" message with
                 | `List parts -> parts | _ -> []) in
          let images = List.filter (fun part -> member "type" part = `String "image_url") parts in
          check int "one actual attached image" 1 (List.length images);
          check string "exact PNG bytes and MIME reached HTTP provider"
            ("data:image/png;base64," ^ png_base64)
            (List.hd images |> member "image_url" |> member "url" |> to_string);
          let body_path = Filename.concat (Workspace.masc_root_dir config)
              ("evidence/" ^ single_submission () ^ "/0.bin") in
          check string "immutable snapshot body" png (Fs_compat.load_file body_path);
          check string "producer file changed independently" "changed after submission"
            (Fs_compat.load_file source);
          let module Store = Workspace_verification_store in
          (* #35170: artifact reads are complete — a known binary format is
             adopted whole regardless of size, and the delivery ceiling (not
             the reader) bounds what the judge later receives. The
             pre-#35170 contract classified an over-ceiling image as
             unreadable; the unreadable classification is now reserved for
             artifacts the reader genuinely cannot read, which the
             missing-file case below still proves. *)
          Fs_compat.save_file source
            (png ^ String.make Store.verification_evidence_max_bytes 'x');
          let oversized = Store.snapshot_submitted_evidence_json
              ~request_id:"vrf-oversized-image" ~base_path:config.base_path
              ~worker:meta.name ["artifact:render.PNG"] in
          let oversized_item = oversized |> to_list |> List.hd in
          check string "oversized known binary is adopted whole"
            "artifact_binary" (oversized_item |> member "kind" |> to_string);
          Unix.unlink source;
          let missing = Store.snapshot_submitted_evidence_json
              ~request_id:"vrf-missing-image" ~base_path:config.base_path
              ~worker:meta.name ["artifact:render.PNG"] in
          check string "unreadable artifact is explicitly typed"
            "artifact_unreadable"
            (missing |> to_list |> List.hd |> member "kind" |> to_string)))


let test_completion_with_evidence_refs_succeeds () =
  with_ws "completion_trust_evidence_refs"
    (fun ~sw:_ ~net:_ ~clock ~config ~meta ~publication_recovery ~ctx_work ->
    reviewer_response := Reviewer_verdict (AR.Approve "");
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"complete with evidence refs" ~priority:1
         ~description:"claimed by the caller and completed with trusted proof");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim precondition succeeds" "success"
      (outcome_label claim.KTE.disposition);
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Implemented the deliverable and recorded completion evidence."
        ~evidence_refs:[ "note:completion-trust-harness" ]
        ()
    in
    check string "completion outcome" "success"
      (outcome_label result.KTE.disposition);
    check_submitted_evidence config (single_submission ())
      [ "note:completion-trust-harness"
      ; "note:Implemented the deliverable and recorded completion evidence."
      ];
    match await_authority_verdict ~clock config "task-001" with
    | Some { task_status = Masc_domain.Done { assignee; _ }; _ } ->
      check string "done assignee" meta.name assignee;
      check int "controlled reviewer actually ran" 1 (List.length !reviewer_calls)
    | Some task ->
      fail ("expected task-001 Done, got " ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after completion")

(* This is a controlled production-dispatch round trip, not proof that a
   real Keeper model autonomously chooses the repair. The fixture reads and
   projects the delivered decision into a world event, then explicitly
   submits changed evidence through the same tool dispatch. *)
let test_rejection_delivery_then_changed_submission_completes () =
  with_ws "completion_llm_reject_then_approve"
    (fun ~sw:_ ~net:_ ~clock ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.add_task config ~title:"Reviewed completion" ~priority:1
      ~description:"completion follows the evaluator verdict");
    let claim = claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
      ~task_id:"task-001" in
    check string "self-claim succeeds" "success" (outcome_label claim.KTE.disposition);
    let reason = "deliverable requires corrected evidence" in
    reviewer_response := Reviewer_verdict (AR.Reject reason);
    let first = attempt_done ~config ~meta ~publication_recovery ~ctx_work
      ~task_id:"task-001" ~result:"Initial completion claim"
      ~evidence_refs:[ "note:first completion review" ] () in
    check string "first submission succeeds" "success" (outcome_label first.KTE.disposition);
    let first_id = single_submission () in
    (match await_authority_verdict ~clock config "task-001" with
     | Some { task_status = Masc_domain.InProgress { assignee; _ }; _ } ->
       check string "rejected task returns to same producer" meta.name assignee
     | Some task -> fail ("expected committed rejection, got " ^
                          Masc_domain.task_status_to_string task.task_status)
     | None -> fail "rejected task disappeared");
    let queue () =
      match Keeper_event_queue_persistence.load_result
        ~base_path:config.base_path ~keeper_name:meta.name with
      | Error detail -> fail ("queue read failed: " ^ detail)
      | Ok queue -> Keeper_event_queue.to_list queue
    in
    let matching_rejection stimulus =
      match stimulus.Keeper_event_queue.payload with
      | Keeper_event_queue.Completion_authority_rejected rejection ->
        String.equal rejection.car_verification_id first_id
      | _ -> false
    in
    await_condition ~clock "durable rejection delivery"
      (fun () -> List.exists matching_rejection (queue ()));
    let stimulus =
      match List.filter matching_rejection (queue ()) with
      | [ stimulus ] -> stimulus
      | rows -> failf "expected one rejection row, got %d" (List.length rows)
    in
    (match Masc.Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
     | Ok (Some { event_kind = Masc.Keeper_world_observation.Completion_authority_rejected rejection; _ }) ->
       check string "world event task" "task-001" rejection.car_task_id;
       check string "world event verification" first_id rejection.car_verification_id;
       check string "world event reason" reason rejection.car_reason
     | _ -> fail "delivered rejection did not reach the world observation");
    reviewer_response := Reviewer_verdict (AR.Approve "solid evidence");
    let revised_refs = [ "note:corrected completion evidence after rejection" ] in
    let second = attempt_done ~config ~meta ~publication_recovery ~ctx_work
      ~task_id:"task-001" ~result:"Corrected the rejected evidence"
      ~evidence_refs:revised_refs () in
    check string "changed evidence submission succeeds" "success"
      (outcome_label second.KTE.disposition);
    let second_id =
      match !submitted_verifications with
      | [ second; first ] ->
        check string "original submission preserved" first_id first;
        check bool "resubmission has a fresh verification identity" false
          (String.equal second first);
        second
      | ids -> failf "expected two submissions, got %d" (List.length ids)
    in
    let matching_approval stimulus =
      match stimulus.Keeper_event_queue.payload with
      | Keeper_event_queue.Task_outcome outcome ->
        String.equal outcome.to_verification_id second_id
      | _ -> false
    in
    await_condition ~clock "durable approval delivery"
      (fun () -> List.exists matching_approval (queue ()));
    check_submitted_evidence config second_id
      (revised_refs @ [ "note:Corrected the rejected evidence" ]);
    (match await_authority_verdict ~clock config "task-001" with
     | Some { task_status = Masc_domain.Done { assignee; _ }; _ } ->
       check string "approved task owner" meta.name assignee
     | Some task -> fail ("expected Done after second verdict, got " ^
                          Masc_domain.task_status_to_string task.task_status)
     | None -> fail "approved task disappeared");
    (* reviewer_calls records the response this harness handed back, so the
       second entry carries the approval text set above, not an empty one. *)
    check bool "both controlled verdicts actually ran" true
      (List.rev !reviewer_calls
       = [ Reviewer_verdict (AR.Reject reason)
         ; Reviewer_verdict (AR.Approve "solid evidence")
         ]))

(* Historical shape: keeper_task_done used to consult the reviewer inline and
   an unavailable evaluator rejected the call. The tool now only files
   evidence (submit_for_verification); the terminal verdict belongs to the
   completion authority, and with the evaluator unavailable none is issued —
   the run_completion_review error arm logs "task remains nonterminal" and
   emits no verdict. Fail-closed moved from the submission to the verdict:
   what must never happen is the task reaching Done without one. *)
let test_unavailable_evaluator_keeps_task_active () =
  with_ws "completion_llm_unavailable"
    (fun ~sw:_ ~net:_ ~clock ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"unavailable evaluator" ~priority:1
         ~description:"must stay active without an LLM verdict");
    let claim =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "self-claim succeeds" "success"
      (outcome_label claim.KTE.disposition);
    reviewer_response := Reviewer_unavailable;
    let result =
      attempt_done
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Completed the deliverable."
        ~evidence_refs:[]
        ()
    in
    check string "evidence submission succeeds without an inline verdict"
      "success"
      (outcome_label result.KTE.disposition);
    await_condition ~clock "unavailable evaluator invocation"
      (fun () -> !reviewer_calls <> []);
    check bool "controlled evaluator was unavailable" true
      (List.for_all (( = ) Reviewer_unavailable) !reviewer_calls);
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | None -> fail "task-001 missing after submit"
    | Some { task_status = Masc_domain.Done _; _ } ->
      fail
        "an unavailable evaluator must never let the task complete (fail-open)"
    | Some { task_status = Masc_domain.AwaitingVerification { assignee; _ }; _ }
      ->
      check string "submitter identity is preserved for the retry"
        meta.name assignee
    | Some { task_status; _ } ->
      fail
        ("task must park awaiting verification, got "
         ^ Masc_domain.task_status_to_string task_status))


(* Positive lifecycle control: a keeper claiming its own backlog task is
   accepted on the same dispatch path. *)
let test_legitimate_claim_succeeds () =
  with_ws "completion_trust_positive_claim"
    (fun ~sw:_ ~net:_ ~clock:_ ~config ~meta ~publication_recovery ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.name));
    ignore
      (Workspace.add_task config ~title:"claimable task" ~priority:1
         ~description:"unowned backlog work");
    let result =
      claim_via_dispatch ~config ~meta ~publication_recovery ~ctx_work
        ~task_id:"task-001"
    in
    check string "legitimate claim outcome" "success"
      (outcome_label result.KTE.disposition);
    match assignee_of config "task-001" with
    | Some assignee -> check string "claimed task is owned by the caller" meta.name assignee
    | None -> fail "task-001 must be Claimed/InProgress after a legitimate claim")

let () =
  let prompt_dir = Masc_test_deps.source_path "config/prompts" in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  Masc.Workspace_metric_hooks.install ();
  Masc.Keeper_task_owner_backend.install_hooks ();
  Masc_test_deps.init_unified_tool_registry ();
  Atomic.set Workspace_hooks.get_default_runtime_id_fn (fun () -> "test-evaluator-runtime");
  (* RFC-0361 D7(a): completion review resolves only the verifier_exact lane. *)
  Atomic.set
    Workspace_hooks.get_verifier_exact_lane_slot_ids_fn
    (fun () -> Ok [ "test-evaluator-runtime" ]);
  Atomic.set AR.run_llm_reviewer_fn reviewer;
  run "Completion_trust_harness"
    [ ( "completion_trust_dispatch_oracle"
      , [ test_case "non-owner completion is denied (ownership gate)" `Quick
            test_completion_denied_for_non_owner
        ; test_case "completion of an unclaimed task is denied" `Quick
            test_completion_denied_when_unclaimed
        ; test_case "short notes reach committed controlled approval"
            `Quick test_short_notes_without_evidence_follow_llm_approval
        ; test_case "rendered image submission reaches verifier HTTP request"
            `Quick test_rendered_image_reaches_verifier_http_request
        ; test_case "submitted evidence reaches committed controlled approval"
            `Quick test_completion_with_evidence_refs_succeeds
        ; test_case "delivered rejection, changed resubmission, committed approval"
            `Quick test_rejection_delivery_then_changed_submission_completes
        ; test_case "unavailable evaluator keeps task active"
            `Quick test_unavailable_evaluator_keeps_task_active
        ; test_case "legitimate self-claim is accepted (selectivity control)" `Quick
            test_legitimate_claim_succeeds
        ] )
    ]
