(* Who is calling, as the dispatch boundary that built the context knows it.
   Every schedule action that names an actor stands on it: [owner=self] lists
   the caller's rows, create records the caller as both [requested_by] and
   [scheduled_by], update and cancel decide from it which rows the caller may
   change, and cancel records it as the canceller. No call argument names
   the actor: an argument is whatever the caller chose to write, and a Keeper
   that could write [human_operator] there could pass itself off as the
   operator. *)
type caller =
  | Operator_caller of string
  (* The operator surface: an HTTP route whose request presented an operator
     credential ([Server_auth.Operator_credential]), named by the actor that
     credential resolved to. It records [Human_operator] and may change any
     schedule. *)
  | Named_caller of string
  (* A Keeper turn's own name, or an MCP caller whose name the endpoint did
     not mint itself. It records [Automated_actor] and may cancel only the
     rows [owner=self] lists for it. *)
  | Unnamed_caller
  (* An MCP caller that gave no name and presented no credential naming one.
     The endpoint minted a placeholder for its session; the placeholder
     belongs to no one across sessions, so neither "my rows" nor "who
     scheduled this" can stand on it. *)

type context =
  { config : Workspace.config
  ; caller : caller
  ; stamp_keeper_wake_result_delivery :
      payload:Yojson.Safe.t -> (Yojson.Safe.t, string) result
  ; admit_keeper_wake_creation :
      Workspace.config ->
      keeper_name:string ->
      (unit ->
       (Schedule_domain.schedule_request, Schedule_service.service_error) result) ->
      (Schedule_domain.schedule_request, Schedule_service.service_error) result
  }

let ( let* ) = Result.bind

(* Why a call was refused. [Refusal] is one whose sentence is the whole
   answer. [Typed_refusal] names its [error_kind] and carries the facts a
   caller needs to act without a second read; see
   [Schedule_contract_values.refusal_kind] for what each kind asks of it. *)
type refusal =
  | Refusal of string
  | Typed_refusal of
      { kind : Schedule_contract_values.refusal_kind
      ; message : string
      ; facts : (string * Yojson.Safe.t) list
      }

let plain result = Result.map_error (fun message -> Refusal message) result

let string_opt args key =
  match Json_util.get_string args key with
  | None -> None
  | Some value -> String_util.trim_nonempty value
;;

let required_string args key =
  match string_opt args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_int args key = Json_util.get_int args key

(* The arguments this module reads to decide which rule applies -- which due
   input, which rows, which page, how many, when a row expires -- are read as
   what they declare. A key
   sent with another JSON type is refused, not taken as absent: taken as
   absent, it lets a different argument decide the call. A null is absent. *)
let strict_int args key =
  match Json_util.assoc_member_opt key args with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some (`Intlit literal) ->
    Error (Refusal (Printf.sprintf "%s %s does not fit an integer" key literal))
  | Some
      ( `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ ) ->
    Error (Refusal (Printf.sprintf "%s must be an integer" key))
;;

let strict_number args key =
  match Json_util.assoc_member_opt key args with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some (`Intlit _ | `Bool _ | `String _ | `Assoc _ | `List _) ->
    Error (Refusal (Printf.sprintf "%s must be a number" key))
;;

(* A blank string is absent, as for every other string argument here: the
   TUI's creation form sends [due_at_iso = ""] when the operator fills in a
   recurrence instead. *)
let strict_string args key =
  match Json_util.assoc_member_opt key args with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (String_util.trim_nonempty value)
  | Some (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Assoc _ | `List _) ->
    Error (Refusal (Printf.sprintf "%s must be a string" key))
;;

let argument_out_of_range ~field ~minimum ~maximum ~given =
  let range =
    match maximum with
    | None -> Printf.sprintf "at least %d" minimum
    | Some maximum -> Printf.sprintf "%d..%d" minimum maximum
  in
  Typed_refusal
    { kind = Schedule_contract_values.Refusal_argument_out_of_range
    ; message = Printf.sprintf "%s must be %s; got %d" field range given
    ; facts =
        [ "field", `String field
        ; "minimum", `Int minimum
        ; ( "maximum"
          , match maximum with
            | None -> `Null
            | Some maximum -> `Int maximum )
        ; "given", `Int given
        ]
    }
;;

let caller_name ctx ~instead =
  match ctx.caller with
  | Operator_caller name | Named_caller name -> Ok name
  | Unnamed_caller ->
    Error
      (Typed_refusal
         { kind = Schedule_contract_values.Refusal_caller_unidentified
         ; message =
             Printf.sprintf
               "this endpoint does not know who is calling: the call gave no \
                agent name and no credential that names one; %s"
               instead
         ; facts = []
         })
;;

let caller_actor ctx ~instead =
  let* id = caller_name ctx ~instead in
  let kind =
    match ctx.caller with
    | Operator_caller _ -> Schedule_domain.Human_operator
    | Named_caller _ | Unnamed_caller -> Schedule_domain.Automated_actor
  in
  Ok Schedule_domain.{ id; kind; display_name = None }
;;

(* The actor fields are not in the tool schemas, but a call that skips schema
   validation can still send them. A field that names an actor other than the
   caller is refused rather than ignored, so the caller learns the record is
   not what it asked for; a field that names the caller changes nothing. *)
let refuse_other_actor ~(actor : Schedule_domain.actor) ~prefix args =
  let mismatch field given described =
    Error
      (Typed_refusal
         { kind = Schedule_contract_values.Refusal_actor_mismatch
         ; message =
             Printf.sprintf
               "%s names %s but the caller is %s; the actor is the caller, so \
                omit the field"
               field given described
         ; facts =
             [ "field", `String field
             ; "caller", `String actor.id
             ; "caller_kind", `String (Schedule_domain.actor_kind_to_string actor.kind)
             ; "given", `String given
             ]
         })
  in
  let id_field = prefix ^ "_id" in
  let kind_field = prefix ^ "_kind" in
  let kind = Schedule_domain.actor_kind_to_string actor.kind in
  match string_opt args id_field with
  | Some given when not (String.equal given actor.id) ->
    mismatch id_field given actor.id
  | Some _ | None ->
    (match string_opt args kind_field with
     | Some given when not (String.equal given kind) -> mismatch kind_field given kind
     | Some _ | None -> Ok ())
;;

let parse_due_at_iso8601 value =
  match Time_codec.parse_rfc3339_whole_seconds value with
  | Error Time_codec.Invalid_rfc3339 -> None
  | Ok timestamp -> Some timestamp
;;

(* A due time a call gave: an absolute instant, or a delay counted from the
   moment the tool is dispatched. A Keeper reads the clock once, on its turn's
   first request; after a tool round it has no current time to add to, so
   "in 90 seconds" is the input it can give exactly. *)
type due_input =
  | Due_at of float
  | Due_in_sec of int

(* A wake is always later than the call that asks for it, so the smallest
   delay is one second. Zero or a negative delay is a past or present due
   time spelled as a delay. *)
let min_due_in_sec = 1

let due_input_names = [ "due_at_unix"; "due_at_iso"; "due_in_sec" ]

(* Every due input the call sent, in [due_input_names] order. The caller
   decides what an empty or a longer list means. *)
let due_inputs_of_args args =
  let* from_unix =
    let* value = strict_number args "due_at_unix" in
    match value with
    | None -> Ok []
    | Some due_at -> Ok [ "due_at_unix", Due_at due_at ]
  in
  let* from_iso =
    let* value = strict_string args "due_at_iso" in
    match value with
    | None -> Ok []
    | Some iso ->
      (match parse_due_at_iso8601 iso with
       | Some due_at -> Ok [ "due_at_iso", Due_at due_at ]
       | None ->
         Error
           (Refusal
              "due_at_iso must be an RFC 3339 timestamp with Z or an explicit \
               offset such as +09:00"))
  in
  let* from_delay =
    let* value = strict_int args "due_in_sec" in
    match value with
    | None -> Ok []
    | Some delay when delay >= min_due_in_sec -> Ok [ "due_in_sec", Due_in_sec delay ]
    | Some delay ->
      Error
        (argument_out_of_range
           ~field:"due_in_sec"
           ~minimum:min_due_in_sec
           ~maximum:None
           ~given:delay)
  in
  Ok (from_unix @ from_iso @ from_delay)
;;

(* [dispatched_at] is the clock of this tool call, never [requested_at_unix]:
   a caller can set that one, and an old value would make a delay land in the
   past and a calendar recurrence compute a first due that was never asked
   for. *)
let resolve_due_at ~dispatched_at recurrence args =
  let* inputs = due_inputs_of_args args in
  match inputs with
  | [ (_, Due_at due_at) ] -> Ok due_at
  | [ (_, Due_in_sec delay) ] -> Ok (dispatched_at +. Float.of_int delay)
  | [] ->
    (match Schedule_domain.first_due_after ~now:dispatched_at recurrence with
     | Some due_at -> Ok due_at
     | None ->
       Error
         (Typed_refusal
            { kind = Schedule_contract_values.Refusal_due_input_missing
            ; message =
                Printf.sprintf
                  "one of %s is required unless recurrence_kind is daily or cron"
                  (String.concat ", " due_input_names)
            ; facts = []
            }))
  | (_ :: _ :: _) as given ->
    let names = List.map fst given in
    Error
      (Typed_refusal
         { kind = Schedule_contract_values.Refusal_due_inputs_conflict
         ; message =
             Printf.sprintf
               "give exactly one of %s; this call gave %s"
               (String.concat ", " due_input_names)
               (String.concat " and " names)
         ; facts = [ "given", `List (List.map (fun name -> `String name) names) ]
         })
;;

let source_of_arg args =
  match string_opt args "source" with
  | None -> Ok Schedule_domain.Operator_request
  | Some raw ->
    (match Schedule_domain.schedule_source_of_string raw with
     | Ok source -> Ok source
     | Error msg -> Error msg)
;;

let status_of_arg args =
  let* raw = strict_string args "status" in
  match raw with
  | None -> Ok None
  | Some raw ->
    (match Schedule_contract_values.status_selector_of_string raw with
     | Ok selector -> Ok (Some selector)
     | Error error ->
       Error (Refusal (Schedule_contract_values.decode_error_to_string error)))
;;

(* [Status_active] is every status [Schedule_domain.is_terminal] does not
   call terminal, read from there so the listing and the domain cannot
   disagree about which rows are still live. *)
let status_selected
      (selector : Schedule_contract_values.status_selector option)
      (request : Schedule_domain.schedule_request)
  =
  match selector with
  | None -> true
  | Some (Schedule_contract_values.Status_exact expected) -> request.status = expected
  | Some Schedule_contract_values.Status_active ->
    not (Schedule_domain.is_terminal request.status)
;;

let required_int args key =
  match optional_int args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let validate_recurrence_arg recurrence = Schedule_domain.validate_recurrence recurrence

let recurrence_of_arg args =
  let* recurrence_kind =
    match string_opt args "recurrence_kind" with
    | None -> Ok Schedule_contract_values.One_shot
    | Some wire_value ->
      (match Schedule_contract_values.recurrence_kind_of_string wire_value with
       | Ok recurrence_kind -> Ok recurrence_kind
       | Error error ->
         Error (Schedule_contract_values.decode_error_to_string error))
  in
  match recurrence_kind with
  | Schedule_contract_values.One_shot ->
    validate_recurrence_arg Schedule_domain.One_shot
  | Schedule_contract_values.Interval ->
    let* interval_sec = required_int args "recurrence_interval_sec" in
    validate_recurrence_arg (Schedule_domain.Interval { interval_sec })
  | Schedule_contract_values.Daily ->
    let* hour = required_int args "recurrence_hour" in
    let* minute = required_int args "recurrence_minute" in
    let second =
      (* DET-OK: missing seconds means the explicit daily schedule default at
         the API boundary, not provider/model-derived guessing. *)
      match optional_int args "recurrence_second" with
      | None -> 0
      | Some second -> second
    in
    let* timezone = required_string args "recurrence_timezone" in
    validate_recurrence_arg (Schedule_domain.Daily { hour; minute; second; timezone })
  | Schedule_contract_values.Cron ->
    let* expression = required_string args "recurrence_cron" in
    let* timezone = required_string args "recurrence_timezone" in
    validate_recurrence_arg (Schedule_domain.Cron { expression; timezone })
;;

(* The kind the runtime stamps on every schedule it creates. Written as a
   match on the projection's closed variant rather than as a constant: a
   second kind added there stops the build here, which is where the decision
   about what this tool asks a caller for belongs. *)
let stamped_kind : Schedule_payload_projection.known_kind -> string = function
  | Schedule_payload_projection.Keeper_wake -> Schedule_supported_kinds.keeper_wake
;;

(* One kind exists, so the tool takes its fields directly instead of an
   envelope the caller assembles. The envelope was three params -- kind,
   schema version, body -- whose only correct values were a fixed string, the
   integer 1, and an object with two required keys. Callers guessed, and two
   thirds of the calls were rejected on shape before the schedule was ever
   considered. [result_delivery] is absent on purpose: it is stamped from the
   creating turn's continuation and a supplied one is not honoured. *)
let payload_from_args args =
  let* keeper_name = required_string args "keeper_name" in
  let* message = required_string args "message" in
  let optional name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  let body =
    [ "keeper_name", `String keeper_name; "message", `String message ]
    @ optional "title" (string_opt args "title")
    @ optional "urgency" (string_opt args "urgency")
  in
  Ok
    (`Assoc
      [ "kind", `String (stamped_kind Schedule_payload_projection.Keeper_wake)
      ; "body", `Assoc body
      ])
;;

(* [schedule_payload_unsupported_total] is no longer counted here. The label
   was phase=creation, and this tool stamps the kind, so an unsupported kind
   cannot arrive through it any more. The dispatch-phase producer in
   [Server_schedule_consumers] is what still meets one, on a row stored before
   a kind was retired. *)
let validate_known_payload_request ~payload =
  match
    Schedule_payload_projection.validate_request_payload_for_creation_detailed
      ~payload
  with
  | Ok () -> Ok ()
  | Error rejection ->
    Error (Schedule_payload_projection.creation_rejection_message rejection)
;;

(* A keeper_wake schedule whose target has no durable metadata can never be
   settled: dispatch rejects the due occurrence terminally as owner-absent
   and the schedule fails (#26092). Reject at creation unless the caller
   explicitly schedules for a keeper that will be registered later. The
   registry lookup arrives via [Workspace_hooks] so this tool module keeps no
   static keeper dependency (RFC-0194). *)
let allow_unregistered_keeper_of_args args =
  match Json_util.assoc_member_opt "allow_unregistered_keeper" args with
  | None | Some `Null -> Ok false
  | Some (`Bool value) -> Ok value
  | Some _ -> Error "allow_unregistered_keeper must be a boolean"
;;

let validate_keeper_wake_target ctx ~keeper_wake_target args =
  match keeper_wake_target with
  | None -> Ok ()
  | Some keeper_name ->
    let* allow_unregistered = allow_unregistered_keeper_of_args args in
    if allow_unregistered
    then Ok ()
    else (
      match
        (Atomic.get Workspace_hooks.schedule_wake_target_registered_fn)
          ctx.config
          keeper_name
      with
      | Ok true -> Ok ()
      | Ok false ->
        Error
          (Printf.sprintf
             "schedule target keeper '%s' has no durable metadata; register the \
              keeper first or pass allow_unregistered_keeper=true to schedule for \
              a keeper that will be created later"
             keeper_name)
      | Error detail ->
        Error
          (Printf.sprintf
             "schedule target keeper '%s' metadata read failed: %s"
             keeper_name
             detail))
;;

let schedule_request_json ?last_wake (request : Schedule_domain.schedule_request) =
  let next_due_at =
    match request.status with
    | Schedule_domain.Scheduled | Schedule_domain.Due -> Some request.due_at
    | Schedule_domain.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      None
  in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  match Schedule_domain.schedule_request_to_yojson request with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ( "due_at_iso"
           , `String (Masc_domain.iso8601_of_unix_seconds request.due_at) )
         ; ( "next_due_at"
           , match next_due_at with
             | None -> `Null
             | Some ts -> `Float ts )
         ; ( "next_due_at_iso"
           , match next_due_at with
             | None -> `Null
             | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts) )
         ; ( "requested_at_iso"
           , `String (Masc_domain.iso8601_of_unix_seconds request.requested_at) )
           (* [Schedule_domain.schedule_request_to_yojson] already emits the
              structured "recurrence" in [fields] above. Appending it a second
              time here produced an object with the key twice: readers that
              take the first binding and readers that take the last read
              different values from one result, and the checkpoint encoder --
              which rejects duplicate keys outright -- failed the whole turn
              at [message[_].content[_].json], after the tool had already run.
              One keeper lost 12 consecutive turns to that on 2026-08-29.
              The flattened pair below stays for the readers that use it. *)
         ; ( "recurrence_kind"
           , `String (Schedule_domain.recurrence_kind_to_string request.recurrence) )
         ; ( "recurrence_summary"
           , `String (Schedule_domain.recurrence_summary request.recurrence) )
         ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
         ; ( "payload_kind"
           , match Schedule_payload_projection.kind request with
             | None -> `Null
             | Some kind -> `String kind )
         ; ( "payload_support"
           , `String
               (request
                |> Schedule_payload_projection.support_status
                |> Schedule_payload_projection.support_status_to_string) )
         ; ( "payload_dispatch_tool"
             (* Display getter: non-logging result variant (see
                server_dashboard_http_runtime_info). Avoids a per-poll WARN on
                terminal unsupported-kind rows. *)
           , match Schedule_payload_projection.dispatch_tool_for_request_result request with
             | Ok tool_name -> `String tool_name
             | Error _ -> `Null )
         ; ( "payload_target"
           , match payload_target with
             | None -> `Null
             | Some target -> `String target )
         ; ( "payload_summary"
           , match payload_summary with
             | None -> `Null
             | Some summary -> `String summary )
         ; ( "last_wake"
           , match last_wake with
             | None -> `Null
             | Some wake -> Schedule_domain.wake_record_to_yojson wake
           )
         ])
  | other -> other
;;

let ok ~tool_name ~start_time data =
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let workflow_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let runtime_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let refusal_result ~tool_name ~start_time = function
  | Refusal message -> workflow_error ~tool_name ~start_time message
  | Typed_refusal { kind; message; facts } ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      ~data:
        (Tool_args.error_assoc
           (("message", `String message)
            :: ( "error_kind"
               , `String (Schedule_contract_values.refusal_kind_to_string kind) )
            :: facts))
      message
;;

let schedule_read_runtime_error ~tool_name ~start_time err =
  runtime_error
    ~tool_name
    ~start_time
    ("schedule store read failed: " ^ Schedule_store.read_error_to_string err)
;;

let iso_json timestamp = `String (Masc_domain.iso8601_of_unix_seconds timestamp)

(* A refusal the caller can act on carries its facts as fields, not only in
   the sentence: which status the schedule was already in and what its last
   wake did, or which due time was already behind the clock. The match names
   every error so a new one is a decision here, not a silent message-only
   row. *)
let refusal_of_service_error (err : Schedule_service.service_error) =
  let message = Schedule_service.service_error_to_string err in
  let typed kind facts = Typed_refusal { kind; message; facts } in
  match err with
  | Schedule_service.Due_already_past { due_at; now } ->
    typed
      Schedule_contract_values.Refusal_due_already_past
      [ "due_at_iso", iso_json due_at; "now_iso", iso_json now ]
  | Schedule_service.Store_error
      (Schedule_store.Changed_due_already_past
        { schedule_id; stored_due_at; due_at; now }) ->
    typed
      Schedule_contract_values.Refusal_due_already_past
      [ "schedule_id", `String schedule_id
      ; "due_at_iso", iso_json due_at
      ; "stored_due_at_iso", iso_json stored_due_at
      ; "now_iso", iso_json now
      ]
  | Schedule_service.Store_error
      (Schedule_store.Interval_below_runner_tick
        { schedule_id; below = { interval_sec; runner_tick_sec } }) ->
    typed
      Schedule_contract_values.Refusal_argument_out_of_range
      [ "field", `String "recurrence_interval_sec"
      ; "minimum", `Int (int_of_float (Float.ceil runner_tick_sec))
      ; "maximum", `Null
      ; "given", `Int interval_sec
      ; "schedule_id", `String schedule_id
      ; "runner_tick_sec", `Float runner_tick_sec
      ]
  | Schedule_service.Store_error
      (Schedule_store.Transition_refused { schedule_id; current; attempted; last_wake })
    ->
    typed
      Schedule_contract_values.Refusal_transition_refused
      [ "schedule_id", `String schedule_id
      ; "current_status", `String (Schedule_domain.schedule_status_to_string current)
      ; "attempted", `String (Schedule_store.attempted_transition_to_string attempted)
      ; ( "last_wake"
        , match last_wake with
          | None -> `Null
          | Some wake -> Schedule_domain.wake_record_to_yojson wake )
      ]
  | Schedule_service.Store_error
      ( Schedule_store.Schedule_already_exists
      | Schedule_store.Schedule_not_found
      | Schedule_store.Invalid_initial_status _
      | Schedule_store.Running_wake_absent _
      | Schedule_store.Running_wake_settled _
      | Schedule_store.Schedule_not_due_candidate
      | Schedule_store.Schedule_not_running
      | Schedule_store.Persistence_failed _
      | Schedule_store.Corrupt_ledger _ )
  | Schedule_service.Invalid_request _
  | Schedule_service.Creation_rejected _ -> Refusal message
;;

(* The rows a named caller may change: the ones [owner=self] lists for it,
   a row it scheduled or a row that wakes it. The operator may change any
   row. *)
let caller_holds_row ~name (request : Schedule_domain.schedule_request) =
  String.equal request.scheduled_by.id name
  || (match Schedule_payload_projection.wake_keeper_name request with
      | Some keeper_name -> String.equal keeper_name name
      | None -> false)
;;

let not_schedule_owner ~schedule_id ~name ~scheduled_by_id ~wake_target =
  Typed_refusal
    { kind = Schedule_contract_values.Refusal_not_schedule_owner
    ; message =
        Printf.sprintf
          "schedule %s was scheduled by %s and would not wake %s; a caller \
           changes only the schedules it made or the ones that wake it"
          schedule_id
          scheduled_by_id
          name
    ; facts =
        [ "schedule_id", `String schedule_id
        ; "caller", `String name
        ; "scheduled_by_id", `String scheduled_by_id
        ; ( "wake_target"
          , match wake_target with
            | Some keeper_name -> `String keeper_name
            | None -> `Null )
        ]
    }
;;

(* Asked before update and cancel. It answers the stored row, so update can
   keep the row's actors. A row this read does not find is [None] and is left
   to the store, which answers "not found" under its own lock. *)
let authorize_row_change ctx ~schedule_id =
  let* _name =
    caller_name ctx ~instead:"only a named caller may change a schedule"
  in
  match Schedule_store.read_state_result ctx.config with
  | Error err ->
    Error
      (Refusal
         ("schedule store read failed: " ^ Schedule_store.read_error_to_string err))
  | Ok state ->
    let row =
      List.find_opt
        (fun (request : Schedule_domain.schedule_request) ->
           String.equal request.schedule_id schedule_id)
        state.schedules
    in
    (match ctx.caller, row with
     | (Operator_caller _ | Unnamed_caller), _ | Named_caller _, None -> Ok row
     | Named_caller name, Some request when caller_holds_row ~name request -> Ok row
     | Named_caller name, Some request ->
       Error
         (not_schedule_owner
            ~schedule_id
            ~name
            ~scheduled_by_id:request.scheduled_by.id
            ~wake_target:(Schedule_payload_projection.wake_keeper_name request)))
;;

(* An update replaces the whole definition, including whom it wakes, so the
   replacement has to be one the caller would hold too: a Keeper the row
   wakes cannot point it at another Keeper. The row keeps its actors; the
   update does not make the caller its scheduler. *)
let authorize_replacement ctx ~schedule_id ~(stored : Schedule_domain.schedule_request)
      ~keeper_wake_target
  =
  match ctx.caller with
  | Operator_caller _ | Unnamed_caller -> Ok ()
  | Named_caller name ->
    let wakes_caller =
      match keeper_wake_target with
      | Some keeper_name -> String.equal keeper_name name
      | None -> false
    in
    if String.equal stored.scheduled_by.id name || wakes_caller
    then Ok ()
    else
      Error
        (not_schedule_owner
           ~schedule_id
           ~name
           ~scheduled_by_id:stored.scheduled_by.id
           ~wake_target:keeper_wake_target)
;;

(* TEL-OK: schedule tools return [Tool_result.t] through the shared
   [Tool_dispatch] paths; [Server_bootstrap_maintenance] installs the canonical
   dispatch observer that records tool telemetry and metrics once for keeper and
   MCP calls. *)
type write_action =
  | Create_schedule
  | Update_schedule

let handle_write ~action ~tool_name ~start_time ctx args =
  let result =
    let* payload = plain (payload_from_args args) in
    let* payload = plain (ctx.stamp_keeper_wake_result_delivery ~payload) in
    let* () = plain (validate_known_payload_request ~payload) in
    let* keeper_wake_target =
      plain (Schedule_payload_projection.creation_keeper_wake_target ~payload)
    in
    let* source = plain (source_of_arg args) in
    let* recurrence = plain (recurrence_of_arg args) in
    let* requested_at =
      let* given = strict_number args "requested_at_unix" in
      (* NDT-OK: absent requested_at_unix means "schedule this from the tool
         dispatch boundary now"; replay/tests can pass requested_at_unix explicitly. *)
      match given with
      | None -> Ok start_time
      | Some requested_at -> Ok requested_at
    in
    let* due_at = resolve_due_at ~dispatched_at:start_time recurrence args in
    let* schedule_id =
      match action, string_opt args "schedule_id" with
      | Create_schedule, schedule_id -> Ok schedule_id
      | Update_schedule, Some schedule_id -> Ok (Some schedule_id)
      | Update_schedule, None -> Error (Refusal "schedule_id is required")
    in
    let* caller =
      caller_actor ctx
        ~instead:"call with an agent name or a credential that names one"
    in
    let* () = refuse_other_actor ~actor:caller ~prefix:"requested_by" args in
    let* () = refuse_other_actor ~actor:caller ~prefix:"scheduled_by" args in
    let caller_as_both () = Ok (caller, caller) in
    let* requested_by, scheduled_by =
      match action, schedule_id with
      | Update_schedule, Some schedule_id ->
        let* stored = authorize_row_change ctx ~schedule_id in
        (match stored with
         | Some stored ->
           let* () =
             authorize_replacement ctx ~schedule_id ~stored ~keeper_wake_target
           in
           Ok (stored.requested_by, stored.scheduled_by)
         | None -> caller_as_both ())
      | Update_schedule, None | Create_schedule, _ -> caller_as_both ()
    in
    let* expires_at = strict_number args "expires_at_unix" in
    let write_request () =
      let* () =
        validate_keeper_wake_target ctx ~keeper_wake_target args
        |> Result.map_error (fun detail ->
          Schedule_service.Creation_rejected detail)
      in
      (* [start_time], not [requested_at]: a caller can set requested_at,
         and the question is whether the due time is already behind the
         clock this call runs on. *)
      (* The cadence the production runner loop sleeps on
         ([Server_schedule_runner_policy.interval_sec] reads the same value). *)
      let runner_tick_sec = Env_config_runtime_services.ScheduleRunner.interval_sec in
      match action, schedule_id with
      | Create_schedule, schedule_id ->
        Schedule_service.create
          ctx.config ~now:start_time ~runner_tick_sec ?schedule_id ~requested_at ?expires_at
          ~requested_by ~scheduled_by ~due_at ~payload ~source ~recurrence ()
      | Update_schedule, Some schedule_id ->
        Schedule_service.update
          ctx.config ~now:start_time ~runner_tick_sec ~schedule_id ~requested_at ?expires_at
          ~requested_by ~scheduled_by ~due_at ~payload ~source ~recurrence ()
      | Update_schedule, None ->
        Error (Schedule_service.Invalid_request "schedule_id is required")
    in
    Ok
      (match keeper_wake_target with
       | None -> write_request ()
       | Some keeper_name ->
         ctx.admit_keeper_wake_creation
           ctx.config
           ~keeper_name
           write_request)
  in
  match result with
  | Error refusal -> refusal_result ~tool_name ~start_time refusal
  | Ok (Error err) ->
    refusal_result ~tool_name ~start_time (refusal_of_service_error err)
  | Ok (Ok request) -> ok ~tool_name ~start_time (schedule_request_json request)
;;

let handle_create = handle_write ~action:Create_schedule
let handle_update = handle_write ~action:Update_schedule

let take limit items =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (item :: acc) (remaining - 1) rest
  in
  loop [] limit items
;;

let default_list_limit = 50
let min_list_limit = 1
let max_list_limit = 200

(* One page size rule for both listings: an absent limit is the default, and
   a given one inside [min_list_limit]..[max_list_limit] is that many rows. A
   limit outside the range is refused rather than moved inside it: a caller
   that asked for 0 or 10,000 rows and got 1 or 200 reads a page it did not
   ask for and cannot tell. *)
let list_limit_of_args args =
  let* requested = strict_int args "limit" in
  match requested with
  | None -> Ok default_list_limit
  | Some limit when limit >= min_list_limit && limit <= max_list_limit -> Ok limit
  | Some limit ->
    Error
      (argument_out_of_range
         ~field:"limit"
         ~minimum:min_list_limit
         ~maximum:(Some max_list_limit)
         ~given:limit)
;;

(* Whose rows a listing reads, once [owner] and [owner_name] are parsed. A
   schedule names two actors -- the one that created it and the Keeper it
   wakes -- and [Either_side] is the caller on either of them. *)
type owner_filter =
  | Either_side of string
  | Wake_target of string
  | Scheduled_by of string
  | All_rows

(* [owner] is required, so no call reads every row by leaving it out. Only the
   two named selectors take [owner_name]; a name next to self or all is
   refused rather than ignored, because the caller meant something by it. *)
let owner_filter_of_args ctx args =
  let* kind =
    match string_opt args "owner" with
    | None ->
      Error
        (Refusal
           (Printf.sprintf
              "owner is required; accepted: %s"
              (String.concat ", " Schedule_contract_values.owner_kind_strings)))
    | Some raw ->
      Schedule_contract_values.owner_kind_of_string raw
      |> Result.map_error (fun error ->
        Refusal (Schedule_contract_values.decode_error_to_string error))
  in
  let kind_name = Schedule_contract_values.owner_kind_to_string kind in
  match kind, string_opt args "owner_name" with
  | Schedule_contract_values.Owner_self, None ->
    let* name =
      caller_name
        ctx
        ~instead:"use owner=scheduled_by or owner=wake_target with owner_name"
    in
    Ok (Either_side name)
  | Schedule_contract_values.Owner_all, None -> Ok All_rows
  | Schedule_contract_values.Owner_wake_target, Some name -> Ok (Wake_target name)
  | Schedule_contract_values.Owner_scheduled_by, Some name -> Ok (Scheduled_by name)
  | (Schedule_contract_values.Owner_self | Schedule_contract_values.Owner_all), Some _ ->
    Error (Refusal (Printf.sprintf "owner_name is not accepted with owner=%s" kind_name))
  | ( ( Schedule_contract_values.Owner_wake_target
      | Schedule_contract_values.Owner_scheduled_by )
    , None ) ->
    Error (Refusal (Printf.sprintf "owner_name is required with owner=%s" kind_name))
;;

let owner_filter_parts filter =
  match filter with
  | Either_side name -> Schedule_contract_values.Owner_self, Some name
  | Wake_target name -> Schedule_contract_values.Owner_wake_target, Some name
  | Scheduled_by name -> Schedule_contract_values.Owner_scheduled_by, Some name
  | All_rows -> Schedule_contract_values.Owner_all, None
;;

let optional_string_json = function
  | None -> `Null
  | Some value -> `String value
;;

let owner_filter_fields filter =
  let kind, name = owner_filter_parts filter in
  [ "owner", `String (Schedule_contract_values.owner_kind_to_string kind)
  ; "owner_name", optional_string_json name
  ]
;;

let owner_filter_equal left right =
  match left, right with
  | Either_side left, Either_side right
  | Wake_target left, Wake_target right
  | Scheduled_by left, Scheduled_by right -> String.equal left right
  | All_rows, All_rows -> true
  | (Either_side _ | Wake_target _ | Scheduled_by _ | All_rows), _ -> false
;;

let status_filter_equal
      (left : Schedule_contract_values.status_selector option)
      (right : Schedule_contract_values.status_selector option)
  =
  match left, right with
  | None, None -> true
  | Some left, Some right -> left = right
  | Some _, None | None, Some _ -> false
;;

let owner_filter_matches filter (request : Schedule_domain.schedule_request) =
  let wakes name =
    match Schedule_payload_projection.wake_keeper_name request with
    | Some keeper_name -> String.equal keeper_name name
    | None -> false
  in
  let scheduled name = String.equal request.scheduled_by.id name in
  match filter with
  | Either_side name -> caller_holds_row ~name request
  | Wake_target name -> wakes name
  | Scheduled_by name -> scheduled name
  | All_rows -> true
;;

(* A listing row answers "which schedule is this and where does it stand".
   The request itself -- payload, delivery route, actors, structured
   recurrence -- is masc_schedule_get's; a row that carried it made one
   fleet listing 140 KB. *)
let schedule_summary_json state (request : Schedule_domain.schedule_request) =
  let last_wake =
    Schedule_store.last_wake_for_schedule_instance
      state
      ~schedule_instance_id:request.schedule_instance_id
      ~schedule_id:request.schedule_id
  in
  let _, summary = Schedule_payload_projection.target_summary request in
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "due_at_iso", iso_json request.due_at
    ; ( "recurrence_summary"
      , `String (Schedule_domain.recurrence_summary request.recurrence) )
    ; ( "wake_target"
      , optional_string_json (Schedule_payload_projection.wake_keeper_name request) )
    ; "scheduled_by", `String request.scheduled_by.id
    ; "summary", optional_string_json summary
    ; ( "last_wake_status"
      , match last_wake with
        | None -> `Null
        | Some wake ->
          `String (Schedule_domain.wake_status_to_string wake.Schedule_domain.status) )
    ]
;;

(* What a cursor carries: the filters of the listing that issued it and the
   last schedule_id that listing showed. The call that brings it back must
   ask for the same rows; a cursor from another filter would skip rows that
   filter never compared against the id. It travels as base64url JSON so a
   caller hands it back whole rather than editing a part. *)
type list_cursor =
  { after_schedule_id : string
  ; cursor_owner : owner_filter
  ; cursor_status : Schedule_contract_values.status_selector option
  }

let list_cursor_to_string { after_schedule_id; cursor_owner; cursor_status } =
  `Assoc
    (("after", `String after_schedule_id)
     :: (owner_filter_fields cursor_owner
         @ [ ( "status"
             , match cursor_status with
               | None -> `Null
               | Some selector ->
                 `String (Schedule_contract_values.status_selector_to_string selector) )
           ]))
  |> Yojson.Safe.to_string
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
;;

let cursor_not_issued = Refusal "cursor is not one a listing issued; list again without cursor"

let list_cursor_of_string raw =
  let* decoded =
    Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet raw
    |> Result.map_error (fun (`Msg _) -> cursor_not_issued)
  in
  let* fields =
    match Yojson.Safe.from_string decoded with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error cursor_not_issued
    | exception Yojson.Json_error _ -> Error cursor_not_issued
  in
  let string_field name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok (Some value)
    | Some `Null -> Ok None
    | None | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
      Error cursor_not_issued
  in
  let* after = string_field "after" in
  let* owner = string_field "owner" in
  let* owner_name = string_field "owner_name" in
  let* status = string_field "status" in
  let* after_schedule_id =
    match after with
    | Some after -> Ok after
    | None -> Error cursor_not_issued
  in
  let* owner_kind =
    match owner with
    | None -> Error cursor_not_issued
    | Some owner ->
      Schedule_contract_values.owner_kind_of_string owner
      |> Result.map_error (fun (_ : Schedule_contract_values.decode_error) ->
        cursor_not_issued)
  in
  let* cursor_owner =
    match owner_kind, owner_name with
    | Schedule_contract_values.Owner_self, Some name -> Ok (Either_side name)
    | Schedule_contract_values.Owner_wake_target, Some name -> Ok (Wake_target name)
    | Schedule_contract_values.Owner_scheduled_by, Some name -> Ok (Scheduled_by name)
    | Schedule_contract_values.Owner_all, None -> Ok All_rows
    | ( ( Schedule_contract_values.Owner_self
        | Schedule_contract_values.Owner_wake_target
        | Schedule_contract_values.Owner_scheduled_by )
      , None )
    | Schedule_contract_values.Owner_all, Some _ -> Error cursor_not_issued
  in
  let* cursor_status =
    match status with
    | None -> Ok None
    | Some status ->
      Schedule_contract_values.status_selector_of_string status
      |> Result.map (fun selector -> Some selector)
      |> Result.map_error (fun (_ : Schedule_contract_values.decode_error) ->
        cursor_not_issued)
  in
  Ok { after_schedule_id; cursor_owner; cursor_status }
;;

let cursor_of_args ~owner ~status args =
  match Json_util.assoc_member_opt "cursor" args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
    (match String_util.trim_nonempty raw with
     | None ->
       Error (Refusal "cursor is empty; leave cursor out to read the first page")
     | Some raw ->
       let* cursor = list_cursor_of_string raw in
       if
         owner_filter_equal cursor.cursor_owner owner
         && status_filter_equal cursor.cursor_status status
       then Ok (Some cursor)
       else (
         let cursor_owner_kind, cursor_owner_name =
           owner_filter_parts cursor.cursor_owner
         in
         let cursor_status_name =
           match cursor.cursor_status with
           | None -> "any"
           | Some selector -> Schedule_contract_values.status_selector_to_string selector
         in
         Error
           (Typed_refusal
              { kind = Schedule_contract_values.Refusal_cursor_mismatch
              ; message =
                  Printf.sprintf
                    "this cursor belongs to a listing with owner=%s%s status=%s; \
                     send those filters with it, or list again without cursor"
                    (Schedule_contract_values.owner_kind_to_string cursor_owner_kind)
                    (match cursor_owner_name with
                     | None -> ""
                     | Some name -> " owner_name=" ^ name)
                    cursor_status_name
              ; facts =
                  [ ( "cursor_owner"
                    , `String
                        (Schedule_contract_values.owner_kind_to_string
                           cursor_owner_kind) )
                  ; "cursor_owner_name", optional_string_json cursor_owner_name
                  ; ( "cursor_status"
                    , match cursor.cursor_status with
                      | None -> `Null
                      | Some selector ->
                        `String
                          (Schedule_contract_values.status_selector_to_string selector) )
                  ]
              })))
  | Some (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Assoc _ | `List _) ->
    Error (Refusal "cursor must be a string")
;;

(* Pages follow schedule_id order, and a page is every listed row whose id
   sorts after the cursor's. An update keeps the id, so a row edited between
   two calls stays where it was, and a pruned row is simply not there.
   Schedule ids are random, though, so a row created while a caller walks the
   pages lands anywhere in that order: one that sorts before the cursor is on
   none of the remaining pages, and a listing started again from the first
   page shows it. *)
let handle_list ~tool_name ~start_time ctx args =
  let parsed =
    let* owner = owner_filter_of_args ctx args in
    let* status = status_of_arg args in
    let* limit = list_limit_of_args args in
    let* cursor = cursor_of_args ~owner ~status args in
    Ok (owner, status, limit, cursor)
  in
  match parsed with
  | Error refusal -> refusal_result ~tool_name ~start_time refusal
  | Ok (owner, status, limit, cursor) ->
    (match Schedule_store.read_state_result ctx.config with
     | Error err -> schedule_read_runtime_error ~tool_name ~start_time err
     | Ok state ->
       let after_cursor (request : Schedule_domain.schedule_request) =
         match cursor with
         | None -> true
         | Some { after_schedule_id; _ } ->
           String.compare request.schedule_id after_schedule_id > 0
       in
       let remaining =
         state.Schedule_store.schedules
         |> List.filter (fun request ->
           after_cursor request
           && status_selected status request
           && owner_filter_matches owner request)
         |> List.sort
              (fun
                  (left : Schedule_domain.schedule_request)
                  (right : Schedule_domain.schedule_request)
                -> String.compare left.schedule_id right.schedule_id)
       in
       let page = take limit remaining in
       let next_cursor =
         match List.rev page with
         | (last : Schedule_domain.schedule_request) :: _
           when List.length remaining > List.length page ->
           [ ( "next_cursor"
             , `String
                 (list_cursor_to_string
                    { after_schedule_id = last.schedule_id
                    ; cursor_owner = owner
                    ; cursor_status = status
                    }) )
           ]
         | _ :: _ | [] -> []
       in
       ok ~tool_name ~start_time
         (`Assoc
           ([ "status", `String "ok" ]
            @ owner_filter_fields owner
            @ [ "limit", `Int limit
              ; "schedules", `List (List.map (schedule_summary_json state) page)
              ]
            @ next_cursor)))
