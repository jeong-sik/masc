type review_kind = Proof

type evaluated_verdict = Approved of { reason : string } | Rejected of { reason : string }

type outcome =
  | Reviewed
  | Committed
  | Superseded of { detail : string }
  | Deferred of
      { detail : string }
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluated_verdict : evaluated_verdict option
      ; evaluator_runtime : string option
      ; elapsed_s : float
      ; tools : Verification_run_registry.tool_observation list
      }

type run =
  { run_id : string
  ; goal_id : string
  ; request_id : string
  ; criterion : Goal_store.criterion
  ; review_kind : review_kind
  ; authority_actor : string
  ; started_at : float
  ; status : run_status
  }

(* RFC-0444 §2.3 row 7: a verifier scan the goal store refused is a row of
   this registry too. It reviews nothing — no goal, no request, no criterion,
   no model — so it is not a [run] with blanks in those members but its own
   arm, carrying the whole [Goal_store.unavailable] value the scan saw. *)
type row =
  | Review of run
  | Scan_skipped of
      { run_id : string
      ; started_at : float
      ; unavailable : Goal_store.unavailable
      }

let storage_filename = "goal-verification-runs.jsonl"

(* The token every stored event and every served row carries in [kind]. One
   closed set, spelled once; the parsers below match on exactly these. *)
type row_kind = Review_kind | Scan_skipped_kind

let row_kind_label = function
  | Review_kind -> "review"
  | Scan_skipped_kind -> "scan_skipped"
;;

let row_kind_of_label = function
  | "review" -> Ok Review_kind
  | "scan_skipped" -> Ok Scan_skipped_kind
  | label -> Error (Printf.sprintf "unknown Goal verification row kind %S" label)
;;

