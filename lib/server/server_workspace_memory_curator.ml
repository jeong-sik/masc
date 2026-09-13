module Context = Workspace_memory_context
module Proposals = Workspace_memory_proposal
module Exact = Agent_core.Exact_output
module Runs = Exact_lane_run_registry

let lane_id = Runs.lane_key Runs.Workspace_curator
let ( let* ) = Result.bind

let object_schema fields =
  `Assoc [ "type", `String "object"; "properties", `Assoc fields;
           "required", `List (List.map (fun (key, _) -> `String key) fields);
           "additionalProperties", `Bool false ]

let text_schema = `Assoc [ "type", `String "string"; "minLength", `Int 1 ]
let array_schema items = `Assoc [ "type", `String "array"; "items", items ]
let refs_schema =
  `Assoc [ "type", `String "array"; "items", text_schema;
           "minItems", `Int 1; "uniqueItems", `Bool true ]

let output_schema =
  object_schema
    [ "shared_claims", array_schema (object_schema
        [ "claim", text_schema; "source_ids", refs_schema ])
    ; "conflicts", array_schema (object_schema
        [ "description", text_schema; "source_ids", refs_schema ])
    ; "excluded", array_schema (object_schema
        [ "source_id", text_schema; "reason", text_schema ]) ]

let flow_failure = function
  | Exact.Flow_candidates_exhausted { rejection; evidence } ->
    Keeper_exact_flow_detail.candidates_exhausted_detail ~rejection ~evidence
  | Exact.Flow_exact_execution_failed { candidate; cause; evidence } ->
    Keeper_exact_flow_detail.execution_failure_detail ~candidate ~cause ~evidence
  | Exact.Flow_attempt_already_started evidence ->
    "attempt already started: " ^ Keeper_exact_flow_detail.flow_evidence_detail evidence
  | Exact.Flow_attempt_start_failed { cause = Call_id_generation_failed detail; _ }
  | Exact.Flow_measurement_start_failed { cause = Measurement_operation_id_generation_failed detail; _ } -> detail
  | Exact.Flow_measurement_start_failed { cause = Measurement_clock_required_for_timeout; _ } ->
    "measurement clock required for provider timeout"
  | Exact.Flow_before_measurement_dispatch_callback_failed { cause; _ }
  | Exact.Flow_measurement_terminal_callback_failed { cause; _ }
  | Exact.Flow_before_dispatch_callback_failed { cause; _ }
  | Exact.Flow_before_advance_callback_failed { cause; _ } -> cause

let execute ~(resolved : Runtime_exact_output_registry.resolved_lane) ~rendered_prompt context =
  (* This workspace owner has no Keeper identity or Keeper CLI sandbox. Refuse
     an unsupported CLI tail explicitly instead of silently skipping it. *)
  let* () = match resolved.cli_slots with
    | [] -> Ok ()
    | _ -> Error "workspace curator requires admitted exact-output slots; CLI tails are not supported" in
  let rec candidates = function
    | [] -> Ok []
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      let* candidate = Exact.make_flow_candidate ~id:slot.slot_id
        ~admitted_target:slot.admitted_target
        |> Result.map_error (function Exact.Blank_flow_candidate_id -> "blank candidate identity") in
      let* rest = candidates rest in
      Ok (candidate :: rest)
  in
  let* candidates = candidates resolved.selected_slots in
  let* first, rest = match candidates with
    | [] -> Error "workspace curator has no admitted exact-output slot"
    | first :: rest -> Ok (first, rest) in
  let messages = Agent_core.Types.[
    make_message ~role:User [Text rendered_prompt] ] in
  let requirement = Exact.make_output_requirement ~schema:output_schema
      ~minimum_guarantee:Exact.Json_syntax in
  let* snapshot = Exact.snapshot_flow ~first ~rest ~messages requirement
    |> Result.map_error (function Exact.Duplicate_flow_candidate_id { candidate_id; _ } ->
      "duplicate candidate: " ^ candidate_id) in
  let* attempt = Exact.start_flow snapshot
    |> Result.map_error (function Exact.Flow_id_generation_failed detail -> detail) in
  match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | Some net, Some clock ->
    let validate success =
      let raw = (Exact.flow_success_output success).output in
      match Proposals.decode (Context.proposal_json context raw) with
      | Ok _ -> Exact.Accept raw
      | Error detail -> Exact.Reject_and_advance detail in
    (match Exact.execute_flow_once ~net ~clock
       ~before_measurement_dispatch:(fun _ -> Ok ())
       ~on_measurement_terminal:(fun _ -> Ok ())
       ~before_dispatch:(fun _ -> Ok ())
       ~before_advance:(fun ~failed:_ ~next:_ -> Ok ()) ~validate attempt with
     | Ok success ->
       let candidate = Exact.flow_success_candidate success.transport_success in
       Ok (success.accepted, candidate.visit.identity.candidate_id)
     | Error (Exact.Flow_execution_terminal { cause; _ }) -> Error (flow_failure cause)
     | Error (Exact.Flow_semantic_candidates_exhausted { rejections; _ }) ->
       Error (String.concat "; " (List.map (fun rejection -> rejection.Exact.rejection)
         (rejections.first :: rejections.rest))))
  | _ -> Error "workspace curator execution context unavailable"

type owner =
  { mutex : Stdlib.Mutex.t
  ; mutable pending : bool
  ; mutable in_flight : bool
  ; mutable stopped : bool
  ; mutable wake : unit Eio.Promise.u option
  }

let owners_mutex = Stdlib.Mutex.create ()
let owners : (string, owner) Hashtbl.t = Hashtbl.create 4

type refresh = Queued | No_owner | Unavailable of string

let wake owner =
  let queued, resolver = Stdlib.Mutex.protect owner.mutex (fun () ->
    if owner.stopped then false, None else (
      owner.pending <- true;
      let resolver = owner.wake in owner.wake <- None; true, resolver)) in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver;
  if queued then Queued else No_owner

let request ~base_path =
  match Unix.realpath base_path with
  | base_path ->
    let owner = Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path) in
    (match owner with None -> No_owner | Some owner -> wake owner)
  | exception Unix.Unix_error (error, operation, _) ->
    Unavailable (operation ^ ": " ^ Unix.error_message error)

let store_error = function Proposals.Invalid detail | Proposals.Unavailable detail -> detail

let already_published ~base_path ~request_identity registry =
  let rec find = function
    | [] -> Ok false
    | (summary : Runs.run) :: rest ->
      if summary.lane <> Runs.Workspace_curator || not (String.equal summary.actor base_path)
      then find rest
      else match Runs.get registry ~run_id:summary.run_id with
      | Some { input = Runs.Exact_input (`Assoc input);
               status = Runs.Completed { outcome = Runs.Succeeded; output = `Assoc output; _ }; _ }
        when List.assoc_opt "request_identity" input = Some request_identity ->
        (match List.assoc_opt "proposal_id" output, List.assoc_opt "proposal" output with
         | Some (`String id), Some expected ->
           let* proposal = Proposals.read ~base_path ~id |> Result.map_error store_error in
           (match proposal with
            | None -> find rest
            | Some proposal when Yojson.Safe.equal (Proposals.to_json proposal) expected ->
              let* () = Workspace_memory_publication.publish ~base_path ~proposal_id:id in
              Ok true
            | Some _ -> Error "saved proposal differs from the successful exact-run output")
         | _ -> find rest)
      | _ -> find rest
  in
  find (Runs.list_runs registry)

type execution =
  { configuration : Yojson.Safe.t
  ; execute : rendered_prompt:string -> Context.t -> (Yojson.Safe.t * string, string) result
  }

let prepare_execution () =
  let* registry = Runtime_exact_output_registry.current ()
    |> Result.map_error Runtime_exact_output_registry.publication_error_to_string in
  let* resolved = Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error Runtime_exact_output_registry.lane_resolution_error_to_string in
  let configuration = `Assoc
    [ "catalog_generation", `String (Runtime_exact_output_registry.catalog_generation_fingerprint registry)
    ; "slots", `List (List.map (fun (slot : Runtime_exact_output_registry.selected_slot) -> `String slot.slot_id) resolved.selected_slots)
    ; "cli_slots", `List (List.map (fun id -> `String id) resolved.cli_slots) ] in
  Ok { configuration; execute = execute ~resolved }

