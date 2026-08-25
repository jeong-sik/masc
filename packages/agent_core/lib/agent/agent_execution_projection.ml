open Result_syntax
module Event = Execution_event
module Journal = Execution_journal
module Durable = Journal.Durable_read
module Sequence_map = Map.Make (Int)

module type ID = sig
  type t

  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Event_id = Event.Event_id
module Run_id = Event.Run_id
module Node_id = Event.Node_id
module Correlation_id = Event.Correlation_id

type output_block_kind =
  | Text_block
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
  | Image_block
  | Document_block
  | Audio_block

type node_kind =
  | Agent_run of { agent_name : string }
  | Agent_turn of { ordinal : int }
  | Provider_attempt of
      { ordinal : int
      ; target : Binding_identity.Redacted_snapshot.t
      }
  | Output_block of
      { ordinal : int
      ; block_kind : output_block_kind
      }
  | Tool_invocation of
      { provider_tool_use_id : string option
      ; tool_name : string
      ; schedule : Tool_contract.schedule
      ; completion : Tool_contract.completion
      }
  | Tool_attempt

type node =
  { node_id : Node_id.t
  ; run_id : Run_id.t
  ; parent_node_id : Node_id.t option
  ; kind : node_kind
  }

type node_update =
  | Provider_event of Yojson.Safe.t
  | Provider_response_snapshot of Llm_provider.Types.api_response
  | Output_delta of Yojson.Safe.t
  | Output_snapshot of Llm_provider.Types.content_block
  | Tool_input_delta of Yojson.Safe.t
  | Tool_input_snapshot of Llm_provider.Types.content_block
  | Tool_progress of Yojson.Safe.t
  | Tool_result of Llm_provider.Types.content_block

type failure_kind =
  | Provider_failure
  | Tool_failure
  | Hook_failure
  | Observer_failure
  | Persistence_failure
  | Protocol_failure
  | Internal_failure

type failure =
  { kind : failure_kind
  ; detail : string
  ; data : Yojson.Safe.t option
  }

type terminal =
  | Succeeded
  | Failed of failure
  | Cancelled of
      { reason : string option
      ; data : Yojson.Safe.t option
      }

type payload =
  | Node_opened of node
  | Node_updated of
      { node_id : Node_id.t
      ; update : node_update
      }
  | Node_closed of
      { node_id : Node_id.t
      ; terminal : terminal
      }

module External_source = Event.External_source

type cause =
  | Internal_event of Event_id.t
  | External_event of
      { source : External_source.t
      ; event_id : string
      }

type event =
  { event_id : Event_id.t
  ; run_id : Run_id.t
  ; correlation_id : Correlation_id.t
  ; seq : int
  ; parent_event_id : Event_id.t option
  ; causes : cause list
  ; payload : payload
  ; event_time : float
  ; observed_at : float
  ; source_clock : Event_envelope.source_clock
  }

type cursor =
  { scope_id : Durable.Scope_id.t
  ; seq : int
  }

type cursor_field =
  | Version
  | Scope_id
  | Sequence

type cursor_decode_error =
  | Cursor_not_object
  | Missing_cursor_field of cursor_field
  | Unexpected_cursor_field of string
  | Duplicate_cursor_field of cursor_field
  | Invalid_cursor_field of
      { field : cursor_field
      ; detail : string
      }
  | Unsupported_cursor_version of
      { expected : int
      ; actual : int
      }

type unexpected_store_error = Durable.unexpected_store_error =
  | Writer_already_active
  | Store_already_attached
  | Store_released
  | Store_release_forbidden
  | Resource_cleanup_failed
  | Construction_cleanup_failed
  | Store_already_exists
  | Correlation_mismatch
  | Sequence_conflict
  | Committed_content_conflict
  | Cursor_scope_mismatch
  | Cursor_ahead
  | Store_poisoned
  | Commit_outcome_unknown

type storage_failure = Durable.storage_failure =
  | Invalid_store_argument of string
  | Store_identity_failure of string
  | Store_io_failure of
      { operation : string
      ; detail : string
      }
  | Store_codec_failure of string
  | Store_not_found
  | Store_initialization_incomplete
  | Store_initialization_conflict
  | Unsupported_store_version of
      { expected : int
      ; actual : int
      }
  | Corrupt_store of
      { offset : int64
      ; detail : string
      }
  | Commit_authority_identity_changed
  | Commit_authority_regressed of
      { previous_committed_offset : int64
      ; actual_committed_offset : int64
      ; previous_last_seq : int
      ; actual_last_seq : int
      }
  | Unexpected_store_failure of
      { kind : unexpected_store_error
      ; detail : string
      }

