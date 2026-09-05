(** Bounded transmission view over provider-bound history — see the
    interface for the contract (RFC-0351 §3 L5, #26534 PR-C, #26535, #26551). *)

let atoms_per_window = 60
let preamble_marker_key = "masc.model_input_tail_window.v1"

let preamble_text =
  "[context window] Older turns of this conversation are omitted from this \
   request. The full history is preserved in the durable checkpoint and \
   surfaces through the memory system when relevant."

let preamble_message : Agent_core.Types.message =
  { role = Agent_core.Types.User
  ; content = [ Agent_core.Types.Text preamble_text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = [ (preamble_marker_key, `Bool true) ]
  }
;;

let is_synthetic_preamble (message : Agent_core.Types.message) =
  match List.assoc_opt preamble_marker_key message.metadata with
  | Some (`Bool true) -> true
  | Some _ | None -> false
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
  { messages : Agent_core.Types.message list
  ; dropped_atoms : int
  ; atom_count : int
  }

type window_observation =
  { transmitted_atoms : int
  ; total_atoms : int
  }

let observe ~history_atom_count (projection : projection) =
  { transmitted_atoms = projection.atom_count - projection.dropped_atoms
  ; total_atoms = history_atom_count
  }
;;

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

(* Both constructors say one thing: this candidate's declared ceiling cannot
   carry material this turn has to transmit. That is a per-candidate capacity
   bound, not a defect in the request -- keeper_turn_driver.ml states the same
   rationale for the provider-raised case, "a later lane candidate with a
   larger context window can still serve the same turn" -- so it is named with
   the constructor the lane loop already rotates on rather than a new one.

   [limit] is [None] because it is tokens (keeper_turn_runtime_budget reads it
   as [Provider_overflow { limit_tokens }]) and this window measures bytes.
   Reporting a byte figure there would be read as a token count. *)
let budget_error_to_core_error error =
  Agent_core.Error.Api
    (Llm_provider.Retry.ContextOverflow
       { message = budget_error_to_string error; limit = None })
;;

(* A message is pinned when it must survive every cut: [System] entries
   (defensive — the runtime carries the system prompt out of band) and any
   message with extra-system-context provenance. [Invalid]/[Duplicate]
   provenance still means the per-turn context assembler authored the
   message, so it is pinned rather than exposed to the cut on a malformed
   tag. *)
let is_extra_context (msg : Agent_core.Types.message) =
  match
    Agent_core.Types.Extra_system_context_provenance.classify msg.metadata
  with
  | Agent_core.Types.Extra_system_context_provenance.Absent -> false
  | Agent_core.Types.Extra_system_context_provenance.Present
  | Agent_core.Types.Extra_system_context_provenance.Invalid
  | Agent_core.Types.Extra_system_context_provenance.Duplicate -> true
;;

type label =
  | Pinned
  | Atom of int

(* Label every message with its atom index, in order. [User] and [Assistant]
   open a new atom; [Tool] joins the atom of the assistant that issued the
   call, so both sides of a tool exchange always share one label. A leading
   orphan [Tool] run (possible only on a history that was already cut
   upstream of AGENT_CORE) becomes atom 0 so it is dropped with the first cut
   rather than transmitted headless. *)
let annotate (messages : Agent_core.Types.message list) :
  (Agent_core.Types.message * label) list * int
  =
  let labelled_rev, atom_count =
    List.fold_left
      (fun (acc, count) (msg : Agent_core.Types.message) ->
         if is_extra_context msg
         then ((msg, Pinned) :: acc, count)
         else (
           match msg.role with
           | Agent_core.Types.System -> ((msg, Pinned) :: acc, count)
           | Agent_core.Types.User | Agent_core.Types.Assistant ->
             ((msg, Atom count) :: acc, count + 1)
           | Agent_core.Types.Tool ->
             if count = 0
             then ((msg, Atom 0) :: acc, 1)
             else ((msg, Atom (count - 1)) :: acc, count)))
      ([], 0)
      messages
  in
  (List.rev labelled_rev, atom_count)
;;

let first_atom_at_or_after messages ~message_index =
  let labelled, atom_count = annotate messages in
  let rec scan position = function
    | [] -> atom_count
    | (_, label) :: rest ->
      (match label with
       | Atom index when position >= message_index -> index
       | Atom _ | Pinned -> scan (position + 1) rest)
  in
  scan 0 labelled
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

let next_shrink_capacity_bytes
    ?(allow_empty_history = false)
    ~measure_message_bytes
    ~target_capacity_bytes
    messages =
  let rejected_window_bytes =
    List.fold_left
      (fun total message -> total + measure_message_bytes message)
      0
      messages
  in
  (* A provider-bound list may already contain the preamble materialized by a
     previous cut. It is generated framing, not a durable conversation atom;
     never let it become the oldest removable atom of the next retry. *)
  let shrinkable_messages =
    List.filter (fun message -> not (is_synthetic_preamble message)) messages
  in
  let labelled, atom_count = annotate shrinkable_messages in
  if atom_count = 0
  then None
  else (
    let pinned_bytes =
      List.fold_left
        (fun total (message, label) ->
           match label with
           | Pinned -> total + measure_message_bytes message
           | Atom _ -> total)
        0
        labelled
    in
    let preamble_bytes = measure_message_bytes preamble_message in
    let undroppable_bytes = pinned_bytes + preamble_bytes in
    let _, suffix =
      atom_suffix_bytes ~measure_message_bytes ~atom_count labelled
    in
    let full_atom_bytes = suffix.(0) in
    let target_atom_bytes = target_capacity_bytes - undroppable_bytes in
    let required_atom_capacity bytes = max 1 bytes in
    let rec boundaries_at_or_below_target drop =
      if drop >= atom_count
      then []
      else (
        let retained = required_atom_capacity suffix.(drop) in
        let rest = boundaries_at_or_below_target (drop + 1) in
        if retained < full_atom_bytes && retained <= target_atom_bytes
        then retained :: rest
        else rest)
    in
    let newest_atom_bytes =
      required_atom_capacity suffix.(atom_count - 1)
    in
    (* Candidate views, largest first: every atom boundary at or below the
       target, then the newest atom alone when the target sits below that
       indivisible atom (clamping upward rather than returning a capacity the
       projection must reject locally), then the empty history where the
       caller allows it. Removing an atom is not sufficient when the retained
       suffix starts with Assistant/Tool: [project] then adds the synthetic
       User preamble, so a candidate is only an answer when its framed size
       is strictly smaller than the exact window the provider already
       rejected. A boundary can fail that test while a deeper one passes:
       dropping only the oldest atom saves less than the preamble the cut
       adds whenever that atom is shorter than the preamble encoding, which
       is any one-line user message (#33217); answering [None] there ended
       the shrink walk on both official-client lanes before any deeper view
       was asked. The same order also reaches the empty history when the
       newest atom alone frames larger and the caller allows it, which the
       one-candidate answer never did. *)
    let candidates =
      boundaries_at_or_below_target 1
      @ (if newest_atom_bytes < full_atom_bytes then [ newest_atom_bytes ] else [])
      @ if allow_empty_history then [ 0 ] else []
    in
    List.find_map
      (fun retained ->
         let framed_capacity = undroppable_bytes + retained in
         if framed_capacity < rejected_window_bytes
         then Some framed_capacity
         else None)
      candidates)
;;

let minimum_capacity_bytes ~measure_message_bytes messages =
  let rejected_window_bytes =
    List.fold_left
      (fun total message -> total + measure_message_bytes message)
      0
      messages
  in
  let shrinkable_messages =
    List.filter (fun message -> not (is_synthetic_preamble message)) messages
  in
  let labelled, atom_count = annotate shrinkable_messages in
  if atom_count = 0
  then None
  else (
    let pinned_bytes =
      List.fold_left
        (fun total (message, label) ->
           match label with
           | Pinned -> total + measure_message_bytes message
           | Atom _ -> total)
        0
        labelled
    in
    let floor_capacity_bytes =
      pinned_bytes + measure_message_bytes preamble_message
    in
    if floor_capacity_bytes < rejected_window_bytes
    then Some floor_capacity_bytes
    else None)
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

let assemble ~allow_empty_history ~atom_count ~drop ~messages labelled =
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
        (fun ((msg : Agent_core.Types.message), label) ->
           match label with
           | Atom _ -> Some msg.role
           | Pinned -> None)
        kept_labelled
    in
    let kept = List.map fst kept_labelled in
    match first_kept_atom_role with
    | None when allow_empty_history && drop >= atom_count -> preamble_message :: kept
    | Some Agent_core.Types.User | None -> kept
    | Some Agent_core.Types.Assistant
    | Some Agent_core.Types.Tool
    | Some Agent_core.Types.System -> preamble_message :: kept)
;;

let project_with_drop
    ?(allow_empty_history = false)
    ~measure_message_bytes
    ~capacity_bytes
    ~reserved_bytes
    (messages : Agent_core.Types.message list)
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
  if available_bytes < 0 || (available_bytes = 0 && not allow_empty_history)
  then
    Error
      (Reservation_exceeds_capacity
         { capacity_bytes; reserved_bytes; undroppable_bytes })
  else if atom_count = 0
  then Ok { messages; dropped_atoms = 0; atom_count }
  else (
    let per_atom, suffix =
      atom_suffix_bytes ~measure_message_bytes ~atom_count labelled
    in
    match quantized_drop ~available_bytes ~atom_count suffix with
    | Some drop ->
      Ok
        { messages =
            assemble ~allow_empty_history ~atom_count ~drop ~messages labelled
        ; dropped_atoms = drop
        ; atom_count
        }
    | None ->
      let drop = exact_drop ~available_bytes ~atom_count suffix in
      if drop >= atom_count && not allow_empty_history
      then
        Error
          (Newest_atom_exceeds_available
             { available_bytes; newest_atom_bytes = per_atom.(atom_count - 1) })
      else
        Ok
          { messages =
              assemble ~allow_empty_history ~atom_count ~drop ~messages labelled
          ; dropped_atoms = drop
          ; atom_count
          })
;;

let project ?(allow_empty_history = false) ~measure_message_bytes ~capacity_bytes
    ~reserved_bytes messages =
  Result.map
    (fun projection -> projection.messages)
    (project_with_drop
       ~allow_empty_history
       ~measure_message_bytes
       ~capacity_bytes
       ~reserved_bytes
       messages)
;;
