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

(* The Librarian working state opens a summarized range
   ([Keeper_turn_driver_try_provider]) and must survive every cut, like the
   per-turn context. It is not that context: AGENT_CORE appends the per-turn
   carrier once per provider round and [Keeper_agent_prompt_metrics] expects
   exactly one, so a working state under the carrier's tag read as a second
   carrier, or as a carrier the params hook never announced, on every
   request that carried one (10,864 warnings on 2026-09-22, every turn
   record of those keepers without an input composition). *)
let working_state_marker_key = "masc.librarian_working_state.v1"
let working_state_metadata = [ (working_state_marker_key, `Bool true) ]

let is_working_state (message : Agent_core.Types.message) =
  List.mem_assoc working_state_marker_key message.metadata
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
  ; front_atom_digest : string
  }

(* A window names its front by the message that opens it. A projection that
   carried no atom puts its front at [history_atom_count], an index the
   history's lookup has no atom at, so it is no observation. *)
let observe ~digest_at ~history_atom_count (projection : projection) =
  let transmitted_atoms = projection.atom_count - projection.dropped_atoms in
  Option.map
    (fun front_atom_digest ->
       { transmitted_atoms; total_atoms = history_atom_count; front_atom_digest })
    (digest_at (history_atom_count - transmitted_atoms))
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
   (defensive — the runtime carries the system prompt out of band), any
   message with extra-system-context provenance, and the Librarian working
   state. [Invalid]/[Duplicate] provenance still means the per-turn context
   assembler authored the message, so it is pinned rather than exposed to
   the cut on a malformed tag. *)
let is_extra_context (msg : Agent_core.Types.message) =
  match
    Agent_core.Types.Extra_system_context_provenance.classify msg.metadata
  with
  | Agent_core.Types.Extra_system_context_provenance.Absent -> false
  | Agent_core.Types.Extra_system_context_provenance.Present
  | Agent_core.Types.Extra_system_context_provenance.Invalid
  | Agent_core.Types.Extra_system_context_provenance.Duplicate -> true
;;

let is_pinned msg = is_extra_context msg || is_working_state msg

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
         if is_pinned msg
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

(* The atom's position is its index plus the message that opens it: the
   first message [annotate] labels with that index, a [User] or [Assistant]
   message (or the orphan [Tool] that heads a history cut upstream). A [Tool]
   message that joins the atom later carries an index the atom already has,
   so it never becomes the opener. The digest is over the checkpoint
   encoding of that one message, the bytes a save writes for it.

   Partial application does the labelling once; each lookup encodes and
   hashes one message. *)
let atom_opening_digest (messages : Agent_core.Types.message list) =
  let labelled, _atom_count = annotate messages in
  let openers_rev, _next =
    List.fold_left
      (fun (openers, next) (message, label) ->
         match label with
         | Atom index when index = next -> message :: openers, next + 1
         | Atom _ | Pinned -> openers, next)
      ([], 0)
      labelled
  in
  let openers = Array.of_list (List.rev openers_rev) in
  fun atom ->
    if atom < 0 || atom >= Array.length openers
    then None
    else (
      let encoded =
        Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json openers.(atom))
      in
      Some Digestif.SHA256.(digest_string encoded |> to_hex))
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

(* [assemble] and whether it prepended the synthetic preamble, which the
   target projection charges only when it is transmitted. *)
let assemble_with_preamble ?(history_already_announced = false) ~allow_empty_history ~atom_count ~drop ~messages labelled =
  if drop = 0
  then messages, false
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
    | None when allow_empty_history && drop >= atom_count
                && not history_already_announced -> preamble_message :: kept, true
    | Some Agent_core.Types.User | None -> kept, false
    | Some Agent_core.Types.Assistant
    | Some Agent_core.Types.Tool
    | Some Agent_core.Types.System -> preamble_message :: kept, true)
;;

let assemble ~allow_empty_history ~atom_count ~drop ~messages labelled =
  fst (assemble_with_preamble ~allow_empty_history ~atom_count ~drop ~messages labelled)
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

(* {1 Target projection} *)

type overrun_cause =
  | Fixed_parts_exceed_target
  | Newest_atom_exceeds_target

type target_fit =
  | Within_target
  | Overrun of
      { by_bytes : int
      ; cause : overrun_cause
      }

type target_projection =
  { projection : projection
  ; fit : target_fit
  ; transmitted_bytes : int
  }

let target_fit_to_string = function
  | Within_target -> "within_target"
  | Overrun { by_bytes; cause = Fixed_parts_exceed_target } ->
    Printf.sprintf "overrun_by_fixed_parts:%d" by_bytes
  | Overrun { by_bytes; cause = Newest_atom_exceeds_target } ->
    Printf.sprintf "overrun_by_newest_atom:%d" by_bytes
;;

let pinned_bytes_of ~measure_message_bytes labelled =
  List.fold_left
    (fun acc (msg, label) ->
       match label with
       | Pinned -> acc + measure_message_bytes msg
       | Atom _ -> acc)
    0
    labelled
;;

(* The same quantized cut as [project_with_drop], with one difference in what
   happens when no suffix fits: the newest atom is transmitted anyway and the
   overrun is reported. The window is a target, and the parts no cut can
   remove -- the reservation, pinned context, the newest atom -- are what the
   turn is about; whether the provider can take them is the request-body
   cap's and the provider's verdict, not this stage's. *)
let project_target ~measure_message_bytes ~target_bytes ~reserved_bytes messages =
  let labelled, atom_count = annotate messages in
  let pinned_bytes = pinned_bytes_of ~measure_message_bytes labelled in
  let preamble_bytes = measure_message_bytes preamble_message in
  let available_bytes = target_bytes - reserved_bytes - pinned_bytes - preamble_bytes in
  let fit ~overrun_cause ~transmitted_bytes =
    let request_bytes = reserved_bytes + transmitted_bytes in
    match overrun_cause with
    | Some cause when request_bytes > target_bytes ->
      Overrun { by_bytes = request_bytes - target_bytes; cause }
    | Some _ | None -> Within_target
  in
  if atom_count = 0
  then (
    let transmitted_bytes = pinned_bytes in
    { projection = { messages; dropped_atoms = 0; atom_count }
    ; fit = fit ~overrun_cause:(Some Fixed_parts_exceed_target) ~transmitted_bytes
    ; transmitted_bytes
    })
  else (
    let _, suffix = atom_suffix_bytes ~measure_message_bytes ~atom_count labelled in
    let newest_only = atom_count - 1 in
    let drop, overrun_cause =
      if available_bytes < 0
      then newest_only, Some Fixed_parts_exceed_target
      else (
        match quantized_drop ~available_bytes ~atom_count suffix with
        | Some drop -> drop, None
        | None ->
          let drop = exact_drop ~available_bytes ~atom_count suffix in
          if drop >= atom_count
          then newest_only, Some Newest_atom_exceeds_target
          else drop, None)
    in
    let assembled, preamble_prepended =
      assemble_with_preamble ~allow_empty_history:false ~atom_count ~drop ~messages labelled
    in
    let transmitted_bytes =
      pinned_bytes + suffix.(drop) + (if preamble_prepended then preamble_bytes else 0)
    in
    { projection = { messages = assembled; dropped_atoms = drop; atom_count }
    ; fit = fit ~overrun_cause ~transmitted_bytes
    ; transmitted_bytes
    })
;;

let project_from_atom ?(allow_empty_history = false)
    ?(history_already_announced = false) ~measure_message_bytes ~first_atom messages =
  let labelled, atom_count = annotate messages in
  let pinned_bytes = pinned_bytes_of ~measure_message_bytes labelled in
  if atom_count = 0
  then { messages; dropped_atoms = 0; atom_count }, pinned_bytes
  else (
    let last = if allow_empty_history then atom_count else atom_count - 1 in
    let drop = max 0 (min first_atom last) in
    let _, suffix = atom_suffix_bytes ~measure_message_bytes ~atom_count labelled in
    let assembled, preamble_prepended =
      assemble_with_preamble ~history_already_announced ~allow_empty_history ~atom_count ~drop ~messages labelled
    in
    let transmitted_bytes =
      pinned_bytes
      + suffix.(drop)
      + if preamble_prepended then measure_message_bytes preamble_message else 0
    in
    { messages = assembled; dropped_atoms = drop; atom_count }, transmitted_bytes)
;;

