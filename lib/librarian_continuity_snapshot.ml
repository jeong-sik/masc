module R = Keeper_librarian_range
module B = Keeper_turn_boundaries
module Window = Runtime_model_input_tail_window

type t =
  { trace_id : string
  ; history_start_boundary_line : int
  ; end_boundary_line : int
  ; end_turn_ref : Ids.Turn_ref.t
  ; end_atom : int
  ; last_atom_digest : string
  ; prefix_sha256 : string
  ; working_state : string
  }

type error =
  | Invalid_snapshot of string
  | Uncovered_history
  | Range_stopped of R.stop
  | Trace_mismatch
  | History_changed
  | Prefix_changed
  | Read_failed of string
  | Write_failed of string

type restored =
  { working_state : string
  ; messages : Agent_core.Types.message list
  }

let error_to_string = function
  | Invalid_snapshot detail -> "invalid continuity snapshot: " ^ detail
  | Uncovered_history -> "no completed history range from a witnessed restart"
  | Range_stopped (R.Unreadable_line { line; _ }) ->
    Printf.sprintf "continuity source boundary is unreadable at line %d" line
  | Range_stopped (R.Position_mismatch _) -> "continuity source position does not match history"
  | Trace_mismatch -> "continuity snapshot belongs to another trace"
  | History_changed -> "continuity snapshot belongs to another history generation or boundary"
  | Prefix_changed -> "continuity snapshot covered messages changed"
  | Read_failed detail -> "continuity snapshot read failed: " ^ detail
  | Write_failed detail -> "continuity snapshot write failed: " ^ detail
;;

let ( let* ) = Result.bind

let valid_sha256 text =
  String.length text = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) text
;;

let validate (snapshot : t) =
  if String.trim snapshot.trace_id = "" then Error (Invalid_snapshot "blank trace_id")
  else if snapshot.history_start_boundary_line < 1 || snapshot.end_atom < 1
  then Error (Invalid_snapshot "history positions must be positive")
  else if snapshot.end_boundary_line < snapshot.history_start_boundary_line
  then Error (Invalid_snapshot "ending boundary precedes history start")
  else if not (String.equal snapshot.trace_id (Ids.Turn_ref.trace_id snapshot.end_turn_ref))
  then Error (Invalid_snapshot "ending turn belongs to another trace")
  else if not (valid_sha256 snapshot.last_atom_digest && valid_sha256 snapshot.prefix_sha256)
  then Error (Invalid_snapshot "digests must be canonical SHA256")
  else if String.trim snapshot.working_state = ""
  then Error (Invalid_snapshot "blank working_state")
  else Ok snapshot
;;

let to_json (snapshot : t) =
  `Assoc
    [ "trace_id", `String snapshot.trace_id
    ; "history_start_boundary_line", `Int snapshot.history_start_boundary_line
    ; "end_boundary_line", `Int snapshot.end_boundary_line
    ; "end_turn_ref", Ids.Turn_ref.to_yojson snapshot.end_turn_ref
    ; "end_atom", `Int snapshot.end_atom
    ; "last_atom_digest", `String snapshot.last_atom_digest
    ; "prefix_sha256", `String snapshot.prefix_sha256
    ; "working_state", `String snapshot.working_state
    ]
;;

let of_json = function
  | `Assoc fields ->
    let keys = ["trace_id"; "history_start_boundary_line"; "end_boundary_line"; "end_turn_ref"; "end_atom";
      "last_atom_digest"; "prefix_sha256"; "working_state"] in
    if List.sort String.compare (List.map fst fields) <> List.sort String.compare keys
    then Error (Invalid_snapshot "unexpected, duplicate or missing fields")
    else (
      let* end_turn_ref = Ids.Turn_ref.of_yojson (List.assoc "end_turn_ref" fields)
        |> Result.map_error (fun detail -> Invalid_snapshot detail) in
      match List.assoc "end_boundary_line" fields, List.assoc "trace_id" fields, List.assoc "history_start_boundary_line" fields,
            List.assoc "end_atom" fields, List.assoc "last_atom_digest" fields,
            List.assoc "prefix_sha256" fields, List.assoc "working_state" fields with
      | `Int end_boundary_line, `String trace_id, `Int history_start_boundary_line, `Int end_atom,
        `String last_atom_digest, `String prefix_sha256, `String working_state ->
        validate { trace_id; history_start_boundary_line; end_boundary_line; end_turn_ref; end_atom;
                   last_atom_digest; prefix_sha256; working_state }
      | _ -> Error (Invalid_snapshot "field type mismatch"))
  | _ -> Error (Invalid_snapshot "expected object")
