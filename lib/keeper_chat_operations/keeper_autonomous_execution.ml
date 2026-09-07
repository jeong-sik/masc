module Snapshot = Keeper_repetition_snapshot
module Scope_id = Keeper_execution_scope_id
let ( let* ) = Result.bind

type source_member =
  { post_id : string
  ; admitted_revision : int64
  ; checkpoint_retentions : int
  ; source_sha256 : string
  }

let canonical_sha value =
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest -> String.equal value (Digestif.SHA256.to_hex digest)
  | None -> false

let source_member ~post_id ~admitted_revision ~checkpoint_retentions ~source_sha256 =
  if String.trim post_id = "" then Error "source post_id must not be blank"
  else if admitted_revision < 0L || checkpoint_retentions < 0 then
    Error "source revision and retention count must not be negative"
  else if not (canonical_sha source_sha256) then Error "source hash must be canonical SHA-256"
  else Ok { post_id; admitted_revision; checkpoint_retentions; source_sha256 }

type source_projection = 
  { original : source_member
  ; observed : source_member
  ; bound_scope : Keeper_execution_scope_id.t
  }
let source_projection ~original ~observed ~bound_scope =
  if not (String.equal original.post_id observed.post_id) then
    Error "source projection changed the admitted source identity"
  else Ok { original; observed; bound_scope }

type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Interrupted_execution
type recovery = { origin : recovery_origin; diagnostic : string }
type phase =
  | Preparing
  | Ready
  | Running
  | Recovering of recovery
  | Suspended of Keeper_checkpoint_ref.t
  | Settled of terminal

type t =
  { id : Uuidm.t
  ; revision : int64
  ; sources : source_member list
  ; current_sources : source_member list
  ; frame : Snapshot.t
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }
type error = Invalid_record of string | Invalid_transition of string | Revision_exhausted
type action =
  | Confirm_sources
  | Begin_execution
  | Recheck_sources of source_projection list
  | Resume_checkpoint of Keeper_checkpoint_ref.t
  | Record_observation of Snapshot.observation
  | Require_reconciliation of string
  | Suspend of Keeper_checkpoint_ref.t
  | Settle of terminal

let error_to_string = function
  | Invalid_record detail -> "invalid autonomous execution: " ^ detail
  | Invalid_transition detail -> "invalid autonomous execution transition: " ^ detail
  | Revision_exhausted -> "autonomous execution revision exhausted"

let phase_name = function
  | Preparing -> "preparing" | Ready -> "ready" | Running -> "running"
  | Recovering _ -> "recovering" | Suspended _ -> "suspended" | Settled _ -> "settled"
let is_terminal execution = match execution.phase with Settled _ -> true | _ -> false
let scope execution = Scope_id.autonomous_admission execution.id
let valid_time value = Float.is_finite value && value >= 0.
let valid_terminal = function Failed detail -> String.trim detail <> "" | Completed | Cancelled -> true

let validate_sources sources =
  let rec loop seen = function
    | [] -> Ok ()
    | source :: rest ->
      let identity = source.post_id in
      if List.mem identity seen then Error (Invalid_record "duplicate selected source")
      else loop (identity :: seen) rest
  in loop [] sources

let create ~id ~sources ~now =
  if not (valid_time now) then Error (Invalid_record "invalid admission time")
  else
    let* () = validate_sources sources in
    let* frame = Snapshot.admit Snapshot.empty (Snapshot.Fresh (Scope_id.autonomous_admission id))
      |> Result.map_error (fun error -> Invalid_record (Snapshot.error_to_string error)) in
    Ok { id; revision = 0L; sources; current_sources = sources; frame; phase = Preparing; created_at = now; updated_at = now }

let same_admission left right =
  Uuidm.equal left.id right.id && left.sources = right.sources

let projected_sources current projections =
  let rec loop originals previous projections =
    match originals, previous, projections with
    | [], [], [] -> Ok []
    | original :: originals, previous :: previous_tail, projection :: projections
      when projection.original = original
           && String.equal projection.observed.post_id original.post_id
           && Scope_id.equal projection.bound_scope (scope current)
           && projection.observed.admitted_revision >= previous.admitted_revision
           && projection.observed.checkpoint_retentions >= previous.checkpoint_retentions ->
        let* rest = loop originals previous_tail projections in
        Ok (projection.observed :: rest)
    | _ -> Error (Invalid_transition "source recheck must preserve each original admission and its exact bound scope")
  in
  loop current.sources current.current_sources projections

