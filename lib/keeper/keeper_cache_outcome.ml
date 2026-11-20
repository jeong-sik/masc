module Snapshot = Keeper_provider_input_snapshot
module Cost_events = Keeper_hooks_agent_core_cost_events

let schema = "masc.keeper-cache-outcome.v1"

(* The One_hour class asks Anthropic for [ttl = "1h"]. *)
let one_hour_s = 3600.0

(* Cost rows carry RFC 3339 timestamps without a fraction of a second. A row's
   true end lies within the second after its timestamp, so every start the
   walk derives is known to that second. *)
let ledger_clock_resolution_s = 1.0

let seconds_per_day = 86_400.0
let milliseconds_per_second = 1_000.0

type request =
  { turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; scope : Runtime_usage_scope.t
  ; ended_at : float
  ; latency_ms : int option
  ; cache_read_tokens : int option
  ; cache_creation_tokens : int option
  ; lifetime : Agent_core.Types.cache_write_lifetime option
  }

(* The earliest start the row allows: its whole-second end minus the measured
   latency. *)
let recorded_start (request : request) =
  Option.map
    (fun latency_ms ->
       request.ended_at -. (Float.of_int latency_ms /. milliseconds_per_second))
    request.latency_ms
;;

(* ── Ledger rows ─────────────────────────────────────────────── *)

type row_kind =
  | Raw of (request, string) result
  | Settled
  | Attempt_settled

