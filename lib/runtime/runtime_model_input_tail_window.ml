(** Bounded transmission view over provider-bound history — see the
    interface for the contract (RFC #26534 PR-C, #26544, #26535). *)

let atoms_per_window = 60
let preamble_marker_key = "masc.model_input_tail_window.v1"

let preamble_text =
  "[context window] Older turns of this conversation are omitted from this \
   request. The full history is preserved in the durable checkpoint and \
   surfaces through the memory system when relevant."

let preamble_message : Agent_sdk.Types.message =
  { role = Agent_sdk.Types.User
  ; content = [ Agent_sdk.Types.Text preamble_text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = [ (preamble_marker_key, `Bool true) ]
  }
;;

(* A message is pinned when it must survive every cut: [System] entries
   (defensive — the runtime carries the system prompt out of band) and any
   message with extra-system-context provenance. [Invalid]/[Duplicate]
   provenance still means the per-turn context assembler authored the
   message, so it is pinned rather than exposed to the cut on a malformed
   tag. *)
let is_extra_context (msg : Agent_sdk.Types.message) =
  match
    Agent_sdk.Types.Extra_system_context_provenance.classify msg.metadata
  with
  | Agent_sdk.Types.Extra_system_context_provenance.Absent -> false
  | Agent_sdk.Types.Extra_system_context_provenance.Present
  | Agent_sdk.Types.Extra_system_context_provenance.Invalid
  | Agent_sdk.Types.Extra_system_context_provenance.Duplicate -> true
;;

type label =
  | Pinned
  | Atom of int

(* Label every message with its atom index, in order. [User] and [Assistant]
   open a new atom; [Tool] joins the atom of the assistant that issued the
   call, so both sides of a tool exchange always share one label. A leading
   orphan [Tool] run (possible only on a history that was already cut
   upstream of OAS) becomes atom 0 so it is dropped with the first cut
   rather than transmitted headless. *)
let annotate (messages : Agent_sdk.Types.message list) :
  (Agent_sdk.Types.message * label) list * int
  =
  let labelled_rev, atom_count =
    List.fold_left
      (fun (acc, count) (msg : Agent_sdk.Types.message) ->
         if is_extra_context msg
         then ((msg, Pinned) :: acc, count)
         else (
           match msg.role with
           | Agent_sdk.Types.System -> ((msg, Pinned) :: acc, count)
           | Agent_sdk.Types.User | Agent_sdk.Types.Assistant ->
             ((msg, Atom count) :: acc, count + 1)
           | Agent_sdk.Types.Tool ->
             if count = 0
             then ((msg, Atom 0) :: acc, 1)
             else ((msg, Atom (count - 1)) :: acc, count)))
      ([], 0)
      messages
  in
  (List.rev labelled_rev, atom_count)
;;

(* Largest multiple of [atoms_per_window] that still leaves at least
   [atoms_per_window] atoms. Quantizing the drop count keeps the cut point
   stationary while up to [atoms_per_window] new atoms accumulate, so the
   transmitted prefix only changes when the window jumps. *)
let dropped_atoms ~atom_count =
  if atom_count < 2 * atoms_per_window
  then 0
  else (atom_count - atoms_per_window) / atoms_per_window * atoms_per_window
;;

let project (messages : Agent_sdk.Types.message list) :
  Agent_sdk.Types.message list
  =
  let labelled, atom_count = annotate messages in
  let drop = dropped_atoms ~atom_count in
  if drop = 0
  then messages
  else (
    let kept_labelled =
      List.filter
        (fun (_msg, label) ->
           match label with
           | Pinned -> true
           | Atom index -> index >= drop)
        labelled
    in
    let first_kept_atom_role =
      List.find_map
        (fun ((msg : Agent_sdk.Types.message), label) ->
           match label with
           | Atom _ -> Some msg.role
           | Pinned -> None)
        kept_labelled
    in
    let kept = List.map fst kept_labelled in
    match first_kept_atom_role with
    | Some Agent_sdk.Types.User | None -> kept
    | Some Agent_sdk.Types.Assistant
    | Some Agent_sdk.Types.Tool
    | Some Agent_sdk.Types.System -> preamble_message :: kept)
;;
