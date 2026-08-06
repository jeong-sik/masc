(** Bounded transmission view over provider-bound history — see the
    interface for the contract (RFC-0351 §3 L5, #26534 PR-C, #26535, #26551). *)

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

type budget_error =
  | Reservation_exceeds_capacity of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; undroppable_bytes : int
      }
  | Newest_atom_exceeds_available of
      { available_bytes : int
      ; newest_atom_bytes : int
      }

type projection =
  { messages : Agent_sdk.Types.message list
  ; dropped_atoms : int
  }

let budget_error_to_string = function
  | Reservation_exceeds_capacity
      { capacity_bytes; reserved_bytes; undroppable_bytes } ->
    Printf.sprintf
      "model input budget leaves no room for history: capacity_bytes=%d \
       reserved_bytes=%d undroppable_bytes=%d"
      capacity_bytes
      reserved_bytes
      undroppable_bytes
  | Newest_atom_exceeds_available { available_bytes; newest_atom_bytes } ->
    Printf.sprintf
      "newest conversation atom does not fit the model input budget: \
       available_bytes=%d newest_atom_bytes=%d"
      available_bytes
      newest_atom_bytes
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

(* [suffix.(i)] is the measured size of atoms [i .. atom_count - 1];
   [suffix.(atom_count)] is 0. Suffix sums make every candidate cut a single
   array read, so the quantized scan below stays linear in the atom count. *)
let atom_suffix_bytes ~measure_message_bytes ~atom_count labelled =
  let per_atom = Array.make (max atom_count 1) 0 in
  List.iter
    (fun (msg, label) ->
       match label with
       | Pinned -> ()
       | Atom index -> per_atom.(index) <- per_atom.(index) + measure_message_bytes msg)
    labelled;
  let suffix = Array.make (atom_count + 1) 0 in
  for index = atom_count - 1 downto 0 do
    suffix.(index) <- suffix.(index + 1) + per_atom.(index)
  done;
  (per_atom, suffix)
;;

(* Smallest multiple of [atoms_per_window] whose remaining suffix fits
   [available_bytes]. Quantizing keeps the transmitted prefix byte-identical
   while the conversation grows inside one window, which is what preserves
   provider prompt-cache reuse between jumps (#26535 measured the
   alternative: a per-turn sliding cut changes the prefix on every request).
   [None] means no quantized cut is small enough and the caller must fall
   back to an exact cut — correctness outranks cache reuse. *)
let quantized_drop ~available_bytes ~atom_count suffix =
  let rec scan drop =
    if drop >= atom_count
    then None
    else if suffix.(drop) <= available_bytes
    then Some drop
    else scan (drop + atoms_per_window)
  in
  scan 0
;;

(* Smallest cut of any size whose remaining suffix fits. Returns [atom_count]
   when even the newest atom alone exceeds [available_bytes]. *)
let exact_drop ~available_bytes ~atom_count suffix =
  let rec scan drop =
    if drop >= atom_count
    then atom_count
    else if suffix.(drop) <= available_bytes
    then drop
    else scan (drop + 1)
  in
  scan 0
;;

let assemble ~drop ~messages labelled =
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

let project_with_drop
    ~measure_message_bytes
    ~capacity_bytes
    ~reserved_bytes
    (messages : Agent_sdk.Types.message list)
  : (projection, budget_error) result
  =
  let labelled, atom_count = annotate messages in
  (* Everything the cut cannot remove is charged before any atom is
     considered. Pinned messages are re-assembled fresh each turn by the
     keeper hooks, and the preamble is prepended whenever a cut lands on a
     non-[User] head; charging both up front is what makes an over-capacity
     request a typed refusal instead of a cut that can never converge. *)
  let pinned_bytes =
    List.fold_left
      (fun acc (msg, label) ->
         match label with
         | Pinned -> acc + measure_message_bytes msg
         | Atom _ -> acc)
      0
      labelled
  in
  let preamble_bytes = measure_message_bytes preamble_message in
  let undroppable_bytes = pinned_bytes + preamble_bytes in
  let available_bytes = capacity_bytes - reserved_bytes - undroppable_bytes in
  if available_bytes <= 0
  then
    Error
      (Reservation_exceeds_capacity
         { capacity_bytes; reserved_bytes; undroppable_bytes })
  else if atom_count = 0
  then Ok { messages; dropped_atoms = 0 }
  else (
    let per_atom, suffix =
      atom_suffix_bytes ~measure_message_bytes ~atom_count labelled
    in
    match quantized_drop ~available_bytes ~atom_count suffix with
    | Some drop -> Ok { messages = assemble ~drop ~messages labelled; dropped_atoms = drop }
    | None ->
      let drop = exact_drop ~available_bytes ~atom_count suffix in
      if drop >= atom_count
      then
        Error
          (Newest_atom_exceeds_available
             { available_bytes; newest_atom_bytes = per_atom.(atom_count - 1) })
      else Ok { messages = assemble ~drop ~messages labelled; dropped_atoms = drop })
;;

let project ~measure_message_bytes ~capacity_bytes ~reserved_bytes messages =
  Result.map
    (fun projection -> projection.messages)
    (project_with_drop
       ~measure_message_bytes
       ~capacity_bytes
       ~reserved_bytes
       messages)
;;
