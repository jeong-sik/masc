module Request = Keeper_librarian_durable_request
module Capture = Keeper_librarian_durable_capture
module Commit = Keeper_librarian_durable_commit
module Lock = Keeper_librarian_durable_source_lock
module Chain = Keeper_librarian_floor_chain
module Step = Keeper_librarian_floor_step_request
module Unread = Keeper_librarian_unread
module Current = Keeper_memory_os_current
module Range = Keeper_librarian_range
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f

type turn = Atoms of Current.durable_range_id | Official of Range.official_line * Current.official_range_id
type t = {record : Owner.retained; request : Request.t; turn : turn}
let request t = t.request
let record t = t.record
let turn t = t.turn
let range t : Step.link = {request_id = t.record.request_id; request_digest = t.record.request_digest}

(* The consumer's narrowed round reads the oldest turn only, of whichever kind
   ends first, so an original read that way holds one atom range or one
   official turn. A broader read, or a mix of the two, is not one turn. *)
let one_turn request =
  let source = Request.source request in
  match Capture.extent source, Capture.source source, Capture.range_id source with
  | Range.To_first_cut_point, Capture.Held.Checkpoint_only _, Some range -> Some (Atoms range)
  | Range.To_first_cut_point, Capture.Held.Official_only {Capture.Held.selected = [line]; traces = _}, _ ->
    Option.map (fun range -> Official (line, range)) (Capture.official_range_id source)
  | Range.To_first_cut_point, Capture.Held.Checkpoint_only _, None
  | Range.To_first_cut_point, (Capture.Held.Official_only _ | Capture.Held.Mixed _), (None | Some _)
  | Range.All_unread, (Capture.Held.Checkpoint_only _ | Capture.Held.Official_only _ | Capture.Held.Mixed _),
    (None | Some _) -> None

let refused_final request (record : Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Rejected {stage = Progress.Execution; evidence} ->
    let* exact = Request.request request in
    let* schema = Option.to_result ~none:"Original history refusal lacks its schema" exact.Exact.schema in
    let* retained = Exact.retained_final_of_json ~schema evidence in
    Ok (Some (Exact.delivered retained))
  | Progress.Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage = Progress.Before_dispatch; _} | Subdividing _ | Subdivided _ ->
    Ok None

let shows_smaller_input_may_help ~store request final =
  let* evidence = io (fun () -> Request.refusal_evidence ~store request final) in
  Ok (Memory_runtime.may_descend_messages
    [Memory_runtime.not_committed_of_failure ~detail:"Original history request refused" evidence])

let candidate ~store ~record ~request =
  match one_turn request, (Capture.input (Request.source request)).messages with
  | None, _ | Some _, [] -> Ok None
  | Some turn, _ :: _ ->
    let* () = io (fun () -> Request.confirm_record request record) in
    let* final = refused_final request record in
    (match final with
     | None -> Ok None
     | Some final ->
       let* descends = shows_smaller_input_may_help ~store request final in
       if not descends then Ok None else
       let* published = io (fun () -> Commit.receipt_state request) in
       let* unchanged = io (fun () -> Lock.positions_unchanged request) in
       Ok (if published || not unchanged then None else Some {record; request; turn}))

type source = {
  sources : Unread.source list;
  unread_message : Unread.source -> reasons:Keeper_librarian_input_refusal.t list -> (Unread.t, string) result;
}

let atom_source (range : Current.durable_range_id) ~messages =
  let* sources = Unread.sources_for_atom_range ~trace_id:range.trace_id
    ~history_start_boundary_line:range.history_start_boundary_line ~start_atom:range.start_atom
    ~end_atom:range.end_atom ~messages in
  let unread_message source ~reasons = match source with
    | Unread.Atom {trace_id; history_start_boundary_line; atom; message_in_atom; _}
      when trace_id = range.trace_id && history_start_boundary_line = range.history_start_boundary_line
           && range.start_atom <= atom && atom < range.end_atom ->
      Unread.for_atom ~trace_id ~history_start_boundary_line ~atom ~message_in_atom ~messages ~reasons
    | Unread.Atom _ | Unread.Official_turn _ -> Error "message is outside the selected checkpoint range" in
  Ok {sources; unread_message}

let official_source (line : Range.official_line) ~(messages : Agent_core.Types.message list) =
  let sources = List.mapi (fun message_in_turn message ->
    Unread.Official_turn {turn_ref = line.turn_ref; boundary_line = line.line; message_in_turn;
      message_sha256 = Unread.message_digest message}) messages in
  let unread_message source ~reasons = match source with
    | Unread.Official_turn {turn_ref; boundary_line; message_in_turn; _}
      when Ids.Turn_ref.equal turn_ref line.turn_ref && boundary_line = line.line ->
      Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons
    | Unread.Atom _ | Unread.Official_turn _ -> Error "message is outside the selected official turn" in
  {sources; unread_message}

(* The messages come from the original; an atom range is numbered against the
   whole checkpoint, which the original keeps only as a count and a digest, so
   it is read under the source lock that also confirms it is the one the
   original read. *)
let read_source t =
  io (fun () ->
    Lock.with_original_snapshot ~request:t.request (fun ~messages ->
      match t.turn, messages with
      | Atoms range, Some messages -> atom_source range ~messages
      | Official (line, _), (None | Some _) ->
        Ok (official_source line ~messages:(Capture.input (Request.source t.request)).messages)
      | Atoms _, None -> Error "Original checkpoint lock observation is missing"))

let fresh t : (Chain.fresh, string) result =
  let owner = Request.physical_owner t.request in
  let keepers_dir = Request.keepers_dir owner and keeper_id = Request.keeper_id owner in
  let* anchor = io (fun () -> Current.capture_program_anchor ~keepers_dir ~keeper_id) in
  let current = Option.map (fun (snapshot : Current.t) ->
    ({Keeper_librarian.facts = snapshot.facts} : Keeper_librarian.current_selection))
    (Current.program_anchor_snapshot anchor) in
  let* unread_messages = io (fun () -> Current.read_unread_messages ~keepers_dir ~keeper_id) in
  Ok {Chain.transaction_id = Keeper_librarian_message_floor.fresh_transaction_id (); current;
      previous_state = None; unread_messages}

let descend ~store ~config ~reserved t =
  let* source = read_source t in
  Chain.run ~store ~config ~reserved ~owner:(Request.physical_owner t.request) ~range:(range t)
    ~input:(Capture.input (Request.source t.request)) ~sources:source.sources ~fresh:(fun () -> fresh t)
    ~unread_message:source.unread_message
