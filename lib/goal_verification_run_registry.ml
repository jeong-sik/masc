type review_kind = Proof

type outcome =
  | Reviewed
  | Committed
  | Deferred of
      { detail : string }
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      ; tools : Verification_run_registry.tool_observation list
      }

type run =
  { run_id : string
  ; goal_id : string
  ; review_kind : review_kind
  ; authority_actor : string
  ; started_at : float
  ; status : run_status
  }

let storage_filename = "goal-verification-runs.jsonl"

let review_kind_label = function
  | Proof -> "proof"
;;

let review_kind_of_label = function
  | "proof" -> Ok Proof
  | label -> Error (Printf.sprintf "unknown Goal review kind %S" label)
;;

let outcome_label = function
  | Reviewed -> "reviewed"
  | Committed -> "committed"
  | Deferred _ -> "deferred"
  | Raised _ -> "raised"
  | Review_cancelled _ -> "review_cancelled"
;;

module Payload = struct
  type registration =
    { goal_id : string
    ; review_kind : review_kind
    ; authority_actor : string
    }

  type completion =
    { outcome : outcome
    ; evaluator_runtime : string option
    ; elapsed_s : float
    ; tools : Verification_run_registry.tool_observation list
    }

  let name = "goal_verification_run_registry"
  let running_noun = "Goal review(s)"
  let restart_reason = "Goal review fibers do not survive server restart"
  let replayed_running_completion = None
  (* Nothing here is large enough to be worth re-reading from disk: this
     registry's live share is under a megabyte. *)
  let shed_registration r = r
  let shed_completion c = c
  let completed_retention = `Latest 64
  let retention_group = None

  let registration_to_yojson registration =
    `Assoc
      [ "goal_id", `String registration.goal_id
      ; "review_kind", `String (review_kind_label registration.review_kind)
      ; "authority_actor", `String registration.authority_actor
      ]
  ;;

  let registration_of_yojson json =
    let open Result.Syntax in
    let* fields = Run_registry_core.Json.object_fields json in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:[ "goal_id"; "review_kind"; "authority_actor" ]
        fields
    in
    let* goal_id = Run_registry_core.Json.string_field "goal_id" fields in
    let* review_kind = Run_registry_core.Json.string_field "review_kind" fields in
    let* review_kind = review_kind_of_label review_kind in
    let* authority_actor =
      Run_registry_core.Json.string_field "authority_actor" fields
    in
    Ok { goal_id; review_kind; authority_actor }
  ;;

  let completion_to_yojson completion =
    let outcome_fields =
      match completion.outcome with
      | Reviewed -> []
      | Committed -> []
      | Deferred { detail } -> [ "detail", `String detail ]
      | Raised { detail } -> [ "detail", `String detail ]
      | Review_cancelled { detail } -> [ "detail", `String detail ]
    in
    `Assoc
      ([ "outcome", `String (outcome_label completion.outcome)
       ; "elapsed_s", `Float completion.elapsed_s
       ; ( "tools"
         , `List
             (List.map
                Verification_run_registry.tool_observation_to_yojson
                completion.tools) )
       ]
       @ outcome_fields
       @
       match completion.evaluator_runtime with
       | None -> []
       | Some runtime -> [ "evaluator_runtime", `String runtime ])
  ;;

  let completion_of_yojson json =
    let open Result.Syntax in
    let* fields = Run_registry_core.Json.object_fields json in
    let* outcome_label = Run_registry_core.Json.string_field "outcome" fields in
    let detail_fields =
      match outcome_label with
      | "reviewed" -> Ok []
      | "committed" -> Ok []
      | "deferred" -> Ok [ "detail" ]
      | "raised" -> Ok [ "detail" ]
      | label -> Error (Printf.sprintf "unknown Goal review outcome %S" label)
    in
    let* detail_fields = detail_fields in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:([ "outcome"; "elapsed_s"; "tools" ] @ detail_fields)
        ~optional:[ "evaluator_runtime" ]
        fields
    in
    let* elapsed_s = Run_registry_core.Json.float_field "elapsed_s" fields in
    let* evaluator_runtime =
      Run_registry_core.Json.optional_string_field "evaluator_runtime" fields
    in
    let* tools_json =
      match List.assoc_opt "tools" fields with
      | Some (`List tools) -> Ok tools
      | Some _ -> Error "field tools must be an array"
      | None -> Error "missing field tools"
    in
    let rec parse_tools acc = function
      | [] -> Ok (List.rev acc)
      | tool :: rest ->
        let* tool = Verification_run_registry.tool_observation_of_yojson tool in
        parse_tools (tool :: acc) rest
    in
    let* tools = parse_tools [] tools_json in
    let* outcome =
      match outcome_label with
      | "reviewed" -> Ok Reviewed
      | "committed" -> Ok Committed
      | "deferred" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Deferred { detail })
      | "raised" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Raised { detail })
      | "review_cancelled" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Review_cancelled { detail })
      | label -> Error (Printf.sprintf "unknown Goal review outcome %S" label)
    in
    Ok { outcome; evaluator_runtime; elapsed_s; tools }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t = Store.t

