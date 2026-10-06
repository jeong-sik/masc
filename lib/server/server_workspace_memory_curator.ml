module Context = Workspace_memory_context
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Decision = Workspace_memory_decision
module Exact = Agent_core.Exact_output
module Runs = Exact_lane_run_registry

let lane_id = Standalone_lane.to_id Standalone_lane.Workspace_curator
let ( let* ) = Result.bind

let output_schema = Decision.output_schema

let validate ~selected ~ledger raw =
  let* assignments = Decision.decode ~selected raw in
  Ledger.apply ledger ~selected assignments
  |> Result.map_error Ledger.apply_error_to_string
  |> Result.map (fun _ -> raw)

(* The curator's flow callbacks never fail ([Ok ()]); their error type is
   string, which the renderer prints unchanged. *)
let flow_failure =
  Exact.flow_execution_error_to_string
    ~callback_error_to_string:Fun.id
    ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt

(* How the lane's HTTP slots ended when none of them answered. *)
type http_failure =
  | No_http_slot
  | Http_failed of string

(* The lane's HTTP slots, as one exact-output flow. *)
let execute_http ~(resolved : Runtime_exact_output_registry.resolved_lane) ~requirement
    ~rendered_prompt ~selected ~ledger =
  let failed result = Result.map_error (fun detail -> Http_failed detail) result in
  let rec candidates = function
    | [] -> Ok []
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      let* candidate = Exact.make_flow_candidate ~id:slot.slot_id
        ~admitted_target:slot.admitted_target
        |> Result.map_error (function Exact.Blank_flow_candidate_id -> "blank candidate identity") in
      let* rest = candidates rest in
      Ok (candidate :: rest)
  in
  (* Ordered here, not in [prepare_execution]: the declared order is part of
     the published configuration, and a rest must not change its identity. *)
  let* candidates =
    candidates (Runtime_exact_lane_backpressure.order resolved).selected_slots |> failed in
  let* first, rest = match candidates with
    | [] -> Error No_http_slot
    | first :: rest -> Ok (first, rest) in
  let messages = Agent_core.Types.[
    make_message ~role:User [Text rendered_prompt] ] in
  let* snapshot = Exact.snapshot_flow ~first ~rest ~messages requirement
    |> Result.map_error (function Exact.Duplicate_flow_candidate_id { candidate_id; _ } ->
      "duplicate candidate: " ^ candidate_id) |> failed in
  let* attempt = Exact.start_flow snapshot
    |> Result.map_error (function Exact.Flow_id_generation_failed detail -> detail) |> failed in
  match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | Some net, Some clock ->
    let validate success =
      let raw = (Exact.flow_success_output success).output in
      match validate ~selected ~ledger raw with
      | Ok _ -> Exact.Accept raw
      | Error detail -> Exact.Reject_and_advance detail in
    let flow = Exact.execute_flow_once ~net ~clock
       ~before_measurement_dispatch:(fun _ -> Ok ())
       ~on_measurement_terminal:(fun _ -> Ok ())
       ~before_dispatch:(fun _ -> Ok ())
       ~before_advance:(fun ~failed:_ ~next:_ -> Ok ()) ~validate attempt in
    Runtime_exact_lane_backpressure.observe ~resolved flow;
    (match flow with
     | Ok success ->
       let candidate = Exact.flow_success_candidate success.transport_success in
       Ok (success.accepted, candidate.visit.identity.candidate_id)
     | Error (Exact.Flow_execution_terminal { cause; _ }) ->
       Error (Http_failed (flow_failure cause))
     | Error (Exact.Flow_semantic_candidates_exhausted { rejections; _ }) ->
       Error (Http_failed (String.concat "; " (List.map (fun rejection -> rejection.Exact.rejection)
         (rejections.first :: rejections.rest)))))
  | _ -> Error (Http_failed "workspace curator execution context unavailable")

(* This lane requires a measured context window for every provider it can
   dispatch to. Official-client slots do not publish one, so they are refused
   by [prepare_execution] instead of silently exceeding the request bound. *)
let execute ~(resolved : Runtime_exact_output_registry.resolved_lane)
    ~rendered_prompt ~selected ~ledger =
  let requirement = Exact.make_output_requirement ~schema:output_schema
      ~minimum_guarantee:Exact.Json_syntax in
  match execute_http ~resolved ~requirement ~rendered_prompt ~selected ~ledger with
  | Ok answer -> Ok answer
  | Error No_http_slot -> Error "workspace curator has no admitted exact-output HTTP slot"
  | Error (Http_failed detail) -> Error detail

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

type execution =
  { configuration : Yojson.Safe.t
  ; max_input_bytes : int
  ; execute : rendered_prompt:string -> selected:Ledger.pending_fact list
      -> ledger:Ledger.t -> (Yojson.Safe.t * string, string) result
  }

let admitted_input_bytes (slot : Runtime_exact_output_registry.selected_slot) =
  let target = Exact.projection_target slot.admitted_target in
  match Llm_provider.Provider_config.context_window target.config, target.config.max_tokens with
  | Some window, Some output when window > output ->
    let schema_bytes = String.length (Yojson.Safe.to_string output_schema) in
    let available = window - output - schema_bytes in
    if available > 0 then Ok available else Error (slot.slot_id ^ " has no input room")
  | _ -> Error (slot.slot_id ^ " has no known context window and output budget")

let minimum_input_bytes slots =
  match slots with
  | [] -> Error "workspace curator needs a window-declared HTTP slot to bound its input"
  | first :: rest ->
    let* initial = admitted_input_bytes first in
    List.fold_left (fun result slot ->
      let* size = result in
      let* next = admitted_input_bytes slot in
      Ok (min size next)) (Ok initial) rest

let prepare_execution ~base_path =
  let* registry = Runtime_exact_output_registry.current ()
    |> Result.map_error Runtime_exact_output_registry.publication_error_to_string in
  let* resolved = Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error Runtime_exact_output_registry.lane_resolution_error_to_string in
  let* () = if resolved.cli_slots = [] then Ok ()
    else Error "workspace curator cannot bound official-client slots without a declared context window" in
  let* max_input_bytes = minimum_input_bytes resolved.selected_slots in
  let configuration = `Assoc
    [ "catalog_generation", `String (Runtime_exact_output_registry.catalog_generation_fingerprint registry)
    ; "slots", `List (List.map (fun (slot : Runtime_exact_output_registry.selected_slot) -> `String slot.slot_id) resolved.selected_slots)
    ; "cli_slots", `List (List.map (fun id -> `String id) resolved.cli_slots) ] in
  Ok { configuration; max_input_bytes;
       execute = execute ~resolved }

