(* Which atoms a Librarian round reads (RFC librarian-lifecycle §4.4). See the
   interface for the contract. *)

module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module Window = Runtime_model_input_tail_window

type range =
  { start_atom : int
  ; end_atom : int
  ; last_atom_digest : string
  ; turns : int
  }

type extent =
  | All_unread
  | Oldest_turn_only

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
let first_unreadable lines =
  List.find_map
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

let matches_checkpoint ~digest_at ~atom_count ~end_atom ~digest =
  end_atom <= atom_count
  &&
  match digest_at (end_atom - 1) with
  | Some opening -> String.equal opening digest
  | None -> false
;;

(* Row 2a: a line of the current history. Lines of an earlier history of the
   trace, and lines for a history that was never stored, do not match and are
   left out without being an error. *)
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

let select ~trace_id ~lines ~progress ~messages extent =
  match first_unreadable lines with
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
       let own = lines_of_trace ~trace_id lines in
       let _labelled, atom_count = Window.annotate messages in
       let digest_at = Window.atom_opening_digest messages in
       let cuts = List.filter_map (fun (_, written) -> cut_point ~digest_at ~atom_count written) own in
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
            | (All_unread | Oldest_turn_only), [] -> None
            | Oldest_turn_only, first :: _ -> Some first
            | All_unread, first :: rest -> Some (List.fold_left (fun _ next -> next) first rest)
          in
          (match chosen with
           | None -> Nothing_to_read
           | Some (end_atom, last_atom_digest) ->
             let turns =
               List.length (List.filter (fun (cut, _) -> cut <= end_atom) beyond)
             in
             Read
               { range = { start_atom; end_atom; last_atom_digest; turns }
               ; boundary_lines_seen
               })))
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