;;

let handle_get ~tool_name ~start_time ctx args =
  match required_string args "schedule_id" with
  | Error msg -> workflow_error ~tool_name ~start_time msg
  | Ok schedule_id ->
    (match Schedule_store.read_state_result ctx.config with
     | Error err -> schedule_read_runtime_error ~tool_name ~start_time err
     | Ok state ->
       match
         List.find_opt
           (fun (request : Schedule_domain.schedule_request) ->
              String.equal request.schedule_id schedule_id)
           state.schedules
       with
     | None -> workflow_error ~tool_name ~start_time "schedule not found"
     | Some request ->
       let last_wake =
         Schedule_store.last_wake_for_schedule_instance state
           ~schedule_instance_id:request.Schedule_domain.schedule_instance_id
           ~schedule_id:request.Schedule_domain.schedule_id
       in
       ok ~tool_name ~start_time (schedule_request_json ?last_wake request))
;;

(* The canceller is the caller, never an argument: see [caller]. *)
let handle_cancel ~tool_name ~start_time ctx args =
  let result =
    let* schedule_id = plain (required_string args "schedule_id") in
    let* reason = plain (required_string args "reason") in
    let* cancelled_by =
      caller_actor ctx
        ~instead:"call with an agent name or a credential that names one"
    in
    let* () = refuse_other_actor ~actor:cancelled_by ~prefix:"cancelled_by" args in
    let* _stored = authorize_row_change ctx ~schedule_id in
    Ok (schedule_id, reason, cancelled_by)
  in
  match result with
  | Error refusal -> refusal_result ~tool_name ~start_time refusal
  | Ok (schedule_id, reason, cancelled_by) ->
    (match Schedule_service.cancel ctx.config ~schedule_id with
     | Error err ->
       refusal_result ~tool_name ~start_time (refusal_of_service_error err)
     | Ok request ->
       ok ~tool_name ~start_time
         (`Assoc
           [ "status", `String "ok"
           ; "schedule", schedule_request_json request
           ; ( "cancelled_by"
             , `Assoc
                 [ "id", `String cancelled_by.Schedule_domain.id
                 ; ( "kind"
                   , `String (Schedule_domain.actor_kind_to_string cancelled_by.kind) )
                 ] )
           ; "reason", `String reason
           ]))
;;

(* Notes append to the store directly (task-381): the note tool owns the
   argument contract while the store owns identity and ordering. The author is
   the caller by the same rule as [scheduled_by] on create. *)
let handle_note_add ~tool_name ~start_time ctx args =
  match
    let* schedule_id = plain (required_string args "schedule_id") in
    let* body = plain (required_string args "body") in
    let* author =
      caller_actor ctx
        ~instead:"call with an agent name or a credential that names one"
    in
    let* () = refuse_other_actor ~actor:author ~prefix:"author" args in
    let author_id = author.Schedule_domain.id in
    let author_kind = author.kind in
    let now = Time_compat.now () in
    let* note, note_count =
      Schedule_store.append_note
        ctx.config
        ~schedule_id
        ~author_id
        ~author_kind
        ~body
        ~now
      |> Result.map_error Schedule_store.store_error_to_string
      |> plain
    in
    Ok (note, note_count)
  with
  | Error refusal -> refusal_result ~tool_name ~start_time refusal
  | Ok (note, note_count) ->
    ok ~tool_name ~start_time
      (`Assoc
        [ "status", `String "ok"
        ; "note", Schedule_domain.schedule_note_to_yojson note
        ; "note_count", `Int note_count
        ])
;;

let handle_notes_list ~tool_name ~start_time ctx args =
  match
    let* schedule_id = plain (required_string args "schedule_id") in
    let* limit = list_limit_of_args args in
    Ok (schedule_id, limit)
  with
  | Error refusal -> refusal_result ~tool_name ~start_time refusal
  | Ok (schedule_id, limit) ->
    (match Schedule_store.read_state_result ctx.config with
     | Error err -> schedule_read_runtime_error ~tool_name ~start_time err
     | Ok state ->
       let notes =
         Schedule_store.notes_for_schedule state ~schedule_id
         |> fun notes ->
         let count = List.length notes in
         if count <= limit then notes
         else
           (* Oldest-first promise stays intact: trim from the head, keep the
              newest [limit], still returned oldest first. *)
           List.filteri (fun i _ -> i >= count - limit) notes
       in
       ok ~tool_name ~start_time
         (`Assoc
           [ "status", `String "ok"
           ; "schedule_id", `String schedule_id
           ; "limit", `Int limit
           ; "notes", `List (List.map Schedule_domain.schedule_note_to_yojson notes)
           ]))