type cursor_role =
  | After
  | Through

type error =
  | Invalid_limit of int
  | Cursor_scope_mismatch
  | Cursor_ahead of
      { cursor_role : cursor_role
      ; cursor_seq : int
      ; high_watermark : int
      }
  | Locator_not_found of Run_id.t
  | Locator_not_top_level of Run_id.t
  | Semantic_failure of
      { seq : int
      ; detail : string
      }
  | Storage_failure of storage_failure

type page =
  { events : event list
  ; next_cursor : cursor
  ; high_watermark : cursor
  ; has_more : bool
  }

type validated_snapshot =
  { durable : Durable.snapshot
  ; reducer : Journal.Reducer.t
  ; events : event Sequence_map.t
  }

type refresh_outcome = (validated_snapshot, error) result option

type in_flight_refresh =
  { promise : refresh_outcome Eio.Promise.t
  ; resolver : refresh_outcome Eio.Promise.u
  }

(** [mu] protects only snapshot reads, single-flight ownership, and
    publication; file I/O, decoding, and reduction run against an immutable
    base outside the lock. The durable snapshot's typed scope/correlation
    identity is the directory identity key; a path string is never treated as
    identity. Reducer and event maps are persistent immutable values shared
    between successive authority snapshots. *)
type t =
  { codec : Execution_codec_executor.t
  ; dir : Eio.Fs.dir_ty Eio.Path.t
  ; locator_run_id : Run_id.t
  ; scope_id : Durable.Scope_id.t
  ; mu : Eio.Mutex.t
  ; mutable snapshot : validated_snapshot
  ; mutable in_flight_refresh : in_flight_refresh option
  }

let cursor_version = 1

let cursor_to_yojson (cursor : cursor) =
  `Assoc
    [ "version", `Int cursor_version
    ; "scope_id", `String (Durable.Scope_id.to_string cursor.scope_id)
    ; "sequence", `Int cursor.seq
    ]
;;

let cursor_fields = [ "version", Version; "scope_id", Scope_id; "sequence", Sequence ]
let cursor_field_of_name name = List.assoc_opt name cursor_fields

let cursor_field_name = function
  | Version -> "version"
  | Scope_id -> "scope_id"
  | Sequence -> "sequence"
;;

let cursor_decode_error_to_string = function
  | Cursor_not_object -> "execution projection cursor must be an object"
  | Missing_cursor_field field ->
    "execution projection cursor is missing field " ^ cursor_field_name field
  | Unexpected_cursor_field field ->
    "execution projection cursor has unexpected field " ^ field
  | Duplicate_cursor_field field ->
    "execution projection cursor repeats field " ^ cursor_field_name field
  | Invalid_cursor_field { field; detail } ->
    Printf.sprintf
      "execution projection cursor field %s is invalid: %s"
      (cursor_field_name field)
      detail
  | Unsupported_cursor_version { expected; actual } ->
    Printf.sprintf
      "execution projection cursor version %d is unsupported; expected version %d"
      actual
      expected
;;

let cursor_of_yojson json =
  let* fields =
    match json with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error Cursor_not_object
  in
  let rec collect version scope_id sequence = function
    | [] -> Ok (version, scope_id, sequence)
    | (name, value) :: rest ->
      (match cursor_field_of_name name with
       | None -> Error (Unexpected_cursor_field name)
       | Some Version ->
         (match version with
          | Some _ -> Error (Duplicate_cursor_field Version)
          | None -> collect (Some value) scope_id sequence rest)
       | Some Scope_id ->
         (match scope_id with
          | Some _ -> Error (Duplicate_cursor_field Scope_id)
          | None -> collect version (Some value) sequence rest)
       | Some Sequence ->
         (match sequence with
          | Some _ -> Error (Duplicate_cursor_field Sequence)
          | None -> collect version scope_id (Some value) rest))
  in
  let* version, scope_id, sequence = collect None None None fields in
  let* version =
    match version with
    | None -> Error (Missing_cursor_field Version)
    | Some (`Int value) -> Ok value
    | Some _ ->
      Error (Invalid_cursor_field { field = Version; detail = "expected integer" })
  in
  let* () =
    if version = cursor_version
    then Ok ()
    else
      Error (Unsupported_cursor_version { expected = cursor_version; actual = version })
  in
  let* scope_id =
    match scope_id with
    | None -> Error (Missing_cursor_field Scope_id)
    | Some (`String value) ->
      Durable.Scope_id.of_string value
      |> Result.map_error (fun detail ->
        Invalid_cursor_field { field = Scope_id; detail })
    | Some _ ->
      Error (Invalid_cursor_field { field = Scope_id; detail = "expected string" })
  in
  let* seq =
    match sequence with
    | None -> Error (Missing_cursor_field Sequence)
    | Some (`Int value) when value >= 0 -> Ok value
    | Some (`Int _) ->
      Error
        (Invalid_cursor_field
           { field = Sequence; detail = "expected non-negative integer" })
    | Some _ ->
      Error (Invalid_cursor_field { field = Sequence; detail = "expected integer" })
  in
  Ok { scope_id; seq }
