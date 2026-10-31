type selection =
  | Summarized of Librarian_continuity_snapshot.t
  | Absorbed of { trace_id : string; end_atom : int }
  | Without_snapshot
  | Not_applied

type range =
  { origin : Keeper_carried_front.origin
  ; first_atom : int
  ; total_atoms : int
  ; custom_projection_changed : bool
  }

let selection_to_json = function
  | Summarized snapshot ->
    `Assoc
      [ "kind", `String "summarized"
      ; "snapshot_origin", `String (match snapshot.origin with
          | Librarian_continuity_snapshot.Witnessed_history -> "witnessed_history"
          | Captured_checkpoint_prefix -> "captured_checkpoint_prefix")
      ; "trace_id", `String snapshot.trace_id
      ; "history_start_boundary_line", `Int snapshot.history_start_boundary_line
      ; "end_boundary_line", `Int snapshot.end_boundary_line
      ; "end_turn_ref", Ids.Turn_ref.to_yojson snapshot.end_turn_ref
      ; "end_atom", `Int snapshot.end_atom
      ; "covering_end_atom", `Int snapshot.covering_end_atom
      ; "covering_last_atom_digest", `String snapshot.covering_last_atom_digest
      ; "last_atom_digest", `String snapshot.last_atom_digest
      ; "catch_up_end_atom", (match snapshot.catch_up_end_atom with
          | Some atom -> `Int atom | None -> `Null)
      ; "unread_messages", Keeper_librarian_unread.list_to_json snapshot.unread_messages
      ; "prefix_sha256", `String snapshot.prefix_sha256
      ; "working_state_sha256",
        `String Agent_core_sha256.(digest_string snapshot.working_state |> to_hex)
      ]
  | Absorbed { trace_id; end_atom } ->
    `Assoc [ "kind", `String "absorbed"; "trace_id", `String trace_id;
             "end_atom", `Int end_atom ]
  | Without_snapshot -> `Assoc [ "kind", `String "without_snapshot" ]
  | Not_applied -> `Assoc [ "kind", `String "not_applied" ]

let origin_to_json = function
  | Keeper_carried_front.Turn_start_unknown _ ->
    `Assoc [ "kind", `String "turn_start_unknown" ]
  | (Keeper_carried_front.Carried _
    | Librarian_snapshot _ | Librarian_progress _ | Past_librarian_point _
    | Turn_start _) as origin -> Keeper_carried_front.origin_to_json origin

let to_json ~keeper ~turn_ref ~unread ~runtime_id ~selection ~range ~wire =
  `Assoc
    [ "schema", `String "masc.continuity-request.v3"
    ; "keeper", `String keeper
    ; "turn_ref", (match turn_ref with Some value -> Ids.Turn_ref.to_yojson value | None -> `Null)
    ; "association", `String (match range with Some _ -> "projection_associated" | None -> "projection_unavailable")
    ; "evidence", `String "pre_dispatch_projection_and_selection"
    ; "runtime_id", `String runtime_id
    ; "binding", `String (match wire.Llm_provider.Request_wire_observer.capture_id with
        | Some _ -> "capture_identified" | None -> "unbound")
    ; "wire", Llm_provider.Request_wire_observer.observation_to_yojson wire
    ; "unread", Keeper_librarian_request_unread.to_json unread
    ; "selection", selection_to_json selection
    ; "bounded_range", (match range with None -> `Null | Some (range : range) -> `Assoc
        [ "origin", origin_to_json range.origin
        ; "first_atom", `Int range.first_atom
        ; "total_atoms", `Int range.total_atoms
        ; "custom_projection_changed", `Bool range.custom_projection_changed
        ])
    ]

let record_best_effort ~config ~keeper_name ~turn_ref ~unread ~runtime_id ~selection ~range ~wire =
  let append () =
    let location =
      Dated_jsonl.Store.keeper
        (Workspace.dated_store_root config)
        ~keeper:keeper_name
        Dated_jsonl.Store.Keeper.Continuity_requests
    in
    Dated_jsonl.append (Dated_jsonl.open_store location)
      (to_json ~keeper:keeper_name ~turn_ref ~unread ~runtime_id ~selection ~range ~wire)
  in
  match append () with
  | () -> ()
  | exception exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception (Eio.Time.Timeout as exn) -> raise exn
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
  | exception exn ->
    Log.Keeper.warn ~keeper_name "continuity request evidence not stored: %s"
      (Printexc.to_string exn)
