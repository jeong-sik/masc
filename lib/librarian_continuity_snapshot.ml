module R = Keeper_librarian_range
module B = Keeper_turn_boundaries
module Window = Runtime_model_input_tail_window

type origin = Witnessed_history | Captured_checkpoint_prefix

type t =
  { origin : origin
  ; covering_end_atom : int
  ; covering_last_atom_digest : string
  ; trace_id : string
  ; history_start_boundary_line : int
  ; end_boundary_line : int
  ; end_turn_ref : Ids.Turn_ref.t
  ; end_atom : int
  ; last_atom_digest : string
  ; prefix_sha256 : string
  ; working_state : string
  ; catch_up_end_atom : int option
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
  else if snapshot.covering_end_atom < snapshot.end_atom
       || (snapshot.origin = Witnessed_history && snapshot.covering_end_atom <> snapshot.end_atom)
  then Error (Invalid_snapshot "cut lies outside its completed boundary")
  else if snapshot.end_boundary_line < snapshot.history_start_boundary_line
  then Error (Invalid_snapshot "ending boundary precedes history start")
  else if not (String.equal snapshot.trace_id (Ids.Turn_ref.trace_id snapshot.end_turn_ref))
  then Error (Invalid_snapshot "ending turn belongs to another trace")
  else if not (valid_sha256 snapshot.covering_last_atom_digest && valid_sha256 snapshot.last_atom_digest && valid_sha256 snapshot.prefix_sha256)
  then Error (Invalid_snapshot "digests must be canonical SHA256")
  else if String.trim snapshot.working_state = ""
  then Error (Invalid_snapshot "blank working_state")
  else
    match snapshot.catch_up_end_atom with
    | Some target when target <= snapshot.end_atom ->
      Error (Invalid_snapshot "catch-up target is not past the snapshot's end")
    | Some _ | None -> Ok snapshot
;;

let to_json (snapshot : t) =
  `Assoc
    ([ "origin", `String (match snapshot.origin with Witnessed_history -> "witnessed_history" | Captured_checkpoint_prefix -> "captured_checkpoint_prefix")
    ; "covering_end_atom", `Int snapshot.covering_end_atom
    ; "covering_last_atom_digest", `String snapshot.covering_last_atom_digest
    ; "trace_id", `String snapshot.trace_id
    ; "history_start_boundary_line", `Int snapshot.history_start_boundary_line
    ; "end_boundary_line", `Int snapshot.end_boundary_line
    ; "end_turn_ref", Ids.Turn_ref.to_yojson snapshot.end_turn_ref
    ; "end_atom", `Int snapshot.end_atom
    ; "last_atom_digest", `String snapshot.last_atom_digest
    ; "prefix_sha256", `String snapshot.prefix_sha256
    ; "working_state", `String snapshot.working_state
    ]
    @ (match snapshot.catch_up_end_atom with
       | Some target -> [ "catch_up_end_atom", `Int target ]
       | None -> []))
;;

