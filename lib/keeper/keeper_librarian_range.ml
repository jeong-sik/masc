(* Which atoms a Librarian round reads (RFC librarian-lifecycle §4.4). See the
   interface for the contract. *)

module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module Window = Runtime_model_input_tail_window
module O = Keeper_librarian_official_progress

type range =
  { history_start_boundary_line : int
  ; start_atom : int
  ; end_atom : int
  ; last_atom_digest : string
  }

type extent =
  | All_unread
  | To_first_cut_point

type stop =
  | Unreadable_line of
      { line : int
      ; error : B.read_error
      }
  | Position_mismatch of
      { position : P.position
      ; atom_count : int
      }

type selection =
  | Read of
      { range : range
      ; boundary_lines_seen : int
      }
  | Baseline of
      { position : P.position
      ; boundary_lines_seen : int
      }
  | Nothing_to_read
  | Position_in_other_trace of P.position
  | Stop of stop

(* Row 2c. The fragment a torn append leaves has no newline and is not a line:
   it is neither counted nor a reason to stop. *)
let unreadable_lines lines =
  List.filter_map
    (fun (line, read) ->
       match read with
       | Error ((B.Not_json _ | B.Malformed _) as error) -> Some (line, error)
       | Error B.Incomplete_line | Ok _ -> None)
    lines
;;

let complete_line_count lines =
  List.fold_left
    (fun count (_, read) ->
       match read with
       | Error B.Incomplete_line -> count
       | Ok _ | Error (B.Not_json _ | B.Malformed _) -> count + 1)
    0
    lines
;;

let lines_of_trace ~trace_id lines =
  List.filter_map
    (fun (line, read) ->
       match read with
       | Error (B.Not_json _ | B.Malformed _ | B.Incomplete_line) -> None
       | Ok (written : B.record) ->
         let own =
           match written.event with
           | B.Turn_ended { turn_ref; history_at_start = _; position = _ } ->
             String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
           | B.History_restarted { trace_id = restarted } ->
             String.equal restarted trace_id
         in
         if own then Some (line, written) else None)
    lines
;;

(* Row 3d. *)
let is_restart (written : B.record) =
  match written.event with
  | B.History_restarted { trace_id = _ } -> true
  | B.Turn_ended { turn_ref = _; history_at_start = B.Fresh_history; position = _ } -> true
  | B.Turn_ended { turn_ref = _; history_at_start = B.Continued_history; position = _ } ->
    false
;;

(* A seen restart still excludes older endpoints. Share this source-order
   segment between the checkpoint preflight and the full selector. *)
let current_history_lines own =
  List.fold_left
    (fun current ((_, written) as row) ->
       if is_restart written then [ row ] else row :: current)
    []
    own
  |> List.rev
;;

let has_completed_atom_boundary ~trace_id ~lines =
  current_history_lines (lines_of_trace ~trace_id lines)
  |> List.exists (fun (_, (written : B.record)) ->
    match written.event with
    | B.Turn_ended { position = B.Atom_history _; _ } -> true
    | B.Turn_ended
        { position = B.Empty_atom_history | B.No_atom_history | B.Stale_noop; _ }
    | B.History_restarted _ -> false)
;;

let may_have_unread ~trace_id ~lines ~progress =
  let own = current_history_lines (lines_of_trace ~trace_id lines) in
  (* Unknown complete rows may contain an atom boundary or restart. Leave
     their rejection to the selector; official-only rows are not atom work. *)
  unreadable_lines lines <> []
  || match progress with
  | None ->
    List.exists
      (fun (_, (written : B.record)) ->
         is_restart written
         || match written.event with
            | B.Turn_ended { position = B.Atom_history _; _ } -> true
            | B.Turn_ended _ | B.History_restarted _ -> false)
      own
  | Some ({ P.position; boundary_lines_seen } : P.t) ->
    not (String.equal trace_id position.trace_id)
    || complete_line_count lines < boundary_lines_seen
    || List.exists
         (fun (line, (written : B.record)) ->
            (line > boundary_lines_seen && is_restart written)
            || match written.event with
               | B.Turn_ended { position = B.Atom_history { end_atom; _ }; _ } ->
                 line > boundary_lines_seen || end_atom > position.end_atom
               | B.Turn_ended _ | B.History_restarted _ -> false)
         own
;;

let matches_checkpoint ~digest_at ~atom_count ~end_atom ~digest =
  end_atom <= atom_count
  &&
  match digest_at (end_atom - 1) with
  | Some opening -> String.equal opening digest
  | None -> false
;;

(* Row 2a: an endpoint must match the loaded checkpoint. Repeated messages
   can also match an earlier history, so [select] first discards cut points
   before the latest restart of this trace. A mismatching line is not an error. *)