type ledger_row =
  | Unattributed
      (* Not JSON, or not a row the current contract decodes: whose it is
         cannot be known. *)
  | Other_row
      (* Another Keeper's row, or a manual row that counts no request. *)
  | Keeper_row of
      { row_turn : Ids.Turn_ref.t
      ; row_ended_at : float
      ; kind : row_kind
      }

let request_of_row ~turn_ref ~scope ~ended_at json : (request, string) result =
  match Cost_events.request_cache_fields_of_json json with
  | Error detail -> Error detail
  | Ok { Cost_events.runtime_id = None; _ } -> Error "a request row names no runtime"
  | Ok
      { Cost_events.runtime_id = Some runtime_id
      ; request_latency_ms
      ; cache_creation_tokens
      ; cache_read_tokens
      ; cache_write_lifetime
      } ->
    Ok
      { turn_ref
      ; runtime_id
      ; scope
      ; ended_at
      ; latency_ms = request_latency_ms
      ; cache_read_tokens
      ; cache_creation_tokens
      ; lifetime = cache_write_lifetime
      }
;;

let read_row ~keeper (entry : Dated_jsonl.recent_entry) =
  match entry with
  | Dated_jsonl.Malformed_json _ -> Unattributed
  | Dated_jsonl.Parsed json ->
    (match Cost_ledger.of_json json with
     | Error _ -> Unattributed
     | Ok (row : Cost_ledger.t) ->
       if not (String.equal row.Cost_ledger.agent keeper)
       then Other_row
       else (
         match row.Cost_ledger.source with
         | Cost_ledger.Manual_cli -> Other_row
         | Cost_ledger.Auto_trajectory identity ->
           let row_turn =
             Ids.Turn_ref.make
               ~trace_id:identity.Cost_ledger.trace_id
               ~absolute_turn:identity.Cost_ledger.keeper_turn_id
           in
           let row_ended_at = row.Cost_ledger.ts_unix in
           let kind =
             match row.Cost_ledger.usage_projection with
             | Cost_ledger.Raw_observation scope ->
               Raw (request_of_row ~turn_ref:row_turn ~scope ~ended_at:row_ended_at json)
             | Cost_ledger.Resolved_delta -> Settled
             | Cost_ledger.Resolved_attempt_delta _ -> Attempt_settled
           in
           Keeper_row { row_turn; row_ended_at; kind }))
;;

(* ── Walk ────────────────────────────────────────────────────── *)

type earlier_search =
  | Earlier_absent of { horizon_s : float }
  | Earlier_found of
      { request : request
      ; turn_settled : bool
      }

type walked =
  | Turn_absent
  | Row_unreadable of string
  | Turn_not_per_request of request
  | Turn_found of
      { first : request
      ; earlier : earlier_search
      ; other_runtime_since : string option
      }

type seeking =
  { first : request
  ; horizon_s : float
  ; floor : float
      (* A row of this Keeper that ended before [floor] started more than
         [horizon_s] before the first request, and so did every older row. *)
  ; settled : Ids.Turn_ref.t list
  ; other_runtime_since : string option
  }

type phase =
  | Seeking_turn
  | In_turn of request
      (* The oldest row of the turn seen so far. *)
  | Seeking_earlier of seeking
  | Walked of walked

type walk =
  { walk_keeper : string
  ; walk_turn : Ids.Turn_ref.t
  ; horizon_of : string -> float
  ; passed_over : int
  ; phase : phase
  }

let start ~keeper ~turn_ref ~horizon_s =
  { walk_keeper = keeper
  ; walk_turn = turn_ref
  ; horizon_of = horizon_s
  ; passed_over = 0
  ; phase = Seeking_turn
  }
;;

let seeking_from ~horizon_of (first : request) =
  let horizon_s = horizon_of first.runtime_id in
  let anchor =
    match recorded_start first with
    | Some start -> start
    (* The end bounds the start from above: the search then narrows by the
       request's own duration, and its idle time is reported unrecorded. *)
    | None -> first.ended_at
  in
  (* The clock's second is subtracted so that a request inside the horizon at
     any start the rows allow is still found. *)
  { first
  ; horizon_s
  ; floor = anchor -. horizon_s -. ledger_clock_resolution_s
  ; settled = []
  ; other_runtime_since = None
  }
;;

let nothing_earlier (seeking : seeking) =
  Turn_found
    { first = seeking.first
    ; earlier = Earlier_absent { horizon_s = seeking.horizon_s }
    ; other_runtime_since = seeking.other_runtime_since
    }
;;

(* What follows once [first] is known to be the turn's first request. *)
type after_first =
  | Search_earlier of seeking
  | First_ends_walk of walked

let first_request_known ~horizon_of (first : request) =
  match first.scope with
  | Runtime_usage_scope.Per_request -> Search_earlier (seeking_from ~horizon_of first)
  | Runtime_usage_scope.Turn_total
  | Runtime_usage_scope.Conversation_cumulative
  | Runtime_usage_scope.Usage_scope_unavailable ->
    First_ends_walk (Turn_not_per_request first)
;;

let seeking_turn ~turn_ref ~row_turn kind =
  if Ids.Turn_ref.equal row_turn turn_ref
  then (
    match kind with
    | Raw (Ok request) -> In_turn request
    | Raw (Error detail) -> Walked (Row_unreadable detail)
    | Settled | Attempt_settled -> Seeking_turn)
  else if Ids.Turn_ref.absolute_turn row_turn < Ids.Turn_ref.absolute_turn turn_ref
  then Walked Turn_absent
  else Seeking_turn
;;

let seeking_earlier (seeking : seeking) ~row_turn ~row_ended_at kind =
  if row_ended_at < seeking.floor
  then Walked (nothing_earlier seeking)
  else (
    match kind with
    | Raw (Error detail) -> Walked (Row_unreadable detail)
    | Raw (Ok request) when String.equal request.runtime_id seeking.first.runtime_id ->
      Walked
        (Turn_found
           { first = seeking.first
           ; earlier =
               Earlier_found
                 { request
                 ; turn_settled =
                     List.exists (Ids.Turn_ref.equal request.turn_ref) seeking.settled
                 }
           ; other_runtime_since = seeking.other_runtime_since
           })
    | Raw (Ok request) ->
      (match seeking.other_runtime_since with
       | Some _ -> Seeking_earlier seeking
       | None ->
         Seeking_earlier { seeking with other_runtime_since = Some request.runtime_id })
    | Settled -> Seeking_earlier { seeking with settled = row_turn :: seeking.settled }
    | Attempt_settled -> Seeking_earlier seeking)
;;

let visit walk entry =
  match read_row ~keeper:walk.walk_keeper entry with
  | Unattributed ->
    (match walk.phase with
     | Walked _ -> walk
     | Seeking_turn | In_turn _ | Seeking_earlier _ ->
       { walk with passed_over = walk.passed_over + 1 })
  | Other_row -> walk
  | Keeper_row { row_turn; row_ended_at; kind } ->
    let phase =
      match walk.phase with
      | Walked _ as phase -> phase
      | Seeking_turn -> seeking_turn ~turn_ref:walk.walk_turn ~row_turn kind
      | In_turn first when Ids.Turn_ref.equal row_turn walk.walk_turn ->
        (match kind with
         | Raw (Ok request) -> In_turn request
         | Raw (Error detail) -> Walked (Row_unreadable detail)
         | Settled | Attempt_settled -> In_turn first)
      (* A row older than every row of the turn: [first] is its first
         request, and this row is the first candidate for the earlier one. *)
      | In_turn first ->
        (match first_request_known ~horizon_of:walk.horizon_of first with
         | Search_earlier seeking -> seeking_earlier seeking ~row_turn ~row_ended_at kind
         | First_ends_walk walked -> Walked walked)
      | Seeking_earlier seeking -> seeking_earlier seeking ~row_turn ~row_ended_at kind
    in
    { walk with phase }
;;

let finished walk =
  match walk.phase with
  | Walked _ -> true
  | Seeking_turn | In_turn _ | Seeking_earlier _ -> false
;;

let reads_before walk ended_before =
  match walk.phase with
  | Walked _ -> false
  | Seeking_turn | In_turn _ -> true
  | Seeking_earlier seeking -> ended_before >= seeking.floor
;;

(* What the walk found once no older row is left to read. *)
let conclude walk =
  match walk.phase with
  | Walked walked -> walked
  | Seeking_turn -> Turn_absent
  | In_turn first ->
    (match first_request_known ~horizon_of:walk.horizon_of first with
     | Search_earlier seeking -> nothing_earlier seeking
     | First_ends_walk walked -> walked)
  | Seeking_earlier seeking -> nothing_earlier seeking
;;

(* ── Outcome ─────────────────────────────────────────────────── *)

type lifetime_check =
  | Outlived
  | Within
  | Undecided

type default_unknown =
  | Default_undeclared
  | Runtime_inactive

type lifetime =
  | Lifetime_unrecorded
  | Provider_default_unknown of default_unknown
  | Lifetime_declared of
      { lifetime_s : float
      ; check : lifetime_check
      }

type idle =
  | Start_unrecorded
  | Idle of
      { idle_s : float
      ; lifetime : lifetime
      }

type not_compared =
  | Earlier_turn_not_settled
  | Snapshot_unread of
      { turn_ref : Ids.Turn_ref.t
      ; detail : string
      }
  | Snapshot_of_other_runtime of
      { turn_ref : Ids.Turn_ref.t
      ; runtime_profile : string
      }

type prefix =
  | Compared of
      { system_changed : bool
      ; tools_changed : bool
      ; messages : Keeper_projection_change.message_change
      }
  | Not_compared of not_compared

type earlier =
  | No_earlier_request of { horizon_s : float }
  | Earlier of
      { request : request
      ; idle : idle
      ; prefix : prefix
      }

type t =
  | Turn_not_in_ledger
  | Ledger_row_unreadable of string
  | Not_per_request of request
  | First_request of
      { request : request
      ; other_runtime_since : string option
      ; earlier : earlier
      }

type snapshot_view =
  { runtime_profile : string
  ; parts : Snapshot.part list
  }

let snapshot_view (manifest : Snapshot.manifest) =
  { runtime_profile = manifest.Snapshot.mf_snapshot.Snapshot.runtime_profile
  ; parts = manifest.Snapshot.mf_parts
  }
;;

(* The idle time is known to the clock's second at each end, so a check only
   says outlived or within when the whole uncertainty lies on one side. *)
let lifetime_check ~idle_s ~lifetime_s =
  if idle_s -. ledger_clock_resolution_s >= lifetime_s
  then Outlived
  else if idle_s +. ledger_clock_resolution_s <= lifetime_s
  then Within
  else Undecided
;;

let idle ~provider_default_s ~(earlier : request) ~(current : request) =
  match recorded_start earlier, recorded_start current with
  | Some earlier_start, Some current_start ->
    let idle_s = current_start -. earlier_start in
    let declared lifetime_s =
      Lifetime_declared { lifetime_s; check = lifetime_check ~idle_s ~lifetime_s }
    in
    let lifetime =
      match earlier.lifetime with
      | None -> Lifetime_unrecorded
      | Some Agent_core.Types.One_hour -> declared one_hour_s
      | Some Agent_core.Types.Provider_default ->
        (match provider_default_s earlier.runtime_id with
         | Ok lifetime_s -> declared lifetime_s
         | Error unknown -> Provider_default_unknown unknown)
    in
    Idle { idle_s; lifetime }
  | None, (Some _ | None) | Some _, None -> Start_unrecorded
;;

let system_sha256 parts =
  List.find_map
    (fun (part : Snapshot.part) ->
       match part.Snapshot.part_kind with
       | Snapshot.System_prompt -> Some part.Snapshot.part_sha256
       | Snapshot.Message _ | Snapshot.Tool_schema _ -> None)
    parts
;;

(* A turn's snapshot holds its last request. It describes [request] only when
   the same runtime answered that last request. *)
let snapshot_digests ~(request : request) snapshot =
  match snapshot with
  | Error detail -> Error (Snapshot_unread { turn_ref = request.turn_ref; detail })
  | Ok (view : snapshot_view) ->
    if not (String.equal view.runtime_profile request.runtime_id)
    then
      Error
        (Snapshot_of_other_runtime
           { turn_ref = request.turn_ref; runtime_profile = view.runtime_profile })
    else (
      match Keeper_projection_change.digests_of_parts view.parts with
      | Error detail -> Error (Snapshot_unread { turn_ref = request.turn_ref; detail })
      | Ok digests -> Ok (system_sha256 view.parts, digests))
;;

let compare_prefix ~earlier ~earlier_snapshot ~current ~current_snapshot =
  match
    ( snapshot_digests ~request:earlier earlier_snapshot
    , snapshot_digests ~request:current current_snapshot )
  with
  | Error reason, (Ok _ | Error _) | Ok _, Error reason -> Not_compared reason
  | Ok (earlier_system, earlier_digests), Ok (current_system, current_digests) ->
    Compared
      { system_changed = not (Option.equal String.equal earlier_system current_system)
      ; tools_changed =
          Keeper_projection_change.tool_schemas_differ
            ~previous:earlier_digests
            ~current:current_digests
      ; messages =
          Keeper_projection_change.compare_messages
            ~previous:earlier_digests
            ~current:current_digests
      }
;;

type reading =
  { keeper : string
  ; turn_ref : Ids.Turn_ref.t
  ; unattributed_rows : int
  ; outcome : t
  }

let reading_of_walk walk ~provider_default_s ~current_snapshot ~earlier_snapshot =
  let outcome =
    match conclude walk with
    | Turn_absent -> Turn_not_in_ledger
    | Row_unreadable detail -> Ledger_row_unreadable detail
    | Turn_not_per_request request -> Not_per_request request
    | Turn_found { first; earlier = Earlier_absent { horizon_s }; other_runtime_since } ->
      First_request
        { request = first; other_runtime_since; earlier = No_earlier_request { horizon_s } }
    | Turn_found
        { first; earlier = Earlier_found { request; turn_settled }; other_runtime_since } ->
      let prefix =
        match turn_settled with
        | false -> Not_compared Earlier_turn_not_settled
        | true ->
          compare_prefix
            ~earlier:request
            ~earlier_snapshot:(earlier_snapshot request.turn_ref)
            ~current:first
            ~current_snapshot
      in
      First_request
        { request = first
        ; other_runtime_since
        ; earlier =
            Earlier
              { request
              ; idle = idle ~provider_default_s ~earlier:request ~current:first
              ; prefix
              }
        }
  in
  { keeper = walk.walk_keeper
  ; turn_ref = walk.walk_turn
  ; unattributed_rows = walk.passed_over
  ; outcome
  }
;;

(* ── JSON ────────────────────────────────────────────────────── *)

let kind_field = "kind"
let turn_ref_field = "turn_ref"
let request_field = "request"
let detail_field = "detail"

let tagged kind (fields : (string * Yojson.Safe.t) list) : Yojson.Safe.t =
  `Assoc ((kind_field, `String kind) :: fields)
;;

let turn_ref_json turn_ref : Yojson.Safe.t = `String (Ids.Turn_ref.to_string turn_ref)

let optional (to_json : 'a -> Yojson.Safe.t) : 'a option -> Yojson.Safe.t = function
  | Some value -> to_json value
  | None -> `Null
;;

let request_to_json (request : request) : Yojson.Safe.t =
  `Assoc
    [ turn_ref_field, turn_ref_json request.turn_ref
    ; "runtime_id", `String request.runtime_id
    ; "scope", `String (Runtime_usage_scope.to_string request.scope)
    ; "ended_at", `Float request.ended_at
    ; "latency_ms", optional (fun ms -> `Int ms) request.latency_ms
    ; "cache_read_tokens", optional (fun count -> `Int count) request.cache_read_tokens
    ; ( "cache_creation_tokens"
      , optional (fun count -> `Int count) request.cache_creation_tokens )
    ; ( "cache_write_lifetime"
      , optional
          (fun lifetime ->
             `String (Agent_core.Types.cache_write_lifetime_to_string lifetime))
          request.lifetime )
    ]