;;

let dispatch ctx ~name ~args : Tool_result.result option =
  let start_time = Time_compat.now () in
  let handle f =
    try Some (f ~tool_name:name ~start_time ctx args) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Some
        (runtime_error ~tool_name:name ~start_time
           (Printf.sprintf "schedule tool failed: %s" (Printexc.to_string exn)))
  in
  let open Tool_schemas_schedule in
  match find_definition name with
  | Some { action = Create_request; _ } -> handle handle_create
  | Some { action = Update_request; _ } -> handle handle_update
  | Some { action = List_requests; _ } -> handle handle_list
  | Some { action = Get_request; _ } -> handle handle_get
  | Some { action = Cancel_request; _ } -> handle handle_cancel
  | Some { action = Add_note; _ } -> handle handle_note_add
  | Some { action = List_notes; _ } -> handle handle_notes_list
  (* [None] is "not a schedule tool". Spelling it out rather than [_] keeps the
     action match exhaustive, so an action added to Tool_schemas_schedule is a
     compile error here instead of an advertised name with no route. *)
  | None -> None
;;

let schemas = Tool_schemas_schedule.schemas

let () =
  List.iter
    (fun (definition : Tool_schemas_schedule.definition) ->
      let schema : Masc_domain.tool_schema = definition.schema in
      let is_read_only = definition.read_only in
      Tool_spec.register
        (Tool_spec.create
           ~name:schema.name
           ~description:schema.description
           ~module_tag:Tool_dispatch.Mod_schedule
           ~input_schema:schema.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only
           ()))
    Tool_schemas_schedule.definitions
;;