let cut_point ~digest_at ~atom_count (written : B.record) =
  match written.event with
  | B.Turn_ended
      { turn_ref = _
      ; history_at_start = _
      ; position = B.Atom_history { end_atom; last_atom_digest }
      } ->
    if matches_checkpoint ~digest_at ~atom_count ~end_atom ~digest:last_atom_digest
    then Some (end_atom, last_atom_digest)
    else None
  | B.Turn_ended
      { turn_ref = _
      ; history_at_start = _
      ; position = B.Empty_atom_history | B.No_atom_history | B.Stale_noop
      }
  | B.History_restarted { trace_id = _ } -> None
;;

type start =
  | From of int
  | No_position
  | Mismatch of P.position

(* Row 2c. A refused line stops the round because it may be a restart line.
   Once a restart line of this trace follows it, it cannot be one that still
   matters: a restart puts the start at atom zero, and no content makes a start
   smaller than that, while any cut point it carried belongs to a history that
   has since been renumbered. The restart must be of this trace, because what
   trace the refused line belonged to is exactly what cannot be read. *)
let dead_line ~own line =
  List.exists (fun (later, written) -> later > line && is_restart written) own
;;

(* The question is not whether the first refused line still matters but whether
   any of them does, and the answer differs per line: a restart settles only
   the refused lines before it. Asking it of the first one alone lets a later
   one through unread, which is the one direction row 2c must not fail in. *)
let first_blocking ~own lines =
  List.find_opt (fun (line, _) -> not (dead_line ~own line)) (unreadable_lines lines)
;;

let select ~trace_id ~lines ~progress ~messages extent =
  let own = lines_of_trace ~trace_id lines in
  match first_blocking ~own lines with
  | Some (line, error) -> Stop (Unreadable_line { line; error })
  | None ->
    let other_trace =
      match progress with
      | Some { P.position; boundary_lines_seen = _ } ->
        if String.equal position.P.trace_id trace_id then None else Some position
      | None -> None
    in
    (match other_trace with
     | Some position -> Position_in_other_trace position
     | None ->
       let boundary_lines_seen = complete_line_count lines in
       let _labelled, atom_count = Window.annotate messages in
       let digest_at = Window.atom_opening_digest messages in
       let current_history = current_history_lines own in
       let history_start_boundary_line =
         match current_history with
         | (line, _) :: _ -> Some line
         | [] -> None
       in
       let cuts =
         current_history
         |> List.filter_map (fun (_, written) -> cut_point ~digest_at ~atom_count written)
       in
       (* Row 3c: a restart line beyond the count the progress file holds was
          appended after the position last moved. It wins over a position that
          seems to match: a digest carries no index and no time. *)
       let seen_before =
         match progress with
         | Some { P.position = _; boundary_lines_seen } -> boundary_lines_seen
         | None -> 0
       in
       let restarted =
         List.exists (fun (line, written) -> line > seen_before && is_restart written) own
       in
       let start =
         if restarted
         then From 0
         else (
           match progress with
           | None -> No_position
           | Some { P.position; boundary_lines_seen = _ } ->
             if matches_checkpoint
                  ~digest_at
                  ~atom_count
                  ~end_atom:position.P.end_atom
                  ~digest:position.P.last_atom_digest
             then From position.P.end_atom
             else Mismatch position)
       in
       (match start with
        | Mismatch position -> Stop (Position_mismatch { position; atom_count })
        | No_position ->
          (match List.sort (fun (a, _) (b, _) -> Int.compare a b) cuts with
           | [] -> Nothing_to_read
           | (end_atom, last_atom_digest) :: _ ->
             Baseline
               { position = { P.trace_id; end_atom; last_atom_digest }; boundary_lines_seen })
        | From start_atom ->
          let beyond =
            List.filter (fun (end_atom, _) -> end_atom > start_atom) cuts
            |> List.sort (fun (a, _) (b, _) -> Int.compare a b)
          in
          let chosen =
            match extent, beyond with
            | (All_unread | To_first_cut_point), [] -> None
            | To_first_cut_point, first :: _ -> Some first
            | All_unread, first :: rest -> Some (List.fold_left (fun _ next -> next) first rest)
          in
          (match chosen with
           | None -> Nothing_to_read
           | Some (end_atom, last_atom_digest) ->
             (match history_start_boundary_line with
              | None -> Nothing_to_read
              | Some history_start_boundary_line ->
                Read
                  { range =
                      { history_start_boundary_line
                      ; start_atom
                      ; end_atom
                      ; last_atom_digest
                      }
                  ; boundary_lines_seen
                  }))))
;;

(* RFC §4.9. The count the operator sees, over the same lines [select] reads.
   It is not [select]: a round stopped by a refused line still has turns
   behind it, and the number is what says how far behind. *)