;;

let lifetime_check_to_string = function
  | Outlived -> "outlived"
  | Within -> "within"
  | Undecided -> "undecided"
;;

let default_unknown_to_string = function
  | Default_undeclared -> "undeclared"
  | Runtime_inactive -> "runtime_inactive"
;;

let lifetime_to_json = function
  | Lifetime_unrecorded -> tagged "unrecorded" []
  | Provider_default_unknown unknown ->
    tagged
      "provider_default_unknown"
      [ "reason", `String (default_unknown_to_string unknown) ]
  | Lifetime_declared { lifetime_s; check } ->
    tagged
      "declared"
      [ "lifetime_s", `Float lifetime_s
      ; "check", `String (lifetime_check_to_string check)
      ]
;;

let idle_to_json = function
  | Start_unrecorded -> tagged "start_unrecorded" []
  | Idle { idle_s; lifetime } ->
    tagged "idle" [ "idle_s", `Float idle_s; "lifetime", lifetime_to_json lifetime ]
;;

let not_compared_to_json = function
  | Earlier_turn_not_settled -> tagged "earlier_turn_not_settled" []
  | Snapshot_unread { turn_ref; detail } ->
    tagged
      "snapshot_unread"
      [ turn_ref_field, turn_ref_json turn_ref; detail_field, `String detail ]
  | Snapshot_of_other_runtime { turn_ref; runtime_profile } ->
    tagged
      "snapshot_of_other_runtime"
      [ turn_ref_field, turn_ref_json turn_ref
      ; "runtime_profile", `String runtime_profile
      ]