let run ~base_path ~prepare =
  let initial = Domain_pool_ref.submit_io_or_inline (fun () ->
    let* context = Context.collect ~base_path in
    let* ledger = Ledger.load ~base_path in
    let change = Ledger.reconcile ledger (Context.keepers context) in
    let* () = if change.vanished = [] then Ok ()
      else Ledger.save ~base_path change.ledger in
    Ok (context, change)) in
  match initial with
  | Error detail -> Log.Server.error "workspace curator inventory: %s" detail; false
  | Ok (_, { Ledger.new_facts = []; _ }) -> false
  | Ok (context, change) ->
    let prepared =
      let* execution = prepare () in
      let key = Prompt_names.workspace_memory_curator in
      let resolution = Prompt_registry.resolve_prompt key in
      let render json = Prompt_registry.render_resolved_prompt_template key resolution
        ["workspace_memory_changes", Yojson.Safe.to_string json] in
      let owner_count = List.length (Context.keepers context) in
      let* batch = Request.prepare ~max_input_bytes:execution.max_input_bytes
        ~neighbor_limit:(max 0 (owner_count - 1)) ~render ~ledger:change.ledger
        ~current:change.current_facts ~pending:change.new_facts
        |> Result.map_error Request.error_to_string in
      match batch with
      | None -> Error "workspace curator found pending facts but prepared no batch"
      | Some batch -> Ok (execution, resolution, batch)
    in
    (match prepared with
     | Error detail -> Log.Server.error "workspace curator request: %s" detail; false
     | Ok (execution, resolution, batch) ->
       let registry = Runs.global () in
       let run_id = Random_id.prefixed ~prefix:"workspace-curator-" ~bytes:16 in
       let started_at = Time_compat.now () in
       let monotonic_start = Mtime_clock.now () in
       let sha text = Digestif.SHA256.(digest_string text |> to_hex) in
       let input = `Assoc
         [ "context_sha256", `String (Context.fingerprint context)
         ; "ledger_before_sha256", `String (sha (Yojson.Safe.to_string (Ledger.to_json change.ledger)))
         ; "actual_input", batch.input
         ; "prompt", `Assoc
             [ "key", `String Prompt_names.workspace_memory_curator
             ; "source", `String (Prompt_registry.prompt_source_to_string resolution.source)
             ; "file_path", (match resolution.file_path with None -> `Null | Some path -> `String path)
             ; "effective_template", `String resolution.effective
             ; "rendered", `String batch.rendered_prompt
             ; "rendered_sha256", `String (sha batch.rendered_prompt) ]
         ; "output_schema", output_schema
         ; "configuration", execution.configuration
         ; "max_input_bytes", `Int execution.max_input_bytes
         ; "selected_count", `Int (List.length batch.selected) ] in
       (* Durable exact input precedes every provider call. *)
       Runs.register_running registry ~run_id ~lane:Runs.Workspace_curator
         ~actor:base_path ~started_at ~input:(Runs.Exact_input input);
       let complete ?selected_slot outcome output =
         match Runs.mark_completed registry ~run_id ~outcome
           ~elapsed_s:(Mtime.Span.to_float_ns (Mtime.span monotonic_start (Mtime_clock.now ())) /. 1e9)
           ~selected_slot ~output with
         | Ok () -> ()
         | Error error -> Log.Server.error "workspace curator completion %s: %s"
             run_id (Runs.completion_error_to_string error) in
       let fail detail =
         complete (Runs.Failed { code = "workspace_curator_failed"; detail })
           (`Assoc ["error", `String detail; "semantic_verification", `String "not_performed"]);
         false in
       try
         let result =
           let* raw, slot = execution.execute ~rendered_prompt:batch.rendered_prompt
             ~selected:batch.selected ~ledger:change.ledger in
           let* assignments = Decision.decode ~selected:batch.selected raw in
           let* updated = Ledger.apply change.ledger ~selected:batch.selected assignments
             |> Result.map_error Ledger.apply_error_to_string in
           let* () = Domain_pool_ref.submit_io_or_inline (fun () -> Ledger.save ~base_path updated) in
           Ok (raw, slot, updated) in
         (match result with
          | Error detail -> fail detail
          | Ok (raw, slot, updated) ->
            complete ~selected_slot:slot Runs.Succeeded
              (`Assoc [ "decision", raw
                      ; "ledger_sha256", `String (sha (Yojson.Safe.to_string (Ledger.to_json updated)))
                      ; "remaining_count", `Int (List.length batch.remaining)
                      ; "semantic_verification", `String "not_performed" ]);
            batch.remaining <> [])
       with
       | Eio.Cancel.Cancelled _ as error ->
         Eio.Cancel.protect (fun () -> complete Runs.Cancelled (`Assoc ["cancelled", `Bool true]));
         raise error
       | exn -> fail (Printexc.to_string exn))