let recovery_origin = function
  | Preparing -> Some Unconfirmed_sources
  | Ready -> Some Confirmed_undispatched
  | Running -> Some Interrupted_execution
  | Suspended checkpoint -> Some (Checkpointed checkpoint)
  | Recovering recovery -> Some recovery.origin
  | Settled _ -> None

let apply ~now action current =
  if not (valid_time now) then Error (Invalid_transition "invalid transition time")
  else
    let* phase, frame, current_sources = match current.phase, action with
      | Preparing, Confirm_sources -> Ok (Ready, current.frame, current.current_sources)
      | Ready, Begin_execution -> Ok (Running, current.frame, current.current_sources)
      | (Preparing | Recovering { origin = Unconfirmed_sources; _ }), Recheck_sources projections ->
          let* sources = projected_sources current projections in
          Ok (Preparing, current.frame, sources)
      | (Ready | Recovering { origin = Confirmed_undispatched; _ }), Recheck_sources projections ->
          let* sources = projected_sources current projections in
          Ok (Ready, current.frame, sources)
      | (Suspended expected | Recovering { origin = Checkpointed expected; _ }),
          Resume_checkpoint checkpoint
          when Keeper_checkpoint_ref.equal expected checkpoint ->
          (* The accepted checkpoint owns continuation. Its original attention
             rows may already have been ACKed and need not be recreated. *)
          Ok (Running, current.frame, current.current_sources)
      | Running, Record_observation observation ->
          Snapshot.record current.frame ~scope:(scope current) observation
          |> Result.map (fun frame -> Running, frame, current.current_sources)
          |> Result.map_error (fun error -> Invalid_record (Snapshot.error_to_string error))
      | Running, Suspend checkpoint -> Ok (Suspended checkpoint, current.frame, current.current_sources)
      | phase, Require_reconciliation diagnostic when String.trim diagnostic <> "" ->
          (match recovery_origin phase with
           | Some origin -> Ok (Recovering {origin; diagnostic}, current.frame, current.current_sources)
           | None -> Error (Invalid_transition "terminal execution cannot enter recovery"))
      | (Preparing | Ready | Suspended _ | Recovering _), Settle (Cancelled | Failed _ as terminal)
      | Running, Settle terminal when valid_terminal terminal -> Ok (Settled terminal, current.frame, current.current_sources)
      | _ -> Error (Invalid_transition ("action is not admitted in " ^ phase_name current.phase)) in
    if phase = current.phase && Snapshot.equal frame current.frame && current_sources = current.current_sources
    then Ok current
    else if current.revision = Int64.max_int then Error Revision_exhausted
    else Ok { current with revision = Int64.succ current.revision; phase; frame; current_sources; updated_at = now }

let source_to_json source =
  `Assoc [ "post_id", `String source.post_id
         ; "admitted_revision", `Intlit (Int64.to_string source.admitted_revision)
         ; "checkpoint_retentions", `Int source.checkpoint_retentions
         ; "source_sha256", `String source.source_sha256 ]
let terminal_json = function
  | Completed -> `Assoc ["kind", `String "completed"]
  | Cancelled -> `Assoc ["kind", `String "cancelled"]
  | Failed detail -> `Assoc ["kind", `String "failed"; "detail", `String detail]
let checkpoint_json checkpoint =
  `Assoc [ "trace_id", `String (Keeper_id.Trace_id.to_string checkpoint.Keeper_checkpoint_ref.trace_id)
         ; "turn_count", `Int checkpoint.turn_count
         ; "sha256", `String checkpoint.sha256 ]
let recovery_origin_json = function
  | Unconfirmed_sources -> `Assoc ["kind", `String "unconfirmed_sources"]
  | Confirmed_undispatched -> `Assoc ["kind", `String "confirmed_undispatched"]
  | Interrupted_execution -> `Assoc ["kind", `String "interrupted_execution"]
  | Checkpointed checkpoint ->
      `Assoc ["kind", `String "checkpointed"; "checkpoint", checkpoint_json checkpoint]
