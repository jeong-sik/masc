(* See keeper_canary_failover.mli. *)

type error_kind = Error_kind of string

let error_kind_of_wire s = Error_kind s
let error_kind_render (Error_kind s) = s

type attempt = {
  ts : string;
  keeper_turn_id : int option;
  event : attempt_event;
  runtime_id : string;
  error_kind : error_kind option;
}

and attempt_event =
  | Routed
  | Failed
  | Completed

type mode =
  | In_turn
  | Deferred
  | Not_observed

let attempt_event_of_wire = function
  | "runtime_routed" -> Some Routed
  | "runtime_failed" -> Some Failed
  | "runtime_completed" -> Some Completed
  | _ -> None

let attempt_event_to_string = function
  | Routed -> "routed"
  | Failed -> "failed"
  | Completed -> "completed"

let ( let* ) = Result.bind

let parse_row (j : Yojson.Safe.t) : (attempt option, string) result =
  match j with
  | `Assoc kvs ->
    (match List.assoc_opt "event" kvs with
     | Some (`String wire_event) ->
       (match attempt_event_of_wire wire_event with
        | None -> Ok None
        | Some event ->
          let* ts =
            match List.assoc_opt "ts" kvs with
            | Some (`String ts) -> Ok ts
            | _ -> Error (Printf.sprintf "%s row: missing ts" wire_event)
          in
          let decision_kvs =
            match List.assoc_opt "decision" kvs with
            | Some (`Assoc decision_kvs) -> decision_kvs
            | _ -> []
          in
          (* Attribution source: the lane walk records the attempted
             candidate as decision.runtime_id while the row's top-level
             runtime_id stays the lane id ("lanes shadow runtimes").
             Rows emitted outside a lane walk carry no decision.runtime_id
             and there the top-level id is already the concrete runtime
             (#28871). *)
          let* runtime_id =
            match List.assoc_opt "runtime_id" decision_kvs with
            | Some (`String candidate) -> Ok candidate
            | _ ->
              (match List.assoc_opt "runtime_id" kvs with
               | Some (`String id) -> Ok id
               | _ ->
                 Error (Printf.sprintf "%s row: missing runtime_id" wire_event))
          in
          let keeper_turn_id =
            match List.assoc_opt "keeper_turn_id" kvs with
            | Some (`Int n) -> Some n
            | _ -> None
          in
          let error_kind =
            match List.assoc_opt "error_kind" decision_kvs with
            | Some (`String kind) -> Some (error_kind_of_wire kind)
            | _ -> None
          in
          Ok (Some { ts; keeper_turn_id; event; runtime_id; error_kind }))
     | Some _ -> Error "manifest row: event is not a string"
     | None -> Error "manifest row: missing event")
  | _ -> Error "manifest row is not an object"

let parse_manifest_rows (response : Yojson.Safe.t) : (attempt list, string) result =
  match response with
  | `Assoc kvs ->
    (match List.assoc_opt "manifest_rows" kvs with
     | Some (`List rows) ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | row :: rest ->
           let* parsed = parse_row row in
           (match parsed with
            | Some attempt -> collect (attempt :: acc) rest
            | None -> collect acc rest)
       in
       collect [] rows
     | Some _ -> Error "manifest_rows is not a list"
     | None -> Error "response missing manifest_rows")
  | _ -> Error "runtime-trace response is not a JSON object"

let classify ~(window_start : string) ~(attempts : attempt list) :
  mode * attempt list
  =
  let windowed =
    List.filter (fun (a : attempt) -> String.compare a.ts window_start >= 0) attempts
  in
  (* Group routed runtimes by keeper turn: two distinct runtimes routed
     under one turn id is the in-turn walk. *)
  let routed_by_turn = Hashtbl.create 8 in
  List.iter
    (fun (a : attempt) ->
      match a.event, a.keeper_turn_id with
      | Routed, Some turn ->
        (* DET-OK: absent table entry = first routed row seen for this
           turn (empty accumulator), not an unknown-input default. *)
        let known = Option.value (Hashtbl.find_opt routed_by_turn turn) ~default:[] in
        if not (List.mem a.runtime_id known)
        then Hashtbl.replace routed_by_turn turn (a.runtime_id :: known)
      | Routed, None | (Failed | Completed), (Some _ | None) -> ())
    windowed;
  let in_turn =
    Hashtbl.fold (fun _ runtimes acc -> acc || List.length runtimes >= 2) routed_by_turn false
  in
  if in_turn
  then (In_turn, windowed)
  else (
    (* Deferred: some turn failed on runtime A and a later row completed
       on a different runtime. Chronological order = list order is not
       guaranteed by the wire, so compare timestamps directly. *)
    let deferred =
      List.exists
        (fun (failed : attempt) ->
          failed.event = Failed
          && List.exists
               (fun (completed : attempt) ->
                 completed.event = Completed
                 && (not (String.equal completed.runtime_id failed.runtime_id))
                 && String.compare completed.ts failed.ts >= 0)
               windowed)
        windowed
    in
    if deferred then (Deferred, windowed) else (Not_observed, windowed))

let mode_to_string = function
  | In_turn -> "in_turn"
  | Deferred -> "deferred"
  | Not_observed -> "not_observed"

let attempt_to_yojson (a : attempt) : Yojson.Safe.t =
  `Assoc
    [ ("ts", `String a.ts)
    ; ( "keeper_turn_id"
      , match a.keeper_turn_id with Some n -> `Int n | None -> `Null )
    ; ("event", `String (attempt_event_to_string a.event))
    ; ("runtime_id", `String a.runtime_id)
    ; ( "error_kind"
      , match a.error_kind with
        | Some k -> `String (error_kind_render k)
        | None -> `Null )
    ]