let create = Store.create
let replay = Store.replay
let max_completed_retained = Store.max_completed_retained
let cut_replay_log = Store.cut_replay_log
let change_observer_fn : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let notify_changed () =
  try (Atomic.get change_observer_fn) () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Task.warn
      "goal_verification_run_registry change observer failed: %s"
      (Printexc.to_string exn)
;;

let register_running t ~run_id ~goal_id ~review_kind ~authority_actor ~started_at =
  Store.register
    t
    ~id:run_id
    ~started_at
    ~registration:{ Payload.goal_id; review_kind; authority_actor };
  notify_changed ()
;;

let mark_completed t ~run_id ~outcome ~tools ?evaluator_runtime ~elapsed_s () =
  let completion = { Payload.outcome; evaluator_runtime; elapsed_s; tools } in
  match Store.complete t ~id:run_id ~completion with
  | `Completed -> notify_changed ()
  | `Unknown -> ()
  | `Persistence_failed failure -> raise (Sys_error failure.detail)
;;

let run_of_entry (entry : Store.entry) =
  let status =
    match entry.status with
    | Store.Running -> Running
    | Store.Completed completion ->
      Completed
        { outcome = completion.outcome
        ; evaluator_runtime = completion.evaluator_runtime
        ; elapsed_s = completion.elapsed_s
        ; tools = completion.tools
        }
  in
  { run_id = entry.id
  ; goal_id = entry.registration.goal_id
  ; review_kind = entry.registration.review_kind
  ; authority_actor = entry.registration.authority_actor
  ; started_at = entry.started_at
  ; status
  }
;;

let list_runs t = List.map run_of_entry (Store.list_entries t)
let get t ~run_id = Option.map run_of_entry (Store.get t ~id:run_id)

let status_label = function
  | Running -> "running"
  | Completed { outcome; _ } -> outcome_label outcome
;;

let run_to_yojson run =
  let completion_fields =
    match run.status with
    | Running -> []
    | Completed { outcome; evaluator_runtime; elapsed_s; tools } ->
      let detail_fields =
        match outcome with
        | Reviewed -> []
        | Committed -> []
        | Deferred { detail } -> [ "detail", `String detail ]
        | Raised { detail } -> [ "detail", `String detail ]
        | Review_cancelled { detail } -> [ "detail", `String detail ]
      in
      [ "elapsed_s", `Float elapsed_s
      ; ( "tools"
        , `List
            (List.map
               Verification_run_registry.tool_observation_to_yojson
               tools) )
      ]
      @ detail_fields
      @
      match evaluator_runtime with
      | None -> []
      | Some runtime -> [ "evaluator_runtime", `String runtime ]
  in
  `Assoc
    ([ "run_id", `String run.run_id
     ; "goal_id", `String run.goal_id
     ; "review_kind", `String (review_kind_label run.review_kind)
     ; "authority_actor", `String run.authority_actor
     ; "started_at", `Float run.started_at
     ; "status", `String (status_label run.status)
     ]
     @ completion_fields)
;;

type global_install_error = Already_installed

module Global = Run_registry_core.Global (struct
    type nonrec t = t

    let initial = create ()
  end)

let global = Global.current

let install_global registry =
  match Global.install registry with
  | Ok () -> Ok ()
  | Error Global.Already_installed -> Error Already_installed
;;