;;

let prefix_to_json = function
  | Compared { system_changed; tools_changed; messages } ->
    tagged
      "compared"
      [ "system_changed", `Bool system_changed
      ; "tools_changed", `Bool tools_changed
      ; "messages", Keeper_projection_change.message_change_to_json messages
      ]
  | Not_compared reason -> tagged "not_compared" [ "reason", not_compared_to_json reason ]
;;

let earlier_to_json = function
  | No_earlier_request { horizon_s } -> tagged "none_within" [ "horizon_s", `Float horizon_s ]
  | Earlier { request; idle; prefix } ->
    tagged
      "earlier"
      [ request_field, request_to_json request
      ; "idle", idle_to_json idle
      ; "prefix", prefix_to_json prefix
      ]
;;

let outcome_to_json = function
  | Turn_not_in_ledger -> tagged "turn_not_in_ledger" []
  | Ledger_row_unreadable detail ->
    tagged "ledger_row_unreadable" [ detail_field, `String detail ]
  | Not_per_request request ->
    tagged "not_per_request" [ request_field, request_to_json request ]
  | First_request { request; other_runtime_since; earlier } ->
    tagged
      "first_request"
      [ request_field, request_to_json request
      ; ( "other_runtime_since"
        , optional (fun runtime_id -> `String runtime_id) other_runtime_since )
      ; "earlier", earlier_to_json earlier
      ]
;;

let to_json (reading : reading) =
  `Assoc
    [ "schema", `String schema
    ; "keeper", `String reading.keeper
    ; turn_ref_field, turn_ref_json reading.turn_ref
    ; "unattributed_rows", `Int reading.unattributed_rows
    ; "outcome", outcome_to_json reading.outcome
    ]
;;

(* ── Reading ─────────────────────────────────────────────────── *)

type read_error = Ledger_unreadable of Dated_jsonl.read_error

let read_error_to_string (Ledger_unreadable error) =
  "cost ledger: " ^ Dated_jsonl.read_error_to_string error
;;

let day_start ts = Float.floor (ts /. seconds_per_day) *. seconds_per_day

(* Day files are read newest first. A row lands in the day file of the moment
   it was appended, after its timestamp, so every row of a day's files ended
   before that day did. *)
let walk_ledger store walk ~born_at ~until =
  let walk = ref walk in
  let visit_entry entry =
    walk := visit !walk entry;
    if finished !walk then Some () else None
  in
  let rec read_files = function
    | [] -> Ok ()
    | path :: older ->
      (match Dated_jsonl.find_latest_entry_in_file_result path visit_entry with
       | Error error -> Error error
       | Ok (Some ()) -> Ok ()
       | Ok None -> read_files older)
  in
  let first_day = day_start born_at in
  let rec read_days day =
    if day < first_day || not (reads_before !walk (day +. seconds_per_day))
    then Ok ()
    else (
      let key = Jsonl_writer.day_key ~ts:day in
      match Dated_jsonl.range_day_file_paths_result store ~since:key ~until:key with
      | Error error -> Error error
      | Ok paths_oldest_first ->
        (match read_files (List.rev paths_oldest_first) with
         | Error error -> Error error
         | Ok () -> if finished !walk then Ok () else read_days (day -. seconds_per_day)))
  in
  Result.map (fun () -> !walk) (read_days (day_start until))
;;

let read ~config ~keeper ~turn_ref ~born_at ~provider_default_s =
  (* A runtime whose default is not known is searched for an hour back: the
     longest lifetime a request can name. *)
  let horizon_s runtime_id =
    match provider_default_s runtime_id with
    | Ok lifetime_s -> Float.max one_hour_s lifetime_s
    | Error (Default_undeclared | Runtime_inactive) -> one_hour_s
  in
  let manifest turn_ref = Snapshot.read_manifest ~config ~keeper ~turn_ref in
  let view result =
    result |> Result.map snapshot_view |> Result.map_error Snapshot.read_error_to_string
  in
  let current_manifest = manifest turn_ref in
  let until =
    match current_manifest with
    | Ok current -> current.Snapshot.mf_snapshot.Snapshot.captured_at
    | Error _ -> Time_compat.now ()
  in
  let store = Cost_ledger.store_of_base_path ~base_path:config.Workspace.base_path in
  match walk_ledger store (start ~keeper ~turn_ref ~horizon_s) ~born_at ~until with
  | Error error -> Error (Ledger_unreadable error)
  | Ok walk ->
    Ok
      (reading_of_walk
         walk
         ~provider_default_s
         ~current_snapshot:(view current_manifest)
         ~earlier_snapshot:(fun turn_ref -> view (manifest turn_ref)))
;;