let kind_field kind = "kind", `String (row_kind_label kind)

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
  | Superseded _ -> "superseded"
  | Deferred _ -> "deferred"
  | Raised _ -> "raised"
  | Review_cancelled _ -> "review_cancelled"
;;

module Payload = struct
  type review =
    { goal_id : string
    ; request_id : string
    ; criterion : Goal_store.criterion
    ; review_kind : review_kind
    ; authority_actor : string
    }

  (* A skipped scan is registered and completed in one call
     ([record_scan_skipped]); the completion carries nothing, it only makes
     the row terminal so replay keeps it. *)
  type registration =
    | Review_registration of review
    | Scan_skipped_registration of Goal_store.unavailable

  type review_completion =
    { outcome : outcome
    ; evaluated_verdict : evaluated_verdict option
    ; evaluator_runtime : string option
    ; elapsed_s : float
    ; tools : Verification_run_registry.tool_observation list
    }

  type completion =
    | Review_completion of review_completion
    | Scan_skipped_completion

  let name = "goal_verification_run_registry"
  let running_noun = "Goal review(s)"
  let restart_reason = "Goal review fibers do not survive server restart"
  let replayed_running_completion = None
  (* Nothing here is large enough to be worth re-reading from disk: this
     registry's live share is under a megabyte. *)
  let shed_registration r = r
  let shed_completion c = c
  let completed_retention = `Latest 64

  (* Per kind: a store that stays unreadable produces a skipped-scan row per
     wake, and under one global bound those would evict every retained
     review. *)
  let retention_group =
    Some
      (function
        | Review_registration _ -> row_kind_label Review_kind
        | Scan_skipped_registration _ -> row_kind_label Scan_skipped_kind)
  ;;

  let registration_to_yojson = function
    | Review_registration registration ->
      `Assoc
        [ kind_field Review_kind
        ; "goal_id", `String registration.goal_id
        ; "request_id", `String registration.request_id
        ; "criterion", Goal_store.criterion_to_yojson registration.criterion
        ; "review_kind", `String (review_kind_label registration.review_kind)
        ; "authority_actor", `String registration.authority_actor
        ]
    | Scan_skipped_registration unavailable ->
      `Assoc
        [ kind_field Scan_skipped_kind
        ; "unavailable", Goal_store_unavailable.record_to_yojson unavailable
        ]
  ;;

  let review_registration_of_yojson json fields =
    let open Result.Syntax in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:
          [ "kind"; "goal_id"; "request_id"; "criterion"; "review_kind"; "authority_actor" ]
        fields
    in
    let* goal_id = Run_registry_core.Json.string_field "goal_id" fields in
    let* request_id = Run_registry_core.Json.string_field "request_id" fields in
    let* () = if String.trim request_id = "" then Error "request_id is blank" else Ok () in
    let* criterion = Goal_store.criterion_of_yojson (Yojson.Safe.Util.member "criterion" json) in
    let* review_kind = Run_registry_core.Json.string_field "review_kind" fields in
    let* review_kind = review_kind_of_label review_kind in
    let* authority_actor =
      Run_registry_core.Json.string_field "authority_actor" fields
    in
    Ok (Review_registration { goal_id; request_id; criterion; review_kind; authority_actor })
  ;;

  let scan_skipped_registration_of_yojson json fields =
    let open Result.Syntax in
    let* () = Run_registry_core.Json.exact_fields ~required:[ "kind"; "unavailable" ] fields in
    let* unavailable =
      Goal_store_unavailable.record_of_yojson (Yojson.Safe.Util.member "unavailable" json)
    in
    Ok (Scan_skipped_registration unavailable)
  ;;

  let registration_of_yojson json =
    let open Result.Syntax in
    let* fields = Run_registry_core.Json.object_fields json in
    let* kind = Run_registry_core.Json.string_field "kind" fields in
    let* kind = row_kind_of_label kind in
    match kind with
    | Review_kind -> review_registration_of_yojson json fields
    | Scan_skipped_kind -> scan_skipped_registration_of_yojson json fields
  ;;

  let evaluated_verdict_to_yojson = function
    | None -> `Null
    | Some (Approved { reason }) -> `Assoc [ "decision", `String "approved"; "reason", `String reason ]
    | Some (Rejected { reason }) -> `Assoc [ "decision", `String "rejected"; "reason", `String reason ]

  let evaluated_verdict_of_yojson = function
    | `Null -> Ok None
    | json ->
      let open Result.Syntax in
      let* fields = Run_registry_core.Json.object_fields json in
      let* () = Run_registry_core.Json.exact_fields ~required:[ "decision"; "reason" ] fields in
      let* reason = Run_registry_core.Json.string_field "reason" fields in
      let* () = if String.trim reason = "" then Error "evaluated verdict reason is blank" else Ok () in
      let* decision = Run_registry_core.Json.string_field "decision" fields in
      match decision with
      | "approved" -> Ok (Some (Approved { reason }))
      | "rejected" -> Ok (Some (Rejected { reason }))
      | other -> Error ("unknown evaluated verdict: " ^ other)

  let review_completion_to_yojson completion =
    let outcome_fields =
      match completion.outcome with
      | Reviewed -> []
      | Committed -> []
      | Superseded { detail } -> [ "detail", `String detail ]
      | Deferred { detail } -> [ "detail", `String detail ]
      | Raised { detail } -> [ "detail", `String detail ]
      | Review_cancelled { detail } -> [ "detail", `String detail ]
    in
    `Assoc
      ([ kind_field Review_kind
       ; "outcome", `String (outcome_label completion.outcome)
       ; "evaluated_verdict", evaluated_verdict_to_yojson completion.evaluated_verdict
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

  let completion_to_yojson = function
    | Review_completion completion -> review_completion_to_yojson completion
    | Scan_skipped_completion -> `Assoc [ kind_field Scan_skipped_kind ]
  ;;

  let review_completion_of_yojson json fields =
    let open Result.Syntax in
    let* outcome_label = Run_registry_core.Json.string_field "outcome" fields in
    let detail_fields =
      match outcome_label with
      | "reviewed" -> Ok []
      | "committed" -> Ok []
      | "superseded" -> Ok [ "detail" ]
      | "deferred" -> Ok [ "detail" ]
      | "raised" -> Ok [ "detail" ]
      | "review_cancelled" -> Ok [ "detail" ]
      | label -> Error (Printf.sprintf "unknown Goal review outcome %S" label)
    in
    let* detail_fields = detail_fields in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:
          ([ "kind"; "outcome"; "evaluated_verdict"; "elapsed_s"; "tools" ] @ detail_fields)
        ~optional:[ "evaluator_runtime" ]
        fields
    in
    let* evaluated_verdict = evaluated_verdict_of_yojson (Yojson.Safe.Util.member "evaluated_verdict" json) in
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
      | "superseded" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Superseded { detail })
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
    let* () = match outcome, evaluated_verdict with
      | (Reviewed | Committed), None -> Error "reviewed or committed run requires an evaluated verdict"
      | _ -> Ok () in
    Ok (Review_completion { outcome; evaluated_verdict; evaluator_runtime; elapsed_s; tools })
  ;;

  let completion_of_yojson json =
    let open Result.Syntax in
    let* fields = Run_registry_core.Json.object_fields json in
    let* kind = Run_registry_core.Json.string_field "kind" fields in
    let* kind = row_kind_of_label kind in
    match kind with
    | Review_kind -> review_completion_of_yojson json fields
    | Scan_skipped_kind ->
      let* () = Run_registry_core.Json.exact_fields ~required:[ "kind" ] fields in
      Ok Scan_skipped_completion
  ;;
end

let evaluated_verdict_of_yojson = Payload.evaluated_verdict_of_yojson

module Store = Run_registry_core.Make (Payload)

let validate_event_json = Store.validate_event_json

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

let register_running t ~run_id ~goal_id ~request_id ~criterion ~review_kind ~authority_actor ~started_at =
  Store.register
    t
    ~id:run_id
    ~started_at
    ~registration:
      (Payload.Review_registration
         { Payload.goal_id; request_id; criterion; review_kind; authority_actor });
  notify_changed ()
;;

let mark_completed t ~run_id ~outcome ~evaluated_verdict ~tools ?evaluator_runtime ~elapsed_s () =
  let completion =
    Payload.Review_completion
      { Payload.outcome; evaluated_verdict; evaluator_runtime; elapsed_s; tools }
  in
  match Store.complete t ~id:run_id ~completion with
  | `Completed -> notify_changed ()
  | `Unknown -> ()
  | `Persistence_failed failure -> raise (Sys_error failure.detail)