let of_json = function
  | `Assoc fields ->
    let keys = ["origin"; "covering_end_atom"; "covering_last_atom_digest"; "trace_id"; "history_start_boundary_line"; "end_boundary_line"; "end_turn_ref"; "end_atom";
      "last_atom_digest"; "prefix_sha256"; "working_state"] in
    (* [catch_up_end_atom] is written only while a rewrite is catching up. *)
    let catch_up_key = "catch_up_end_atom" in
    let present = List.map fst fields in
    let expected =
      if List.mem catch_up_key present then catch_up_key :: keys else keys in
    if List.sort String.compare present <> List.sort String.compare expected
    then Error (Invalid_snapshot "unexpected, duplicate or missing fields")
    else (
      let* catch_up_end_atom =
        match List.assoc_opt catch_up_key fields with
        | None -> Ok None
        | Some (`Int target) -> Ok (Some target)
        | Some _ -> Error (Invalid_snapshot "catch-up target is not an integer") in
      let* origin = match List.assoc "origin" fields with
        | `String "witnessed_history" -> Ok Witnessed_history
        | `String "captured_checkpoint_prefix" -> Ok Captured_checkpoint_prefix
        | _ -> Error (Invalid_snapshot "unknown source origin") in
      let* covering_end_atom, covering_last_atom_digest =
        match List.assoc "covering_end_atom" fields, List.assoc "covering_last_atom_digest" fields with
        | `Int ending, `String digest -> Ok (ending, digest)
        | _ -> Error (Invalid_snapshot "invalid covering boundary") in
      let* end_turn_ref = Ids.Turn_ref.of_yojson (List.assoc "end_turn_ref" fields)
        |> Result.map_error (fun detail -> Invalid_snapshot detail) in
      match List.assoc "end_boundary_line" fields, List.assoc "trace_id" fields, List.assoc "history_start_boundary_line" fields,
            List.assoc "end_atom" fields, List.assoc "last_atom_digest" fields,
            List.assoc "prefix_sha256" fields, List.assoc "working_state" fields with
      | `Int end_boundary_line, `String trace_id, `Int history_start_boundary_line, `Int end_atom,
        `String last_atom_digest, `String prefix_sha256, `String working_state ->
        validate { origin; covering_end_atom; covering_last_atom_digest; trace_id; history_start_boundary_line; end_boundary_line; end_turn_ref; end_atom;
                   last_atom_digest; prefix_sha256; working_state; catch_up_end_atom }
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


(* A baseline identifies a real completed checkpoint endpoint; it does not
   certify that Memory ever read it. This source explicitly reads its prefix. *)
let checkpoint_prefix_range ~trace_id ~lines ~messages =
  match R.select ~trace_id ~lines ~progress:None ~messages R.All_unread with
  | R.Baseline baseline ->
    let progress = { Keeper_librarian_progress.position = baseline.position;
      boundary_lines_seen = baseline.boundary_lines_seen } in
    (match R.select ~trace_id ~lines ~progress:(Some progress) ~messages R.All_unread with
     | R.Read {range; _} -> Ok {range with R.start_atom = 0}
     | R.Nothing_to_read ->
       let first = List.find_map (function
         | line, Ok {B.event = B.Turn_ended {turn_ref; _}; _}
           when String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id -> Some line
         | _ -> None) lines in
       (match first with
        | None -> Error Uncovered_history
        | Some history_start_boundary_line -> Ok
          {R.history_start_boundary_line; start_atom = 0;
           end_atom = baseline.position.end_atom;
           last_atom_digest = baseline.position.last_atom_digest})
     | R.Stop error -> Error (Range_stopped error)
     (* The progress given is this trace's own baseline, so select returns
        neither: it builds a baseline only without progress, and that
        position names this trace. Each answers what it would mean, as in
        source_range. *)
     | R.Position_in_other_trace _ -> Error Trace_mismatch
     | R.Baseline _ -> Error Uncovered_history)
  | R.Read _ | R.Nothing_to_read | R.Position_in_other_trace _ | R.Stop _ ->
    source_range ~trace_id ~lines ~messages
;;

let prefix_sha256 messages range =
  R.slice messages range
  |> List.map Agent_core.Checkpoint.message_to_json
  |> fun messages -> Digestif.SHA256.(digest_string (Yojson.Safe.to_string (`List messages)) |> to_hex)
;;

let capture_range ~origin ?end_atom ~catch_up_end_atom ~trace_id ~lines ~messages ~working_state range =
  let end_atom = Option.value end_atom ~default:range.R.end_atom in
  let catch_up_end_atom =
    match catch_up_end_atom with
    | Some target when target > end_atom -> Some target
    | Some _ | None -> None in
  let* last_atom_digest =
    if end_atom < 1 || end_atom > range.end_atom then Error Uncovered_history
    else match Window.atom_opening_digest messages (end_atom - 1) with
      | None -> Error Uncovered_history | Some digest -> Ok digest in
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
    { origin
    ; covering_end_atom = range.end_atom
    ; covering_last_atom_digest = range.last_atom_digest
    ; trace_id
    ; history_start_boundary_line = range.history_start_boundary_line
    ; end_boundary_line
    ; end_turn_ref
    ; end_atom
    ; last_atom_digest
    ; prefix_sha256 = prefix_sha256 messages {range with R.end_atom; last_atom_digest}
    ; working_state
    ; catch_up_end_atom
    }
;;

let capture ~trace_id ~lines ~messages ~working_state =
  let* range = source_range ~trace_id ~lines ~messages in
  capture_range ~origin:Witnessed_history ~catch_up_end_atom:None ~trace_id ~lines ~messages ~working_state range
;;

let capture_checkpoint_prefix ?end_atom ~catch_up_end_atom ~trace_id ~lines ~messages ~working_state () =
  let* range = checkpoint_prefix_range ~trace_id ~lines ~messages in
  capture_range ~origin:Captured_checkpoint_prefix ?end_atom ~catch_up_end_atom ~trace_id ~lines ~messages ~working_state range
;;

let restore ~trace_id ~lines ~messages (snapshot : t) =
  if not (String.equal trace_id snapshot.trace_id) then Error Trace_mismatch
  else
    let source = match snapshot.origin with Witnessed_history -> source_range | Captured_checkpoint_prefix -> checkpoint_prefix_range in
    let* range = source ~trace_id ~lines ~messages in
    let boundary_present = List.exists (function
      | line, Ok { B.event = B.Turn_ended
          { turn_ref; position = B.Atom_history { end_atom; last_atom_digest }; _ }; _ } ->
        line = snapshot.end_boundary_line
        && Ids.Turn_ref.equal turn_ref snapshot.end_turn_ref
        && end_atom = snapshot.covering_end_atom
        && String.equal last_atom_digest snapshot.covering_last_atom_digest
      | _ -> false) lines
    in
    if range.history_start_boundary_line <> snapshot.history_start_boundary_line
       || range.end_atom < snapshot.covering_end_atom || not boundary_present
       || Window.atom_opening_digest messages (snapshot.covering_end_atom - 1)
          <> Some snapshot.covering_last_atom_digest
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
