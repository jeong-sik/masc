(** keeper-v2 #9: response-feedback typed model + deterministic aggregation.
    See {!Keeper_response_feedback} (.mli) for the contract and design trail. *)

type signal =
  | Helpful
  | Not_helpful
  | Cleared

type source =
  | Dashboard

type record =
  { keeper_id   : string
  ; turn_id     : Keeper_invariant.turn_id
  ; signal      : signal
  ; source      : source
  ; recorded_at : float
  }

(* ── Wire codec — strict, Parse-don't-validate (unknown ⇒ Error) ─────── *)

let signal_to_wire = function
  | Helpful -> "up"
  | Not_helpful -> "down"
  | Cleared -> "clear"

let signal_of_wire = function
  | "up" -> Ok Helpful
  | "down" -> Ok Not_helpful
  | "clear" -> Ok Cleared
  | other -> Error (Printf.sprintf "keeper_response_feedback: unknown signal %S" other)

let source_to_wire = function
  | Dashboard -> "dashboard"

let source_of_wire = function
  | "dashboard" -> Ok Dashboard
  | other -> Error (Printf.sprintf "keeper_response_feedback: unknown source %S" other)

let to_json (r : record) : Yojson.Safe.t =
  `Assoc
    [ ("keeper_id", `String r.keeper_id)
    ; ("turn_id", `String r.turn_id)
    ; ("signal", `String (signal_to_wire r.signal))
    ; ("source", `String (source_to_wire r.source))
    ; ("recorded_at", `Float r.recorded_at)
    ]

let of_json (json : Yojson.Safe.t) : (record, string) result =
  match json with
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    (match
       ( get "keeper_id"
       , get "turn_id"
       , get "signal"
       , get "source"
       , get "recorded_at" )
     with
     | ( Some (`String keeper_id)
       , Some (`String turn_id)
       , Some (`String sig_s)
       , Some (`String src_s)
       , Some recorded_at_j ) ->
       let recorded_at_r =
         match recorded_at_j with
         | `Float f -> Ok f
         | `Int i -> Ok (float_of_int i)
         | _ -> Error "keeper_response_feedback: recorded_at must be a number"
       in
       (match signal_of_wire sig_s, source_of_wire src_s, recorded_at_r with
        | Ok signal, Ok source, Ok recorded_at ->
          Ok { keeper_id; turn_id; signal; source; recorded_at }
        | Error e, _, _ -> Error e
        | _, Error e, _ -> Error e
        | _, _, Error e -> Error e)
     | _ -> Error "keeper_response_feedback: missing or mistyped field")
  | _ -> Error "keeper_response_feedback: expected JSON object"

(* ── Aggregation — pure, deterministic ───────────────────────────────── *)

module Turn_map = Map.Make (String)

type tally =
  { helpful     : int
  ; not_helpful : int
  ; cleared     : int
  ; net         : int
  ; malformed   : int
  ; last_at     : float option
  }

let empty_tally =
  { helpful = 0; not_helpful = 0; cleared = 0; net = 0; malformed = 0; last_at = None }

let tally_of_records (records : record list) : tally =
  (* Deduplicate by turn_id, keeping the record with the greatest [recorded_at]
     — the latest vote for that turn (a re-vote or [Cleared] supersedes an
     earlier one). [recorded_at] is the SINGLE authority for "latest", the same
     one [last_at] uses below, so the winner is independent of the input list
     order: a non-append read, a merge, or out-of-order input cannot change it.
     (Earlier this dedup used [Turn_map.add] = list-position-last, which
     disagreed with the [recorded_at]-based [last_at] — review CR.) On an exact
     [recorded_at] tie the later list element wins, deterministic for a fixed
     list. *)
  let latest =
    List.fold_left
      (fun m (r : record) ->
        Turn_map.update r.turn_id
          (function
            | None -> Some r
            | Some existing ->
              Some (if r.recorded_at >= existing.recorded_at then r else existing))
          m)
      Turn_map.empty
      records
  in
  let counted =
    Turn_map.fold
      (fun _turn_id (r : record) acc ->
        let acc =
          match r.signal with
          | Helpful -> { acc with helpful = acc.helpful + 1 }
          | Not_helpful -> { acc with not_helpful = acc.not_helpful + 1 }
          | Cleared -> { acc with cleared = acc.cleared + 1 }
        in
        let last_at =
          match acc.last_at with
          | None -> Some r.recorded_at
          | Some t -> Some (Float.max t r.recorded_at)
        in
        { acc with last_at })
      latest
      empty_tally
  in
  { counted with net = counted.helpful - counted.not_helpful }

(* ── Durable sink + log read — Stdlib I/O via the sibling-log family ──── *)

let record ~(config : Workspace.config) (r : record) : (unit, [ `Io of string ]) result =
  let path = Keeper_types_support.keeper_feedback_log_path config r.keeper_id in
  (* The feedback log shares the .policy/.decisions writer family (rotation
     included), but uses the Result boundary so every write failure is returned
     as [`Io] rather than depending on per-caller exception shape. *)
  match Keeper_types_support.append_jsonl_line_result path (to_json r) with
  | Ok () -> Ok ()
  | Error msg -> Error (`Io msg)

let read_tally ~(config : Workspace.config) ~keeper_id : (tally, [ `Io of string ]) result =
  let path = Keeper_types_support.keeper_feedback_log_path config keeper_id in
  match Fs_compat.load_jsonl_diagnostics path with
  | exception Sys_error msg -> Error (`Io msg)
  | jsons, json_malformed ->
    (* load_jsonl_diagnostics returns rows oldest-first + JSON-malformed count.
       A row that is valid JSON but not a valid record (of_json = Error) is an
       additional malformed line — counted, not silently skipped. *)
    let records, semantic_malformed =
      List.fold_left
        (fun (recs, bad) j ->
          match of_json j with
          | Ok r -> (r :: recs, bad)
          | Error _ -> (recs, bad + 1))
        ([], 0)
        jsons
    in
    let base = tally_of_records (List.rev records) in
    Ok { base with malformed = json_malformed + semantic_malformed }

(* ── HTTP wire helpers (GET/POST feedback route) ─────────────────────── *)

let tally_to_json (t : tally) : Yojson.Safe.t =
  let last_at = match t.last_at with Some f -> `Float f | None -> `Null in
  `Assoc
    [ ("helpful", `Int t.helpful)
    ; ("not_helpful", `Int t.not_helpful)
    ; ("cleared", `Int t.cleared)
    ; ("net", `Int t.net)
    ; ("malformed", `Int t.malformed)
    ; ("last_at", last_at)
    ]

let record_of_request_body ~keeper_id ~recorded_at (body : Yojson.Safe.t) :
    (record, string) result =
  match body with
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    (match get "signal", get "source", get "turn_id" with
     | Some (`String sig_s), Some (`String src_s), Some (`String turn_id) ->
       (match signal_of_wire sig_s, source_of_wire src_s with
        | Ok signal, Ok source ->
          if String.length (String.trim turn_id) = 0 then
            Error "keeper_response_feedback: turn_id is required"
          else Ok { keeper_id; turn_id; signal; source; recorded_at }
        | Error e, _ -> Error e
        | _, Error e -> Error e)
     | _ ->
       Error
         "keeper_response_feedback: body needs string signal/source/turn_id")
  | _ -> Error "keeper_response_feedback: expected JSON object"