let unread_turns ~trace_id ~lines ~progress ~messages =
  let own = lines_of_trace ~trace_id lines in
  let _labelled, atom_count = Window.annotate messages in
  let digest_at = Window.atom_opening_digest messages in
  let cuts =
    current_history_lines own
    |> List.filter_map (fun (_, written) -> cut_point ~digest_at ~atom_count written)
  in
  let seen_before =
    match progress with
    | Some { P.position = _; boundary_lines_seen } -> boundary_lines_seen
    | None -> 0
  in
  let restarted =
    List.exists (fun (line, written) -> line > seen_before && is_restart written) own
  in
  if restarted
  then Some (List.length cuts)
  else (
    match progress with
    | None ->
      (* No position: the smallest cut becomes the baseline and nothing
         before it is read (row 3, third case), so it is not unread. *)
      Some (max 0 (List.length cuts - 1))
    | Some { P.position; boundary_lines_seen = _ } ->
      if String.equal position.P.trace_id trace_id
         && matches_checkpoint
              ~digest_at
              ~atom_count
              ~end_atom:position.P.end_atom
              ~digest:position.P.last_atom_digest
      then
        Some
          (List.length
             (List.filter (fun (end_atom, _) -> end_atom > position.P.end_atom) cuts))
      else None)
;;

let progress_after ~trace_id = function
  | Read { range; boundary_lines_seen } ->
    Some
      { P.position =
          { P.trace_id
          ; end_atom = range.end_atom
          ; last_atom_digest = range.last_atom_digest
          }
      ; boundary_lines_seen
      }
  | Baseline { position; boundary_lines_seen } -> Some { P.position; boundary_lines_seen }
  | Nothing_to_read | Position_in_other_trace _ | Stop _ -> None
;;

let slice messages (range : range) =
  let labelled, _atom_count = Window.annotate messages in
  List.filter_map
    (fun (message, label) ->
       match label with
       | Window.Atom atom ->
         if atom >= range.start_atom && atom < range.end_atom then Some message else None
       | Window.Pinned -> None)
    labelled
;;

type official_line =
  { line : int
  ; turn_ref : Ids.Turn_ref.t
  ; recorded_at : float
  }

type official_selection =
  | Official_read of official_line list
  | Nothing_official
  | Official_stop of
      { line : int
      ; error : B.read_error
      }

let cursor_line = function
  | None -> 0
  | Some { O.boundary_line } -> boundary_line
;;

let official_candidate (line, read) =
  match read with
  | Ok
      ({ recorded_at
       ; event =
           B.Turn_ended { turn_ref; history_at_start = _; position = B.No_atom_history }
       } : B.record) -> Some { line; turn_ref; recorded_at }
  | Ok
      { B.event =
          B.Turn_ended
            { position = B.Atom_history _ | B.Empty_atom_history | B.Stale_noop; _ }
      ; _
      }
  | Ok { B.event = B.History_restarted _; _ }
  | Error _ -> None
;;

let select_official ~lines ~cursor extent =
  let after = cursor_line cursor in
  let beyond = List.filter (fun (line, _) -> line > after) lines in
  match List.find_opt (fun (_, read) -> match read with Error (B.Not_json _ | B.Malformed _) -> true | Error B.Incomplete_line | Ok _ -> false) beyond with
  | Some (line, Error error) -> Official_stop { line; error }
  | Some (_, Ok _) | None ->
    (match List.filter_map official_candidate beyond with
     | [] -> Nothing_official
     | first :: rest ->
       (match extent with
        | To_first_cut_point -> Official_read [ first ]
        | All_unread -> Official_read (first :: rest)))
;;

(* RFC §4.9: official-client turns beyond the cursor. A refused line does
   not hide the candidates around it; the round's stop says it is stopped. *)
let unread_official_turns ~lines ~cursor =
  let after = cursor_line cursor in
  List.filter (fun (line, _) -> line > after) lines
  |> List.filter_map official_candidate
  |> List.length
;;

let may_have_unread_official ~lines ~cursor =
  match select_official ~lines ~cursor All_unread with
  | Official_read _ | Official_stop _ -> true
  | Nothing_official -> false
;;

type atom_cut =
  { cut_line : int
  ; cut_end_atom : int
  ; cut_recorded_at : float
  ; cut_turn_ref : Ids.Turn_ref.t
  }

let cut_lines ~trace_id ~lines ~messages (range : range) =
  let _labelled, atom_count = Window.annotate messages in
  let digest_at = Window.atom_opening_digest messages in
  current_history_lines (lines_of_trace ~trace_id lines)
  |> List.filter_map (fun (line, (written : B.record)) ->
    match cut_point ~digest_at ~atom_count written, written.event with
    | Some (end_atom, _), B.Turn_ended { turn_ref; _ }
      when end_atom > range.start_atom && end_atom <= range.end_atom ->
      Some
        { cut_line = line
        ; cut_end_atom = end_atom
        ; cut_recorded_at = written.recorded_at
        ; cut_turn_ref = turn_ref
        }
    | Some _, (B.Turn_ended _ | B.History_restarted _) | None, _ -> None)
;;