;;

let source_range ~trace_id ~lines ~messages =
  match R.select ~trace_id ~lines ~progress:None ~messages R.All_unread with
  | R.Read { range; _ } when range.start_atom = 0 -> Ok range
  | R.Stop error -> Error (Range_stopped error)
  | R.Position_in_other_trace _ -> Error Trace_mismatch
  | R.Read _ | R.Baseline _ | R.Nothing_to_read -> Error Uncovered_history
;;

let prefix_sha256 messages range =
  R.slice messages range
  |> List.map Agent_core.Checkpoint.message_to_json
  |> fun messages -> Digestif.SHA256.(digest_string (Yojson.Safe.to_string (`List messages)) |> to_hex)
;;

let capture ~trace_id ~lines ~messages ~working_state =
  let* range = source_range ~trace_id ~lines ~messages in
  let* end_boundary_line, end_turn_ref =
    match List.find_map (function
      | line, Ok { B.event = B.Turn_ended
          { turn_ref; position = B.Atom_history { end_atom; last_atom_digest }; _ }; _ }
        when line >= range.history_start_boundary_line
          && String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
          && end_atom = range.end_atom
          && String.equal last_atom_digest range.last_atom_digest -> Some (line, turn_ref)
      | _ -> None) lines with
    | Some ending -> Ok ending
    | None -> Error Uncovered_history
  in
  validate
    { trace_id
    ; history_start_boundary_line = range.history_start_boundary_line
    ; end_boundary_line
    ; end_turn_ref
    ; end_atom = range.end_atom
    ; last_atom_digest = range.last_atom_digest
    ; prefix_sha256 = prefix_sha256 messages range
    ; working_state
    }
;;

let restore ~trace_id ~lines ~messages (snapshot : t) =
  if not (String.equal trace_id snapshot.trace_id) then Error Trace_mismatch
  else
    let* range = source_range ~trace_id ~lines ~messages in
    let boundary_present = List.exists (function
      | line, Ok { B.event = B.Turn_ended
          { turn_ref; position = B.Atom_history { end_atom; last_atom_digest }; _ }; _ } ->
        line = snapshot.end_boundary_line
        && Ids.Turn_ref.equal turn_ref snapshot.end_turn_ref
        && end_atom = snapshot.end_atom
        && String.equal last_atom_digest snapshot.last_atom_digest
      | _ -> false) lines
    in
    if range.history_start_boundary_line <> snapshot.history_start_boundary_line
       || range.end_atom < snapshot.end_atom || not boundary_present
       || Window.atom_opening_digest messages (snapshot.end_atom - 1)
          <> Some snapshot.last_atom_digest
    then Error History_changed
    else
      let covered = { range with R.end_atom = snapshot.end_atom;
        last_atom_digest = snapshot.last_atom_digest } in
      if not (String.equal (prefix_sha256 messages covered) snapshot.prefix_sha256)
      then Error Prefix_changed
      else
        let labelled, _ = Window.annotate messages in
        let messages = List.filter_map (fun (message, label) ->
          match label with
          | Window.Pinned -> Some message
          | Window.Atom atom -> if atom >= snapshot.end_atom then Some message else None) labelled in
        Ok { working_state = snapshot.working_state; messages }
;;

let save ~path snapshot =
  Keeper_fs.save_bytes_durable_atomic path (Yojson.Safe.to_string (to_json snapshot))
  |> Result.map_error (fun error -> Write_failed (Keeper_fs.durable_write_error_to_string error))
;;

let load ~path =
  try
    In_channel.with_open_bin path In_channel.input_all
    |> Yojson.Safe.from_string |> of_json
  with
  | Sys_error detail -> Error (Read_failed detail)
  | Yojson.Json_error detail -> Error (Invalid_snapshot detail)
;;
