module Request = Keeper_librarian_durable_request
module Capture = Keeper_librarian_durable_capture
module Commit = Keeper_librarian_durable_commit
module Lock = Keeper_librarian_durable_source_lock
module Descent = Keeper_librarian_floor_descent
module Machine = Keeper_librarian_message_floor.Machine
module Current = Keeper_memory_os_current
module Cursor = Keeper_external_read_cursor
module Program = Keeper_memory_os_program
let ( let* ) = Result.bind
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail

type outcome = Published | Superseded

(* The receipt names the range together with the messages the chain could not
   read, so the unread messages of the program are part of it. *)
let program_source ~candidate ~messages (program : Program.t) =
  match Descent.turn candidate, messages with
  | Descent.Atoms range, Some checkpoint ->
    Ok (Current.Atom_program_source {range = {range with unread_messages = program.unread}; checkpoint})
  | Descent.Official (line, range), (None | Some _) ->
    Ok (Current.Official_program_source {range = {range with unread_messages = program.unread};
      selected_turns = [line.line, line.turn_ref, (Capture.input (Request.source (Descent.request candidate))).messages]})
  | Descent.Atoms _, None -> Error "Original checkpoint lock observation is missing"

(* The consumer prepared the cursor on this pass for the admissions it saw now.
   The chain read the admissions its original saw, so the cursor goes back to
   those, now naming the range as the receipt will. *)
let prepare_cursor ~candidate ~(program_source : Current.program_source) =
  let request = Descent.request candidate in
  let source = Request.source request and owner = Request.physical_owner request in
  let memory_keepers_dir = Request.keepers_dir owner and keeper_name = Request.keeper_id owner in
  let runtime_keepers_dir = Capture.runtime_keepers_dir source in
  let* token = Cursor.read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name in
  let* () = require (Cursor.offset token = Cursor.observation_offset (Capture.external_before source))
    "External admission cursor moved since the original read it" in
  let atom, official = match program_source with
    | Current.Atom_program_source {range; _} -> Some range, None
    | Current.Official_program_source {range; _} -> None, Some range in
  Cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name token
    ~through:(Keeper_librarian_input_sources.external_through (Capture.counterparts source)) ~atom ~official

let publish ~candidate ~(finished : Machine.finished) =
  let request = Descent.request candidate in
  let owner = Request.physical_owner request in
  let keepers_dir = Request.keepers_dir owner and keeper_id = Request.keeper_id owner in
  let program = finished.program in
  let* proved = io (fun () -> Commit.receipt_state request) in
  if proved then Ok Published else
  let* outcome = io (fun () ->
    Lock.with_original_snapshot ~request (fun ~messages ->
      let* anchor = Current.capture_program_anchor ~keepers_dir ~keeper_id in
      let facts = Option.map (fun (snapshot : Current.t) -> snapshot.facts)
        (Current.program_anchor_snapshot anchor) in
      if facts <> program.initial_current then Ok Superseded else
      let* program_source = program_source ~candidate ~messages program in
      let* () = prepare_cursor ~candidate ~program_source in
      let* _ = Current.apply_program ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~anchor
        ~source:program_source ~validate_source:(fun () -> Ok ()) program in
      Ok Published)) in
  match outcome with
  | Superseded -> Ok Superseded
  | Published ->
    (* The store's receipts decide, never the status it returned. *)
    let* proved = io (fun () -> Commit.receipt_state request) in
    let* () = require proved "Memory returned without the receipt of the range" in
    Ok Published