let start_with ~sw ~base_path ~enabled ~prepare =
  let base_path = Unix.realpath base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  (* A missing directory is an inventory failure, not an empty workspace.
     Creating it here could reconcile every durable ledger member away. *)
  let keepers_dir = try Unix.realpath keepers_dir with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> keepers_dir in
  let owner = { mutex = Stdlib.Mutex.create (); pending = true; in_flight = false; stopped = false; wake = None } in
  let admitted = Stdlib.Mutex.protect owners_mutex (fun () ->
    if Hashtbl.mem owners base_path then false
    else (Hashtbl.add owners base_path owner; true)) in
  if admitted then (
    let unsubscribe_configuration =
      Runtime_exact_output_registry.subscribe_lane_changes ~lane_id (fun () ->
        (* fire-and-forget: publication signals the owner; it never runs a model here. *)
        ignore (wake owner)) in
    let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun event ->
      (* fire-and-forget: wake reports admission only; notifications have no response consumer. *)
      if String.equal event.keepers_dir keepers_dir then ignore (wake owner)) in
    Eio.Switch.on_release sw (fun () ->
      Stdlib.Mutex.protect owner.mutex (fun () -> owner.stopped <- true; owner.wake <- None);
      unsubscribe_configuration ();
      unsubscribe ();
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.remove owners base_path));
    (* A daemon, because the switch is this owner's whole life and the loop
       parks on [owner.wake] whenever the backlog is empty. Nothing wakes it on
       the way down: the release hook below sets [stopped] and drops the
       resolver without resolving it, and release hooks run only after every
       ordinary fiber has finished. [Switch.run] joins ordinary fibers when its
       body returns a value, so as an ordinary fiber this loop would hold the
       server's shutdown open. The daemon is cancelled instead, and a review
       cancelled mid-run already records itself. *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
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
          (* fire-and-forget: remaining facts queue another pulse; stopped owners need none. *)
          (try if enabled () && run ~base_path ~prepare then ignore (wake owner) with
           | Eio.Cancel.Cancelled _ as error -> raise error
           | exn -> Log.Server.error "workspace curator owner %s: %s" base_path (Printexc.to_string exn));
          Stdlib.Mutex.protect owner.mutex (fun () -> owner.in_flight <- false);
          drain () in
      drain ();
      `Stop_daemon))

let configured () = match Runtime_exact_output_registry.current () with
    | Error _ -> false
    | Ok registry ->
      (match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
       | Error (Runtime_exact_output_registry.Exact_lane_off _)
       | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) -> false
       | Ok _ | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) -> true)

let start ~sw ~base_path =
  start_with ~sw ~base_path ~enabled:configured ~prepare:(fun () -> prepare_execution ~base_path)

module For_testing = struct
  let execute = execute

  let start_with_enabled ~sw ~base_path ~enabled ~max_input_bytes ~execute =
    start_with ~sw ~base_path ~enabled
      ~prepare:(fun () -> Ok { configuration = `Assoc ["injected_runner", `Bool true];
                              max_input_bytes; execute })

  let start ~sw ~base_path ~max_input_bytes ~execute =
    start_with_enabled ~sw ~base_path ~enabled:(fun () -> true) ~max_input_bytes ~execute

  let start_configured ~sw ~base_path ~max_input_bytes ~execute =
    start_with_enabled ~sw ~base_path ~enabled:configured ~max_input_bytes ~execute

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