;;

let cursor_seq (cursor : cursor) = cursor.seq

let output_block_kind = function
  | Event.Text_block -> Text_block
  | Event.Thinking_block -> Thinking_block
  | Event.Reasoning_details_block -> Reasoning_details_block
  | Event.Redacted_thinking_block -> Redacted_thinking_block
  | Event.Image_block -> Image_block
  | Event.Document_block -> Document_block
  | Event.Audio_block -> Audio_block
;;

let node_kind = function
  | Event.Agent_run { agent_name } -> Agent_run { agent_name }
  | Event.Agent_turn { ordinal } -> Agent_turn { ordinal }
  | Event.Provider_attempt { ordinal; target } -> Provider_attempt { ordinal; target }
  | Event.Output_block { ordinal; block_kind = kind } ->
    Output_block { ordinal; block_kind = output_block_kind kind }
  | Event.Tool_invocation { provider_tool_use_id; tool_name; schedule; completion } ->
    Tool_invocation { provider_tool_use_id; tool_name; schedule; completion }
  | Event.Tool_attempt -> Tool_attempt
;;

let node value =
  { node_id = Event.node_id value
  ; run_id = Event.node_run_id value
  ; parent_node_id = Event.parent_node_id value
  ; kind = node_kind (Event.node_kind value)
  }
;;

let node_update = function
  | Event.Provider_event value -> Provider_event value
  | Event.Provider_response_snapshot value -> Provider_response_snapshot value
  | Event.Output_delta value -> Output_delta value
  | Event.Output_snapshot value -> Output_snapshot value
  | Event.Tool_input_delta value -> Tool_input_delta value
  | Event.Tool_input_snapshot value -> Tool_input_snapshot value
  | Event.Tool_progress value -> Tool_progress value
  | Event.Tool_result value -> Tool_result value
;;

let failure_kind = function
  | Event.Provider_failure -> Provider_failure
  | Event.Tool_failure -> Tool_failure
  | Event.Hook_failure -> Hook_failure
  | Event.Observer_failure -> Observer_failure
  | Event.Persistence_failure -> Persistence_failure
  | Event.Protocol_failure -> Protocol_failure
  | Event.Internal_failure -> Internal_failure
;;

let failure (value : Event.failure) =
  { kind = failure_kind value.kind; detail = value.detail; data = value.data }
;;

let terminal = function
  | Event.Succeeded -> Succeeded
  | Event.Failed value -> Failed (failure value)
  | Event.Cancelled { reason; data } -> Cancelled { reason; data }
;;

let payload = function
  | Event.Node_opened value -> Node_opened (node value)
  | Event.Node_updated { node_id; update } ->
    Node_updated { node_id; update = node_update update }
  | Event.Node_closed { node_id; terminal = value } ->
    Node_closed { node_id; terminal = terminal value }
;;

let cause = function
  | Event.Internal_event event_id -> Internal_event event_id
  | Event.External_event { source; event_id } -> External_event { source; event_id }
;;

let event value =
  let envelope = Event.envelope value in
  { event_id = Event.event_id value
  ; run_id = Event.run_id value
  ; correlation_id = Event.correlation_id value
  ; seq = Event.seq value
  ; parent_event_id = Event.parent_event_id value
  ; causes = List.map cause (Event.causes value)
  ; payload = payload (Event.payload value)
  ; event_time = envelope.Event_envelope.event_time
  ; observed_at = envelope.observed_at
  ; source_clock = envelope.source_clock
  }
;;

