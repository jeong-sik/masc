type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction

type outcome =
  | Succeeded
  | Cancelled
  | Failed of
      { code : string
      ; detail : string
      }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; elapsed_s : float
      ; output : Yojson.Safe.t
      }

type run_input = Exact_input of Yojson.Safe.t

type run =
  { run_id : string
  ; lane : lane
  ; subject_id : string
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  }

let lane_key = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
  | Compaction -> "compaction_exact"
;;

let lane_of_key = function
  | "librarian_exact" -> Ok Librarian
  | "hitl_auto_judge" -> Ok Hitl_auto_judge
  | "board_attention_exact" -> Ok Board_attention
  | "compaction_exact" -> Ok Compaction
  | value -> Error (Printf.sprintf "unknown exact lane %S" value)
;;

let outcome_label = function
  | Succeeded -> "succeeded"
  | Cancelled -> "cancelled"
  | Failed _ -> "failed"
;;

let input_to_yojson = function
  | Exact_input payload -> `Assoc [ "kind", `String "exact"; "payload", payload ]
;;

let input_of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = Run_registry_core.Json.object_fields json in
  let* kind = Run_registry_core.Json.string_field "kind" fields in
  match kind with
  | "exact" ->
    let* () = Run_registry_core.Json.exact_fields ~required:[ "kind"; "payload" ] fields in
    let* payload =
      List.assoc_opt "payload" fields |> Option.to_result ~none:"missing field payload"
    in
    Ok (Exact_input payload)
  | value -> Error (Printf.sprintf "unknown exact lane input kind %S" value)
;;

module Payload = struct
  type registration =
    { lane : lane
    ; subject_id : string
    ; actor : string
    ; input : run_input
    }

  type completion =
    { outcome : outcome
    ; elapsed_s : float
    ; output : Yojson.Safe.t
    }

  let name = "exact_lane_run_registry"
  let running_noun = "exact lane run(s)"
  let restart_reason = "exact-output fibers do not survive server restart"
  let completed_retention = `All

  let registration_to_yojson registration =
    `Assoc
      [ "lane", `String (lane_key registration.lane)
      ; "subject_id", `String registration.subject_id
      ; "actor", `String registration.actor
      ; "input", input_to_yojson registration.input
      ]
  ;;

  let registration_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:[ "lane"; "subject_id"; "actor"; "input" ]
        fields
    in
    let* lane_key = Run_registry_core.Json.string_field "lane" fields in
    let* lane = lane_of_key lane_key in
    let* subject_id = Run_registry_core.Json.string_field "subject_id" fields in
    let* actor = Run_registry_core.Json.string_field "actor" fields in
    let* input =
      match List.assoc_opt "input" fields with
      | Some value -> input_of_yojson value
      | None -> Error "missing field input"
    in
    Ok { lane; subject_id; actor; input }
  ;;

  let completion_to_yojson completion =
    let detail =
      match completion.outcome with
      | Succeeded | Cancelled -> []
      | Failed { code; detail } ->
        [ "code", `String code; "detail", `String detail ]
    in
    `Assoc
      ([ "outcome", `String (outcome_label completion.outcome)
       ; "elapsed_s", `Float completion.elapsed_s
       ; "output", completion.output
       ]
       @ detail)
  ;;

  let completion_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* label = Run_registry_core.Json.string_field "outcome" fields in
    let detail_fields =
      match label with
      | "succeeded" | "cancelled" -> Ok []
      | "failed" -> Ok [ "code"; "detail" ]
      | value -> Error (Printf.sprintf "unknown exact lane outcome %S" value)
    in
    let* detail_fields = detail_fields in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:([ "outcome"; "elapsed_s"; "output" ] @ detail_fields)
        fields
    in
    let* elapsed_s = Run_registry_core.Json.float_field "elapsed_s" fields in
    let* output =
      match List.assoc_opt "output" fields with
      | Some value -> Ok value
      | None -> Error "missing field output"
    in
    let* outcome =
      match label with
      | "succeeded" -> Ok Succeeded
      | "cancelled" -> Ok Cancelled
      | "failed" ->
        let* code = Run_registry_core.Json.string_field "code" fields in
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Failed { code; detail })
      | value -> Error (Printf.sprintf "unknown exact lane outcome %S" value)
    in
    Ok { outcome; elapsed_s; output }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t = Store.t

type completion_error =
  | Unknown_run
  | Persistence_failed of string

let completion_error_to_string = function
  | Unknown_run -> "completion referenced an unknown exact-lane run"
  | Persistence_failed detail -> detail
;;

let storage_filename = "exact-lane-runs-v3.jsonl"

let change_observer_fn : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let notify_changed () =
  try (Atomic.get change_observer_fn) () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "exact_lane_run_registry change observer failed: %s"
      (Printexc.to_string exn)
;;

let create = Store.create
let replay = Store.replay
let register_running t ~run_id ~lane ~subject_id ~actor ~started_at ~input =
  Store.register
    t
    ~id:run_id
    ~started_at
    ~registration:{ Payload.lane; subject_id; actor; input };
  notify_changed ()
;;

let mark_completed t ~run_id ~outcome ~elapsed_s ~output =
  let completion = { Payload.outcome; elapsed_s; output } in
  match Store.complete t ~id:run_id ~completion with
  | `Completed ->
    notify_changed ();
    Ok ()
  | `Unknown -> Error Unknown_run
  | `Persistence_failed detail -> Error (Persistence_failed detail)
;;

let run_of_entry (entry : Store.entry) =
  let status =
    match entry.status with
    | Store.Running -> Running
    | Store.Completed completion ->
      Completed
        { outcome = completion.outcome
        ; elapsed_s = completion.elapsed_s
        ; output = completion.output
        }
  in
  { run_id = entry.id
  ; lane = entry.registration.lane
  ; subject_id = entry.registration.subject_id
  ; actor = entry.registration.actor
  ; started_at = entry.started_at
  ; input = entry.registration.input
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
  let base =
    [ "run_id", `String run.run_id
    ; "lane", `String (lane_key run.lane)
    ; "subject_id", `String run.subject_id
    ; "actor", `String run.actor
    ; "started_at", `Float run.started_at
    ; "input", input_to_yojson run.input
    ; "status", `String (status_label run.status)
    ]
  in
  let completion =
    match run.status with
    | Running -> []
    | Completed { outcome; elapsed_s; output } ->
      let detail =
        match outcome with
        | Succeeded | Cancelled -> []
        | Failed { code; detail } ->
          [ "code", `String code; "detail", `String detail ]
      in
      [ "elapsed_s", `Float elapsed_s; "output", output ] @ detail
  in
  `Assoc (base @ completion)
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