let run ~base_path ~prepare =
  let registry = Runs.global () in
  let run_id = Random_id.prefixed ~prefix:"workspace-curator-" ~bytes:16 in
  let started_at = Time_compat.now () in
  let monotonic_start = Mtime_clock.now () in
  let context = Domain_pool_ref.submit_io_or_inline (fun () -> Context.collect ~base_path) in
  let prompt = match context with
    | Error detail -> Error detail
    | Ok context -> Prompt_registry.resolve_and_render_prompt_template
        Prompt_names.workspace_memory_curator
        ["workspace_memory_inventory", Yojson.Safe.to_string (Context.to_json context)] in
  let prompt_json = match prompt with
    | Error detail -> `Assoc ["render_error", `String detail]
    | Ok (resolution, rendered) -> `Assoc
        [ "key", `String Prompt_names.workspace_memory_curator
        ; "source", `String (Prompt_registry.prompt_source_to_string resolution.source)
        ; "file_path", (match resolution.file_path with None -> `Null | Some path -> `String path)
        ; "effective_template", `String resolution.effective
        ; "rendered", `String rendered
        ; "rendered_sha256", `String Digestif.SHA256.(digest_string rendered |> to_hex) ] in
  let execution = prepare () in
  let request_identity =
    let* context = context in
    let* _, rendered = prompt in
    let* execution = execution in
    Ok (`Assoc [ "context_sha256", `String (Context.fingerprint context);
                 "rendered_prompt_sha256", `String Digestif.SHA256.(digest_string rendered |> to_hex);
                 "output_schema", output_schema; "configuration", execution.configuration ]) in
  let identity_json = match request_identity with Ok json -> json | Error detail -> `Assoc ["error", `String detail] in
  let input = match context with
    | Ok context -> `Assoc [ "context_sha256", `String (Context.fingerprint context);
                            "actual_input", Context.to_json context;
                            "prompt", prompt_json; "output_schema", output_schema; "request_identity", identity_json ]
    | Error detail -> `Assoc [ "collection_error", `String detail ] in
  let result = match context with
    | Error detail -> Error detail
    | Ok context ->
      let* request_identity = request_identity in
      let* published = Domain_pool_ref.submit_io_or_inline (fun () -> already_published ~base_path ~request_identity registry) in
      Ok (context, published) in
  match result with
  | Ok (_, true) -> ()
  | result ->
    (* Disk-backed registration commits before publication and raises on write
       failure. No provider call is reachable before exact input is durable. *)
    Runs.register_running registry ~run_id ~lane:Runs.Workspace_curator
      ~actor:base_path ~started_at ~input:(Runs.Exact_input input);
    let complete ?selected_slot outcome output =
      match Runs.mark_completed registry ~run_id ~outcome
        ~elapsed_s:(Mtime.Span.to_float_ns (Mtime.span monotonic_start (Mtime_clock.now ())) /. 1e9) ~selected_slot ~output with
      | Ok () -> ()
      | Error error -> Log.Server.error "workspace curator completion %s: %s"
          run_id (Runs.completion_error_to_string error) in
    let fail detail = complete (Runs.Failed { code = "workspace_curator_failed"; detail })
        (`Assoc [ "error", `String detail; "semantic_verification", `String "not_performed" ]) in
    (try
       let result =
         let* context, _ = result in
         let* _, rendered_prompt = prompt in
         let* execution = execution in
         let* raw, slot = execution.execute ~rendered_prompt context in
         let envelope = Context.proposal_json context raw in
         let* id, stored = Domain_pool_ref.submit_io_or_inline (fun () -> Proposals.submit ~base_path envelope)
           |> Result.map_error store_error in
         let* () = Domain_pool_ref.submit_io_or_inline (fun () ->
           Workspace_memory_publication.publish ~base_path ~proposal_id:id) in
         Ok (id, Proposals.to_json stored, slot) in
       match result with
       | Error detail -> fail detail
       | Ok (id, envelope, slot) ->
         complete ~selected_slot:slot Runs.Succeeded
           (`Assoc [ "proposal_id", `String id; "proposal", envelope;
                     "semantic_verification", `String "not_performed" ])
     with
     | Eio.Cancel.Cancelled _ as error ->
       Eio.Cancel.protect (fun () -> complete Runs.Cancelled (`Assoc [ "cancelled", `Bool true ]));
       raise error
     | exn -> fail (Printexc.to_string exn))

let start_with ~sw ~base_path ~enabled ~prepare =
  let base_path = Unix.realpath base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let keepers_dir = Unix.realpath keepers_dir in
  let owner = { mutex = Stdlib.Mutex.create (); pending = true; in_flight = false; stopped = false; wake = None } in
  let admitted = Stdlib.Mutex.protect owners_mutex (fun () ->
    if Hashtbl.mem owners base_path then false
    else (Hashtbl.add owners base_path owner; true)) in
  if admitted then (
    let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun event ->
      (* Fire-and-forget notification: wake only acknowledges queue admission;
         see the owner loop for execution outcomes. A stopped owner needs no wake. *)
      if String.equal event.keepers_dir keepers_dir then ignore (wake owner)) in
    Eio.Switch.on_release sw (fun () ->
      Stdlib.Mutex.protect owner.mutex (fun () -> owner.stopped <- true; owner.wake <- None);
      unsubscribe ();
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.remove owners base_path));
    Eio.Fiber.fork ~sw (fun () ->
      let rec drain () =
        let next = Stdlib.Mutex.protect owner.mutex (fun () ->
          if owner.stopped then `Stop
          else if owner.pending then (owner.pending <- false; owner.in_flight <- true; `Run)
          else let promise, resolver = Eio.Promise.create () in
            owner.wake <- Some resolver; `Wait promise) in
        match next with
        | `Stop -> ()
        | `Wait promise -> Eio.Promise.await promise; drain ()
        | `Run ->
          (try if enabled () then run ~base_path ~prepare with
           | Eio.Cancel.Cancelled _ as error -> raise error
           | exn -> Log.Server.error "workspace curator owner %s: %s" base_path (Printexc.to_string exn));
          Stdlib.Mutex.protect owner.mutex (fun () -> owner.in_flight <- false);
          drain () in
      drain ()))

let start ~sw ~base_path =
  let enabled () = match Runtime_exact_output_registry.current () with
    | Error _ -> false
    | Ok registry ->
      (match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
       | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) -> false
       | Ok _ | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) -> true) in
  start_with ~sw ~base_path ~enabled ~prepare:prepare_execution

module For_testing = struct
  let start ~sw ~base_path ~execute =
    start_with ~sw ~base_path ~enabled:(fun () -> true)
      ~prepare:(fun () -> Ok { configuration = `Assoc ["injected_runner", `Bool true];
                              execute })

  let find ~base_path =
    let base_path = Unix.realpath base_path in
    Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)

  let is_idle ~base_path = match find ~base_path with
    | None -> true
    | Some owner -> Stdlib.Mutex.protect owner.mutex (fun () -> not owner.pending && not owner.in_flight)

  let stop ~base_path = Option.iter (fun owner ->
    let resolver = Stdlib.Mutex.protect owner.mutex (fun () ->
      owner.stopped <- true;
      let resolver = owner.wake in owner.wake <- None; resolver) in
    Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver) (find ~base_path)
end