let phase_json = function
  | Preparing -> `Assoc ["kind", `String "preparing"]
  | Ready -> `Assoc ["kind", `String "ready"]
  | Running -> `Assoc ["kind", `String "running"]
  | Recovering recovery ->
      `Assoc ["kind", `String "recovering"; "origin", recovery_origin_json recovery.origin;
              "detail", `String recovery.diagnostic]
  | Suspended checkpoint ->
      `Assoc ["kind", `String "suspended"; "checkpoint", checkpoint_json checkpoint]
  | Settled terminal -> `Assoc ["kind", `String "settled"; "terminal", terminal_json terminal]

let to_json execution =
  `Assoc [ "schema", `String "masc.keeper_autonomous_execution.v1"
         ; "id", `String (Uuidm.to_string execution.id)
         ; "revision", `Intlit (Int64.to_string execution.revision)
         ; "sources", `List (List.map source_to_json execution.sources)
         ; "current_sources", `List (List.map source_to_json execution.current_sources)
         ; "frame", Snapshot.to_json execution.frame
         ; "phase", phase_json execution.phase
         ; "created_at", `Float execution.created_at
         ; "updated_at", `Float execution.updated_at ]

let exact names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "missing, duplicate, or unexpected fields"
let field name fields = List.assoc name fields
let string name fields = match field name fields with `String value -> Ok value | _ -> Error (name ^ " must be a string")
let int64 name fields = match field name fields with
  | `Int n -> Ok (Int64.of_int n)
  | `Intlit value -> (match Int64.of_string_opt value with Some n -> Ok n | None -> Error (name ^ " exceeds int64"))
  | _ -> Error (name ^ " must be an integer")
let int name fields =
  let* n = int64 name fields in
  if n < 0L || n > Int64.of_int max_int then Error (name ^ " is out of range") else Ok (Int64.to_int n)
let time name fields =
  let value = match field name fields with `Float n -> Some n | `Int n -> Some (Float.of_int n) | _ -> None in
  match value with Some n when valid_time n -> Ok n | _ -> Error (name ^ " must be a finite nonnegative time")
let rec decode_list decode = function
  | [] -> Ok []
  | first :: rest -> let* first = decode first in let* rest = decode_list decode rest in Ok (first :: rest)
let source_of_json json =
  let* fields = exact ["post_id"; "admitted_revision"; "checkpoint_retentions"; "source_sha256"] json in
  let* post_id = string "post_id" fields in
  let* admitted_revision = int64 "admitted_revision" fields in
  let* checkpoint_retentions = int "checkpoint_retentions" fields in
  let* source_sha256 = string "source_sha256" fields in
  source_member ~post_id ~admitted_revision ~checkpoint_retentions ~source_sha256
let terminal_of_json json =
  let names = match json with `Assoc fields when List.mem_assoc "detail" fields -> ["kind";"detail"] | _ -> ["kind"] in
  let* fields = exact names json in
  let* kind = string "kind" fields in
  match kind, names with
  | "completed", ["kind"] -> Ok Completed
  | "cancelled", ["kind"] -> Ok Cancelled
  | "failed", ["kind";"detail"] ->
      let* detail = string "detail" fields in
      if String.trim detail = "" then Error "failure detail must not be blank" else Ok (Failed detail)
  | _ -> Error "invalid terminal state"
let checkpoint_of_json json =
  let* checkpoint = exact ["trace_id";"turn_count";"sha256"] json in
  let* trace_id = string "trace_id" checkpoint in
  let* trace_id = Keeper_id.Trace_id.of_string trace_id in
  let* turn_count = int "turn_count" checkpoint in
  let* sha256 = string "sha256" checkpoint in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count ~sha256
  |> Result.map_error (fun _ -> "invalid checkpoint identity")
let kind_of_json json =
  match json with
  | `Assoc fields -> (match List.assoc_opt "kind" fields with
      | Some (`String kind) -> Ok kind | _ -> Error "kind missing")
  | _ -> Error "expected an object"
let recovery_origin_of_json json =
  let* kind = kind_of_json json in
  match kind with
  | "unconfirmed_sources" | "confirmed_undispatched" | "interrupted_execution" ->
      let* _ = exact ["kind"] json in
      Ok (if kind = "unconfirmed_sources" then Unconfirmed_sources
          else if kind = "confirmed_undispatched" then Confirmed_undispatched
          else Interrupted_execution)
  | "checkpointed" ->
      let* fields = exact ["kind";"checkpoint"] json in
      checkpoint_of_json (field "checkpoint" fields) |> Result.map (fun checkpoint -> Checkpointed checkpoint)
  | _ -> Error "unknown recovery origin"
let phase_of_json json =
  let* kind = match json with
    | `Assoc fields -> (match List.assoc_opt "kind" fields with Some (`String kind) -> Ok kind | _ -> Error "phase kind missing")
    | _ -> Error "phase must be an object" in
  match kind with
  | "preparing" | "ready" | "running" ->
      let* _ = exact ["kind"] json in
      Ok (if kind = "preparing" then Preparing else if kind = "ready" then Ready else Running)
  | "recovering" ->
      let* fields = exact ["kind";"origin";"detail"] json in
      let* diagnostic = string "detail" fields in
      let* origin = recovery_origin_of_json (field "origin" fields) in
      if String.trim diagnostic = "" then Error "recovery detail is blank"
      else Ok (Recovering {origin; diagnostic})
  | "suspended" ->
      let* fields = exact ["kind";"checkpoint"] json in
      checkpoint_of_json (field "checkpoint" fields)
      |> Result.map (fun reference -> Suspended reference)
  | "settled" ->
      let* fields = exact ["kind";"terminal"] json in
      terminal_of_json (field "terminal" fields) |> Result.map (fun terminal -> Settled terminal)
  | _ -> Error "unknown execution phase"

let of_json json =
  let decode () =
    let* fields = exact ["schema";"id";"revision";"sources";"current_sources";"frame";"phase";"created_at";"updated_at"] json in
    let* schema = string "schema" fields in
    let* () = if schema = "masc.keeper_autonomous_execution.v1" then Ok () else Error "unsupported execution schema" in
    let* raw_id = string "id" fields in
    let* id = match Uuidm.of_string raw_id with
      | Some id when Uuidm.to_string id = raw_id -> Ok id | _ -> Error "noncanonical execution UUID" in
    let* revision = int64 "revision" fields in
    let* () = if revision < 0L then Error "negative execution revision" else Ok () in
    let* sources = match field "sources" fields with `List rows -> decode_list source_of_json rows | _ -> Error "sources must be a list" in
    let* () = validate_sources sources |> Result.map_error error_to_string in
    let* current_sources = match field "current_sources" fields with
      | `List rows -> decode_list source_of_json rows | _ -> Error "current_sources must be a list" in
    let* () =
      if List.length sources = List.length current_sources
         && List.for_all2 (fun initial current ->
              initial.post_id = current.post_id
              && current.admitted_revision >= initial.admitted_revision
              && current.checkpoint_retentions >= initial.checkpoint_retentions) sources current_sources
      then Ok () else Error "current source projections do not preserve original admissions" in
    let* frame = Snapshot.of_json (field "frame" fields) |> Result.map_error Snapshot.error_to_string in
    let expected = Scope_id.autonomous_admission id in
    let* () = match Snapshot.active frame, Snapshot.scope_ids frame with
      | Some active, [only] when Scope_id.equal active expected && Scope_id.equal only expected -> Ok ()
      | _ -> Error "execution frame must contain only its admitted scope" in
    let* phase = phase_of_json (field "phase" fields) in
    let* observations = Snapshot.observations frame ~scope:expected
      |> Result.map_error Snapshot.error_to_string in
    let* () = match phase with
      | Preparing when observations = [] -> Ok ()
      | Ready when revision >= 1L && observations = [] -> Ok ()
      | Running when revision >= 2L -> Ok ()
      | Suspended _ when revision >= 3L -> Ok ()
      | Recovering {origin = (Unconfirmed_sources | Confirmed_undispatched); _ }
          when revision >= 1L && observations = [] -> Ok ()
      | Recovering {origin = (Checkpointed _ | Interrupted_execution); _ }
          when revision >= 2L -> Ok ()
      | Settled _ when revision >= 1L -> Ok ()
      | _ -> Error "execution phase, revision and initial frame are incoherent" in
    let* created_at = time "created_at" fields in
    let* updated_at = time "updated_at" fields in
    Ok { id; revision; sources; current_sources; frame; phase; created_at; updated_at }
  in decode () |> Result.map_error (fun detail -> Invalid_record detail)