let storage_failure_to_string = function
  | Invalid_store_argument detail -> "invalid store argument: " ^ detail
  | Store_identity_failure detail -> "store identity failure: " ^ detail
  | Store_io_failure { operation; detail } -> operation ^ " failed: " ^ detail
  | Store_codec_failure detail -> "store codec failed: " ^ detail
  | Store_not_found -> "execution store does not exist"
  | Store_initialization_incomplete -> "execution store initialization is incomplete"
  | Store_initialization_conflict -> "execution store initialization conflicts"
  | Unsupported_store_version { expected; actual } ->
    Printf.sprintf "store version %d is unsupported; expected %d" actual expected
  | Corrupt_store { offset; detail } ->
    Printf.sprintf "execution store is corrupt at byte %Ld: %s" offset detail
  | Commit_authority_identity_changed -> "commit authority identity changed"
  | Commit_authority_regressed
      { previous_committed_offset
      ; actual_committed_offset
      ; previous_last_seq
      ; actual_last_seq
      } ->
    Printf.sprintf
      "commit authority regressed from offset %Ld sequence %d to offset %Ld sequence %d"
      previous_committed_offset
      previous_last_seq
      actual_committed_offset
      actual_last_seq
  | Unexpected_store_failure { kind = _; detail } ->
    "unexpected read-only execution store failure: " ^ detail
;;

let error_to_string = function
  | Invalid_limit limit ->
    Printf.sprintf "execution projection page limit must be positive, received %d" limit
  | Cursor_scope_mismatch -> "execution projection cursor belongs to another scope"
  | Cursor_ahead { cursor_role; cursor_seq; high_watermark } ->
    let role =
      match cursor_role with
      | After -> "after"
      | Through -> "through"
    in
    Printf.sprintf
      "execution projection %s cursor %d is ahead of high watermark %d"
      role
      cursor_seq
      high_watermark
  | Locator_not_found run_id ->
    "execution projection locator run was not found: " ^ Run_id.to_string run_id
  | Locator_not_top_level run_id ->
    "execution projection locator does not identify a top-level run: "
    ^ Run_id.to_string run_id
  | Semantic_failure { seq; detail } ->
    Printf.sprintf "execution projection topology failed at sequence %d: %s" seq detail
  | Storage_failure failure -> storage_failure_to_string failure
;;

let validate_snapshot ~locator_run_id ?previous (durable : Durable.snapshot) =
  let reducer, events =
    match previous with
    | None -> Journal.Reducer.empty, Sequence_map.empty
    | Some previous -> previous.reducer, previous.events
  in
  let rec reduce reducer events = function
    | [] -> Ok (reducer, events)
    | value :: rest ->
      Eio.Fiber.yield ();
      (match Journal.Reducer.apply reducer value with
       | Ok reducer ->
         let seq = Event.seq value in
         reduce reducer (Sequence_map.add seq (event value) events) rest
       | Error violation ->
         Error
           (Semantic_failure
              { seq = Event.seq value
              ; detail = Journal.show_invariant_violation violation
              }))
  in
  let* reducer, events = reduce reducer events (Durable.appended_events durable) in
  let* () =
    match Journal.Reducer.find_run reducer locator_run_id with
    | None -> Error (Locator_not_found locator_run_id)
    | Some view ->
      (match view.Journal.parent_attempt with
       | None -> Ok ()
       | Some _ -> Error (Locator_not_top_level locator_run_id))
  in
  if Journal.Reducer.last_seq reducer = Durable.last_seq durable
  then Ok { durable; reducer; events }
  else
    Error
      (Semantic_failure
         { seq = Durable.last_seq durable
         ; detail = "committed sequence does not equal the projected event count"
         })
;;

let load_snapshot ~codec ~dir ~locator_run_id ?previous () =
  let previous_durable = Option.map (fun value -> value.durable) previous in
  let* durable =
    Durable.read_snapshot ~codec ~dir ?previous:previous_durable ()
    |> Result.map_error (fun failure -> Storage_failure failure)
  in
  match previous with
  | Some previous when Durable.same_snapshot previous.durable durable -> Ok previous
  | None -> validate_snapshot ~locator_run_id durable
  | Some previous -> validate_snapshot ~locator_run_id ~previous durable
;;

let open_durable ~codec ~dir ~locator_run_id () =
  let* snapshot = load_snapshot ~codec ~dir ~locator_run_id () in
  Ok
    { codec
    ; dir
    ; locator_run_id
    ; scope_id = Durable.scope_id snapshot.durable
    ; mu = Eio.Mutex.create ()
    ; snapshot
    ; in_flight_refresh = None
    }
;;

let with_lock t f = Eio.Mutex.use_rw ~protect:true t.mu f
let cached_snapshot t = with_lock t (fun () -> t.snapshot)