;;

(* Registration and completion are two appends under the registry's own
   mutation lock, so the row is terminal on disk as soon as this returns and
   replay ([replayed_running_completion = None]) keeps it. The id was just
   registered and nothing deletes rows, so [`Unknown] cannot be reached; it is
   named rather than absorbed. *)
let record_scan_skipped t ~run_id ~started_at ~unavailable =
  Store.register
    t
    ~id:run_id
    ~started_at
    ~registration:(Payload.Scan_skipped_registration unavailable);
  match Store.complete t ~id:run_id ~completion:Payload.Scan_skipped_completion with
  | `Completed -> notify_changed ()
  | `Unknown ->
    invalid_arg
      (Printf.sprintf "%s: skipped scan %s vanished between register and complete"
         Payload.name run_id)
  | `Persistence_failed failure -> raise (Sys_error failure.detail)
;;

(* The two writers above pair each registration with its own completion, so
   a crossed pair reaches here only from a hand-edited log. It is a corrupt
   store, not a row, and is refused loudly rather than served as either. *)
let row_of_entry (entry : Store.entry) =
  let crossed registration_kind completion_kind =
    invalid_arg
      (Printf.sprintf "%s: run %s pairs a %s registration with a %s completion"
         Payload.name
         entry.id
         (row_kind_label registration_kind)
         (row_kind_label completion_kind))
  in
  match entry.registration, entry.status with
  | Payload.Review_registration registration, Store.Running ->
    Review
      { run_id = entry.id
      ; goal_id = registration.goal_id
      ; request_id = registration.request_id
      ; criterion = registration.criterion
      ; review_kind = registration.review_kind
      ; authority_actor = registration.authority_actor
      ; started_at = entry.started_at
      ; status = Running
      }
  | ( Payload.Review_registration registration
    , Store.Completed (Payload.Review_completion completion) ) ->
    Review
      { run_id = entry.id
      ; goal_id = registration.goal_id
      ; request_id = registration.request_id
      ; criterion = registration.criterion
      ; review_kind = registration.review_kind
      ; authority_actor = registration.authority_actor
      ; started_at = entry.started_at
      ; status =
          Completed
            { outcome = completion.outcome
            ; evaluated_verdict = completion.evaluated_verdict
            ; evaluator_runtime = completion.evaluator_runtime
            ; elapsed_s = completion.elapsed_s
            ; tools = completion.tools
            }
      }
  | ( Payload.Scan_skipped_registration unavailable
    , (Store.Running | Store.Completed Payload.Scan_skipped_completion) ) ->
    (* The registration is the whole fact; the completion only seals it for
       replay. In memory the row exists from the register onward. *)
    Scan_skipped { run_id = entry.id; started_at = entry.started_at; unavailable }
  | Payload.Review_registration _, Store.Completed Payload.Scan_skipped_completion ->
    crossed Review_kind Scan_skipped_kind
  | Payload.Scan_skipped_registration _, Store.Completed (Payload.Review_completion _) ->
    crossed Scan_skipped_kind Review_kind
;;

let list_runs t = List.map row_of_entry (Store.list_entries t)
let get t ~run_id = Option.map row_of_entry (Store.get t ~id:run_id)

let status_label = function
  | Running -> "running"
  | Completed { outcome; _ } -> outcome_label outcome
;;

let run_to_yojson run =
  let completion_fields =
    match run.status with
    | Running -> []
    | Completed { outcome; evaluated_verdict; evaluator_runtime; elapsed_s; tools } ->
      let detail_fields =
        match outcome with
        | Reviewed -> []
        | Committed -> []
      | Superseded { detail } -> [ "detail", `String detail ]
        | Deferred { detail } -> [ "detail", `String detail ]
        | Raised { detail } -> [ "detail", `String detail ]
        | Review_cancelled { detail } -> [ "detail", `String detail ]
      in
      [ "elapsed_s", `Float elapsed_s
      ; "evaluated_verdict", Payload.evaluated_verdict_to_yojson evaluated_verdict
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
    ([ kind_field Review_kind
     ; "run_id", `String run.run_id
     ; "goal_id", `String run.goal_id
     ; "request_id", `String run.request_id
     ; "criterion", Goal_store.criterion_to_yojson run.criterion
     ; "review_kind", `String (review_kind_label run.review_kind)
     ; "authority_actor", `String run.authority_actor
     ; "started_at", `Float run.started_at
     ; "status", `String (status_label run.status)
     ]
     @ completion_fields)
;;

(* A skipped scan is served with the goal_store_unavailable envelope's own
   members, so the dashboard reads reason, field, file, mirror and reset step
   under the keys every other surface spells. *)
let row_to_yojson = function
  | Review run -> run_to_yojson run
  | Scan_skipped { run_id; started_at; unavailable } ->
    `Assoc
      ([ kind_field Scan_skipped_kind
       ; "run_id", `String run_id
       ; "started_at", `Float started_at
       ]
       @ Goal_unavailable_envelope.fields unavailable)
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