let claim_refresh t =
  with_lock t (fun () ->
    match t.in_flight_refresh with
    | Some refresh -> `Follow refresh.promise
    | None ->
      let promise, resolver = Eio.Promise.create () in
      let refresh = { promise; resolver } in
      t.in_flight_refresh <- Some refresh;
      `Lead (t.snapshot, refresh))
;;

let settle_refresh t refresh outcome =
  Eio.Cancel.protect (fun () ->
    with_lock t (fun () ->
      t.in_flight_refresh <- None;
      Eio.Promise.resolve refresh.resolver outcome))
;;

let publish_snapshot t ~base candidate =
  with_lock t (fun () ->
    let current = t.snapshot in
    if current == base
    then (
      t.snapshot <- candidate;
      Ok candidate)
    else (
      let current_offset = Durable.committed_offset current.durable in
      let candidate_offset = Durable.committed_offset candidate.durable in
      let current_seq = Durable.last_seq current.durable in
      let candidate_seq = Durable.last_seq candidate.durable in
      let offset_order = Int64.compare candidate_offset current_offset in
      if offset_order <= 0 && candidate_seq <= current_seq
      then Ok current
      else if offset_order >= 0 && candidate_seq >= current_seq
      then (
        t.snapshot <- candidate;
        Ok candidate)
      else (
        let failure =
          Corrupt_store
            { offset = Int64.max current_offset candidate_offset
            ; detail =
                "concurrent commit authorities disagree on offset and sequence order"
            }
        in
        Error (Storage_failure failure))))
;;

let load_and_publish t base =
  let* candidate =
    load_snapshot
      ~codec:t.codec
      ~dir:t.dir
      ~locator_run_id:t.locator_run_id
      ~previous:base
      ()
  in
  publish_snapshot t ~base candidate
;;

let rec refresh t =
  match claim_refresh t with
  | `Follow promise ->
    (match Eio.Promise.await promise with
     | Some outcome -> outcome
     | None -> refresh t)
  | `Lead (base, in_flight) ->
    (match load_and_publish t base with
     | outcome ->
       settle_refresh t in_flight (Some outcome);
       Eio.Fiber.check ();
       outcome
     | exception exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       settle_refresh t in_flight None;
       Printexc.raise_with_backtrace exn backtrace)
;;

let beginning_cursor t = { scope_id = t.scope_id; seq = 0 }

let current_cursor t =
  let+ snapshot = refresh t in
  { scope_id = t.scope_id; seq = Durable.last_seq snapshot.durable }
;;

let cursor_matches scope_id (cursor : cursor) =
  Durable.Scope_id.equal scope_id cursor.scope_id
;;

let events_slice events ~first_seq ~count =
  let rec collect seq remaining acc =
    if remaining = 0
    then Ok (List.rev acc)
    else (
      Eio.Fiber.yield ();
      match Sequence_map.find_opt seq events with
      | Some event -> collect (seq + 1) (remaining - 1) (event :: acc)
      | None ->
        Error
          (Semantic_failure { seq; detail = "committed projection sequence is missing" }))
  in
  collect first_seq count []
;;

let read_page t ~after ?through ~limit () =
  if limit <= 0
  then Error (Invalid_limit limit)
  else if not (cursor_matches t.scope_id after)
  then Error Cursor_scope_mismatch
  else if
    match through with
    | None -> false
    | Some cursor -> not (cursor_matches t.scope_id cursor)
  then Error Cursor_scope_mismatch
  else
    let* snapshot =
      match through with
      | Some cursor ->
        let cached = cached_snapshot t in
        if cursor.seq <= Durable.last_seq cached.durable then Ok cached else refresh t
      | None -> refresh t
    in
    let high_watermark =
      match through with
      | None -> Durable.last_seq snapshot.durable
      | Some cursor -> cursor.seq
    in
    if high_watermark > Durable.last_seq snapshot.durable
    then
      Error
        (Cursor_ahead
           { cursor_role = Through
           ; cursor_seq = high_watermark
           ; high_watermark = Durable.last_seq snapshot.durable
           })
    else if after.seq > high_watermark
    then
      Error (Cursor_ahead { cursor_role = After; cursor_seq = after.seq; high_watermark })
    else (
      let count = min limit (high_watermark - after.seq) in
      let next_seq = after.seq + count in
      let+ events = events_slice snapshot.events ~first_seq:(after.seq + 1) ~count in
      { events
      ; next_cursor = { scope_id = t.scope_id; seq = next_seq }
      ; high_watermark = { scope_id = t.scope_id; seq = high_watermark }
      ; has_more = next_seq < high_watermark
      })
;;
