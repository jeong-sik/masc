(** Tests for {!Runtime_model_input_tail_window} (RFC-0351 §3 L5, #26534 PR-C,
    #26544, #26551).

    The projection is a pure function of the message list and the byte budget,
    so every case builds a synthetic history and checks the transmitted view
    directly. The load-bearing property is stated once as {!fits_budget} and
    re-asserted per case: whatever the projection returns must fit the budget
    it was given. A count-shaped assertion cannot express that, which is the
    defect these tests cover — a window sized in atoms transmitted an
    over-capacity request whenever atom weight exceeded the sizing sample. *)

module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

let k = Window.atoms_per_window

let message ?(metadata = []) ~role text : Types.message =
  { role
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata
  }
;;

(* Test-local encoder: the byte count is the transmitted text length, so a
   budget in the assertions below is readable as a character count. The
   production caller injects the canonical MASC message encoder instead. *)
let measure_message_bytes (m : Types.message) =
  List.fold_left
    (fun acc (block : Types.content_block) ->
       match block with
       | Types.Text text -> acc + String.length text
       | _ -> acc)
    0
    m.content
;;

let total_bytes messages =
  List.fold_left (fun acc m -> acc + measure_message_bytes m) 0 messages
;;

(* [padded tag bytes] is a message whose measured size is [bytes] and whose
   leading characters identify it, so a cut point stays observable. *)
let padded ~role ~tag bytes =
  let filler = String.make (max 0 (bytes - String.length tag)) 'x' in
  message ~role (tag ^ filler)
;;

let atom_bytes = 1_000
let user i = padded ~role:Types.User ~tag:(Printf.sprintf "user-%d|" i) atom_bytes
let assistant i =
  padded ~role:Types.Assistant ~tag:(Printf.sprintf "assistant-%d|" i) atom_bytes
;;
let tool i = padded ~role:Types.Tool ~tag:(Printf.sprintf "tool-%d|" i) atom_bytes

let extra_context =
  message
    ~metadata:Types.Extra_system_context_provenance.metadata
    ~role:Types.User
    "extra-system-context"
;;

(* [atoms n] builds [n] atoms alternating [user] and [assistant]+2 tools so
   both atom shapes and tool attachment are exercised. The assistant atoms
   weigh three times the user atoms, which is the non-uniformity a count-based
   window cannot see. *)
let atoms n =
  List.concat
    (List.init n (fun i ->
       if i mod 2 = 0
       then [ user i ]
       else [ assistant i; tool i; tool (i + 1000) ]))
;;

let is_preamble (m : Types.message) =
  List.mem_assoc Window.preamble_marker_key m.metadata
;;

let count_atoms messages =
  List.fold_left
    (fun count (m : Types.message) ->
       match m.role with
       | Types.User | Types.Assistant ->
         if is_preamble m
         then count
         else (
           match Types.Extra_system_context_provenance.classify m.metadata with
           | Types.Extra_system_context_provenance.Absent -> count + 1
           | _ -> count)
       | Types.System | Types.Tool -> count)
    0
    messages
;;

let first_text (messages : Types.message list) =
  match messages with
  | { content = Types.Text text :: _; _ } :: _ -> text
  | _ -> "<none>"
;;

(* A capacity no synthetic history in this file can reach, for the cases that
   exercise structure rather than the budget. *)
let unbounded_capacity = 100_000_000

let project ?(allow_empty_history = false) ?(capacity_bytes = unbounded_capacity)
    ?(reserved_bytes = 0) history =
  Window.project
    ~allow_empty_history
    ~measure_message_bytes
    ~capacity_bytes
    ~reserved_bytes
    history
;;

let ok_exn ~what result =
  match result with
  | Ok messages -> messages
  | Error error ->
    Alcotest.failf "%s: %s" what (Window.budget_error_to_string error)
;;

(* The contract, stated once. Everything the projection keeps — pinned
   messages and the synthetic preamble included — has to fit alongside the
   caller's reservation. *)
let fits_budget ~capacity_bytes ~reserved_bytes projected =
  Alcotest.(check bool)
    (Printf.sprintf
       "transmitted %d + reserved %d fits capacity %d"
       (total_bytes projected)
       reserved_bytes
       capacity_bytes)
    true
    (total_bytes projected + reserved_bytes <= capacity_bytes)
;;

let test_identity_when_everything_fits () =
  let history = atoms ((2 * k) - 1) in
  let projected = ok_exn ~what:"identity" (project history) in
  Alcotest.(check bool)
    "physically unchanged when the whole history fits" true
    (projected == history)
;;

let test_empty_list_identity () =
  let projected = ok_exn ~what:"empty" (project []) in
  Alcotest.(check int) "empty stays empty" 0 (List.length projected)
;;

let test_cut_when_over_capacity () =
  (* 4K atoms against a capacity that cannot hold them: the projection must
     cut, and what it returns must fit. *)
  let history = atoms (4 * k) in
  let capacity_bytes = 60_000 in
  let reserved_bytes = 5_000 in
  let projected =
    ok_exn ~what:"cut" (project ~capacity_bytes ~reserved_bytes history)
  in
  Alcotest.(check bool)
    "history was cut" true
    (count_atoms projected < count_atoms history);
  fits_budget ~capacity_bytes ~reserved_bytes projected
;;

let test_heavy_atoms_cut_below_the_count_threshold () =
  (* The regression this module exists for (#26551). The history holds fewer
     than [2 * k] atoms, so an atom-count window is the identity — but the
     atoms are heavy enough that transmitting all of them exceeds capacity.
     The cut must happen on bytes. *)
  let atom_count = (2 * k) - 1 in
  let history = atoms atom_count in
  let capacity_bytes = total_bytes history / 2 in
  let reserved_bytes = 0 in
  let projected =
    ok_exn ~what:"heavy atoms" (project ~capacity_bytes ~reserved_bytes history)
  in
  Alcotest.(check bool)
    "an atom-count window would not have cut here" true
    (atom_count < 2 * k);
  Alcotest.(check bool)
    "history was cut" true
    (count_atoms projected < atom_count);
  fits_budget ~capacity_bytes ~reserved_bytes projected
;;

let test_next_shrink_capacity_clamps_to_lopsided_newest_atom () =
  let pinned =
    message
      ~metadata:Types.Extra_system_context_provenance.metadata
      ~role:Types.User
      "pinned-context"
  in
  let oldest = padded ~role:Types.User ~tag:"oldest|" 400 in
  let newest = padded ~role:Types.User ~tag:"newest|" 600 in
  let history = [ pinned; oldest; newest ] in
  let target_capacity_bytes = total_bytes history / 2 in
  match
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes
      history
  with
  | None -> Alcotest.fail "two non-empty atoms must have a smaller boundary"
  | Some capacity_bytes ->
    Alcotest.(check bool)
      "structural minimum clamps above the raw half target"
      true
      (capacity_bytes > target_capacity_bytes);
    let projected =
      ok_exn
        ~what:"lopsided structural shrink"
        (project ~capacity_bytes history)
    in
    Alcotest.(check int) "oldest atom was removed" 1 (count_atoms projected);
    Alcotest.(check bool)
      "pinned context survived"
      true
      (List.exists (fun message -> message == pinned) projected);
    Alcotest.(check bool)
      "newest atom survived"
      true
      (List.exists (fun message -> message == newest) projected);
    Alcotest.(check bool)
      "capacity includes the conservative preamble reserve"
      true
      (capacity_bytes > total_bytes projected);
    fits_budget ~capacity_bytes ~reserved_bytes:0 projected
;;

let test_next_shrink_capacity_ignores_materialized_preamble () =
  let preamble =
    message
      ~metadata:[ (Window.preamble_marker_key, `Bool true) ]
      ~role:Types.User
      "synthetic preamble"
  in
  let newest = padded ~role:Types.User ~tag:"newest|" 600 in
  match
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes:500
      [ preamble; newest ]
  with
  | None -> ()
  | Some _ ->
    Alcotest.fail
      "a materialized preamble must not create a retry boundary before the newest atom"
;;

let test_next_shrink_rejects_larger_framed_retry () =
  let oldest = padded ~role:Types.User ~tag:"oldest|" 100 in
  let newest = padded ~role:Types.Assistant ~tag:"newest|" 600 in
  match
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes:350
      [ oldest; newest ]
  with
  | None -> ()
  | Some capacity_bytes ->
    Alcotest.failf
      "synthetic framing expanded a 700-byte refusal into a %d-byte retry"
      capacity_bytes
;;

(* #33217: a one-line user message as the oldest atom. Dropping it alone
   saves fewer bytes than the preamble the cut adds, so the first boundary
   at or below the target frames larger than the rejected window; the next
   boundary frames smaller and is the answer. Answering [None] here stopped
   the shrink walk on both official-client lanes before any smaller view was
   tried. *)
let test_next_shrink_walks_past_a_boundary_that_frames_larger () =
  let one_line = message ~role:Types.User "a" in
  let middle = padded ~role:Types.User ~tag:"middle|" 5_000 in
  let newest = padded ~role:Types.Assistant ~tag:"newest|" 5_000 in
  let history = [ one_line; middle; newest ] in
  let rejected_window_bytes = total_bytes history in
  (* The target sits above the whole history: that is the shape in which the
     first boundary (everything but the one-line atom) is at or below the
     target, and the only shape in which it can frame larger. It is the
     bounded retry of a lane whose history is under half its capacity. *)
  match
    Window.next_shrink_capacity_bytes
      ~measure_message_bytes
      ~target_capacity_bytes:(2 * rejected_window_bytes)
      history
  with
  | None ->
    Alcotest.fail
      "the boundary after the one-line atom frames smaller and must be named"
  | Some capacity_bytes ->
    Alcotest.(check bool)
      "the named view is strictly smaller than the rejected window"
      true
      (capacity_bytes < rejected_window_bytes);
    let projected =
      ok_exn ~what:"walk past the first boundary" (project ~capacity_bytes history)
    in
    Alcotest.(check int) "only the newest atom remains" 1 (count_atoms projected);
    Alcotest.(check bool)
      "the newest atom survived"
      true
      (List.exists (fun m -> m == newest) projected);
    Alcotest.(check bool) "the cut is framed" true (List.exists is_preamble projected);
    fits_budget ~capacity_bytes ~reserved_bytes:0 projected
;;

(* When even the newest atom alone frames larger than the rejected window,
   the empty history is the next smaller view for a caller that allows it.
   The one-candidate answer stopped at the newest atom and said there was
   none. *)
let test_next_shrink_reaches_the_empty_history_past_a_larger_clamp () =
  let one_line = message ~role:Types.User "a" in
  let newest = padded ~role:Types.Assistant ~tag:"newest|" 5_000 in
  let history = [ one_line; newest ] in
  let rejected_window_bytes = total_bytes history in
  match
    Window.next_shrink_capacity_bytes
      ~allow_empty_history:true
      ~measure_message_bytes
      ~target_capacity_bytes:(2 * rejected_window_bytes)
      history
  with
  | None -> Alcotest.fail "the empty history is a smaller view and must be named"
  | Some capacity_bytes ->
    Alcotest.(check bool)
      "the named view is strictly smaller than the rejected window"
      true
      (capacity_bytes < rejected_window_bytes);
    let projected =
      ok_exn
        ~what:"empty-history view past a larger clamp"
        (project ~allow_empty_history:true ~capacity_bytes history)
    in
    Alcotest.(check int) "no organic atom remains" 0 (count_atoms projected);
    Alcotest.(check bool) "the floor is framed" true (List.exists is_preamble projected)
;;

let test_bootstrap_floor_drops_the_only_prior_atom () =
  let pinned =
    message
      ~metadata:Types.Extra_system_context_provenance.metadata
      ~role:Types.User
      "pinned-context"
  in
  let only_prior_atom = padded ~role:Types.User ~tag:"prior|" 600 in
  let history = [ pinned; only_prior_atom ] in
  let floor_capacity_bytes =
    match Window.minimum_capacity_bytes ~measure_message_bytes history with
    | Some capacity -> capacity
    | None -> Alcotest.fail "a single prior atom must have a bootstrap floor"
  in
  let projected =
    ok_exn
      ~what:"bootstrap floor"
      (project ~allow_empty_history:true ~capacity_bytes:floor_capacity_bytes history)
  in
  Alcotest.(check int) "all prior atoms were removed" 0 (count_atoms projected);
  Alcotest.(check bool)
    "pinned context survived"
    true
    (List.exists (fun message -> message == pinned) projected);
  Alcotest.(check bool)
    "zero-history floor carries the omission preamble"
    true
    (List.exists is_preamble projected);
  fits_budget ~capacity_bytes:floor_capacity_bytes ~reserved_bytes:0 projected
;;

let test_bootstrap_next_shrink_reaches_zero_history () =
  let only_prior_atom = padded ~role:Types.Assistant ~tag:"prior|" 600 in
  match
    Window.next_shrink_capacity_bytes
      ~allow_empty_history:true
      ~measure_message_bytes
      ~target_capacity_bytes:300
      [ only_prior_atom ]
  with
  | None -> Alcotest.fail "bootstrap shrink must remove the only prior atom"
  | Some capacity_bytes ->
    let projected =
      ok_exn
        ~what:"single-atom bootstrap shrink"
        (project
           ~allow_empty_history:true
           ~capacity_bytes
           [ only_prior_atom ])
    in
    Alcotest.(check int) "no organic atom remains" 0 (count_atoms projected);
    Alcotest.(check bool) "the floor is framed" true (List.exists is_preamble projected)
;;

let test_cut_is_quantized_when_a_quantized_cut_fits () =
  (* Cache stability (#26535): when some multiple of [k] fits, the drop count
     is that multiple, so the transmitted prefix only moves in whole
     windows. *)
  let history = atoms (4 * k) in
  let capacity_bytes = total_bytes history / 2 in
  let projected =
    ok_exn ~what:"quantized" (project ~capacity_bytes history)
  in
  let dropped = count_atoms history - count_atoms projected in
  Alcotest.(check bool)
    (Printf.sprintf "dropped %d is a multiple of %d" dropped k)
    true
    (dropped mod k = 0);
  Alcotest.(check bool) "something was dropped" true (dropped > 0);
  fits_budget ~capacity_bytes ~reserved_bytes:0 projected
;;

let test_cut_point_is_stable_while_the_budget_holds () =
  (* Inside one window the retained head does not move, which is what keeps
     the provider prompt-cache prefix byte-identical between jumps. The
     capacity is chosen so a cut is already in force: a plateau that holds
     only because nothing was cut would not test anything. *)
  let capacity_bytes = 400_000 in
  let projected_after n =
    ok_exn ~what:"plateau" (project ~capacity_bytes (atoms n))
  in
  let head_after n =
    first_text (List.filter (fun m -> not (is_preamble m)) (projected_after n))
  in
  Alcotest.(check bool)
    "a cut is in force at the plateau" true
    (count_atoms (projected_after (4 * k)) < 4 * k);
  Alcotest.(check string)
    "cut point unchanged while the tail grows"
    (head_after (4 * k))
    (head_after ((4 * k) + 1))
;;

let test_exact_cut_when_no_quantized_cut_fits () =
  (* Fewer than [k] atoms can ever be dropped by quantization here, so the
     budget can only be met by an exact cut. Correctness outranks cache
     reuse, and the result must still fit. *)
  let history = atoms (k - 1) in
  let capacity_bytes = total_bytes history / 4 in
  let projected =
    ok_exn ~what:"exact cut" (project ~capacity_bytes history)
  in
  Alcotest.(check bool)
    "history was cut" true
    (count_atoms projected < count_atoms history);
  fits_budget ~capacity_bytes ~reserved_bytes:0 projected
;;

(* The keeper's own history is the thing being reported on, so the assertion is
   stated against the input the caller handed in — not against a number the
   projection also produced. A share computed only from the transmitted list
   would be vacuous: dropped atoms leave no trace there. *)
let test_projection_reports_how_much_history_it_carried () =
  let history = atoms (4 * k) in
  let capacity_bytes = total_bytes history / 8 in
  let projected =
    match
      Window.project_with_drop
        ~measure_message_bytes
        ~capacity_bytes
        ~reserved_bytes:0
        history
    with
    | Ok projection -> projection
    | Error error ->
      Alcotest.failf "reported cut: %s" (Window.budget_error_to_string error)
  in
  let observed =
    Window.observe ~history_atom_count:projected.Window.atom_count projected
  in
  Alcotest.(check int)
    "total is the history the caller handed in"
    (count_atoms history)
    observed.Window.total_atoms;
  Alcotest.(check int)
    "transmitted is what came back"
    (count_atoms projected.Window.messages)
    observed.Window.transmitted_atoms;
  Alcotest.(check bool)
    "a cut history reports less than it held" true
    (observed.Window.transmitted_atoms < observed.Window.total_atoms);
  fits_budget ~capacity_bytes ~reserved_bytes:0 projected.Window.messages
;;

(* Absence of a cut has to be reportable as such. Without this the dashboard
   cannot tell "sent everything" from "no observation", and both would render
   as a full history. *)
let test_uncut_history_reports_everything_carried () =
  let history = atoms 3 in
  let projected =
    match
      Window.project_with_drop
        ~measure_message_bytes
        ~capacity_bytes:unbounded_capacity
        ~reserved_bytes:0
        history
    with
    | Ok projection -> projection
    | Error error ->
      Alcotest.failf "uncut: %s" (Window.budget_error_to_string error)
  in
  let observed =
    Window.observe ~history_atom_count:projected.Window.atom_count projected
  in
  Alcotest.(check int)
    "nothing was dropped" observed.Window.total_atoms observed.Window.transmitted_atoms;
  Alcotest.(check int)
    "and that total is the whole history"
    (count_atoms history)
    observed.Window.total_atoms
;;

(* The demotion pipeline cuts, materializes, and — when a blob fails to
   persist — re-cuts the survivors. That last projection only ever saw the
   survivors, so a denominator read off it would report a keeper that reached
   back over a fraction of its history as having reached over nearly all of
   it. *)
let test_chained_cut_keeps_the_whole_history_as_denominator () =
  let history = atoms (4 * k) in
  let cut ~capacity_bytes messages =
    match
      Window.project_with_drop
        ~measure_message_bytes
        ~capacity_bytes
        ~reserved_bytes:0
        messages
    with
    | Ok projection -> projection
    | Error error ->
      Alcotest.failf "chained cut: %s" (Window.budget_error_to_string error)
  in
  let first = cut ~capacity_bytes:(total_bytes history / 4) history in
  let second =
    cut
      ~capacity_bytes:(total_bytes first.Window.messages / 2)
      first.Window.messages
  in
  let observed =
    Window.observe ~history_atom_count:first.Window.atom_count second
  in
  Alcotest.(check int)
    "denominator is the whole history, not the survivors"
    (count_atoms history)
    observed.Window.total_atoms;
  Alcotest.(check bool)
    "which the chained projection could not have supplied" true
    (observed.Window.total_atoms > second.Window.atom_count);
  Alcotest.(check int)
    "numerator is what the last cut kept"
    (count_atoms second.Window.messages)
    observed.Window.transmitted_atoms
;;

(* The point of the window is how many turns a keeper can still see. Reasoning
   blocks a dialect never replays are deleted before serialization, so charging
   the budget for them buys nothing and costs conversation. This is the feature
   in one assertion: the same budget, the same history, more of it transmitted
   once the unsent bytes stop being counted. *)
module Provider_config = Agent_core.Llm_provider.Provider_config
module Capabilities = Agent_core.Llm_provider.Capabilities

let non_replaying_config =
  Provider_config.make
    ~kind:Provider_config.OpenAI_compat
    ~model_id:"model-a"
    ~base_url:"https://provider.example"
    ~model_capabilities_override:
      { Capabilities.default_capabilities with
        supports_reasoning = true
      ; reasoning_replay_override = Capabilities.Force_no_replay
      }
    ()
;;

(* Each assistant atom carries a reasoning block roughly the size of its text,
   so the unsent share is large enough to move the cut rather than round away. *)
let deliberating_history n =
  List.concat
    (List.init n (fun i ->
       [ user i
       ; message
           ~role:Types.Assistant
           ~metadata:[]
           (Printf.sprintf "assistant-%d|" i)
       ]))
;;

(* The suite's shared encoder counts transmitted text only, which is what makes
   its budgets readable as character counts. That model cannot express this
   case: MASC budgets with [Keeper_context_core.message_to_json], which counts
   every block including the reasoning the wire will delete — that gap is the
   whole defect. So this case measures every block. *)
let measure_all_blocks (m : Types.message) =
  List.fold_left
    (fun acc (block : Types.content_block) ->
       match block with
       | Types.Text text -> acc + String.length text
       | Types.Thinking { content; _ } -> acc + String.length content
       | Types.ReasoningDetails _
       | Types.RedactedThinking _
       | Types.ToolUse _
       | Types.ToolResult _
       | Types.Image _
       | Types.Document _
       | Types.Audio _ -> acc)
    0
    m.content
;;

let total_all_blocks messages =
  List.fold_left (fun acc m -> acc + measure_all_blocks m) 0 messages
;;

let project_all ~capacity_bytes history =
  Window.project
    ~allow_empty_history:false
    ~measure_message_bytes:measure_all_blocks
    ~capacity_bytes
    ~reserved_bytes:0
    history
;;

let test_dropping_unsent_reasoning_widens_the_window () =
  let config = non_replaying_config in
  let history =
    List.map
      (fun (m : Types.message) ->
         match m.role with
         | Types.Assistant ->
           { m with
             Types.content =
               Types.Thinking
                 { content = String.make atom_bytes 'r'; signature = None }
               :: m.content
           }
         | Types.User | Types.Tool | Types.System -> m)
      (deliberating_history (2 * k))
  in
  let capacity_bytes = total_all_blocks history / 4 in
  let raw = ok_exn ~what:"raw cut" (project_all ~capacity_bytes history) in
  let transmitted =
    match
      Agent_core.Llm_provider.Complete_common.transmitted_history ~config history
    with
    | Ok messages -> messages
    | Error error ->
      Alcotest.failf
        "transmitted history: %s"
        (Agent_core.Llm_provider.Reasoning_history_projection.error_to_string error)
  in
  Alcotest.(check bool)
    "the wire drops reasoning this dialect never replays" true
    (total_all_blocks transmitted < total_all_blocks history);
  let projected =
    ok_exn ~what:"projected cut" (project_all ~capacity_bytes transmitted)
  in
  Alcotest.(check bool)
    "so the same budget carries more of the conversation" true
    (count_atoms projected > count_atoms raw)
;;

let test_tool_results_stay_with_their_call () =
  let history = atoms (4 * k) in
  let projected =
    ok_exn ~what:"tool pairing" (project ~capacity_bytes:60_000 history)
  in
  let tool_never_opens_atom =
    let rec scan ~previous_organic = function
      | [] -> true
      | (m : Types.message) :: rest ->
        (match m.role with
         | Types.Tool ->
           (match previous_organic with
            | Some Types.Assistant | Some Types.Tool ->
              scan ~previous_organic:(Some Types.Tool) rest
            | Some Types.User | Some Types.System | None -> false)
         | role -> scan ~previous_organic:(Some role) rest)
    in
    scan ~previous_organic:None projected
  in
  Alcotest.(check bool)
    "every tool message follows its assistant atom" true tool_never_opens_atom
;;

let test_preamble_on_assistant_head () =
  (* All-assistant atoms: after the cut the head organic message is an
     assistant turn, which requires the synthetic user preamble. *)
  let history =
    List.concat (List.init (4 * k) (fun i -> [ assistant i; tool i ]))
  in
  let projected =
    ok_exn ~what:"preamble" (project ~capacity_bytes:60_000 history)
  in
  match projected with
  | head :: _ ->
    Alcotest.(check bool) "head is the tagged preamble" true (is_preamble head);
    Alcotest.(check bool)
      "preamble is a user message" true
      (head.role = Types.User)
  | [] -> Alcotest.fail "projection returned an empty list"
;;

let test_no_preamble_when_nothing_is_cut () =
  let history = atoms (2 * k) in
  let projected = ok_exn ~what:"no cut" (project history) in
  Alcotest.(check bool)
    "no preamble when the whole history fits" false
    (List.exists is_preamble projected)
;;

let test_extra_context_pinned () =
  let history = atoms (4 * k) @ [ extra_context ] in
  let projected =
    ok_exn ~what:"pinned" (project ~capacity_bytes:60_000 history)
  in
  Alcotest.(check bool)
    "extra context survives the cut" true
    (List.exists
       (fun (m : Types.message) ->
          match Types.Extra_system_context_provenance.classify m.metadata with
          | Types.Extra_system_context_provenance.Present -> true
          | _ -> false)
       projected);
  let padded_history = extra_context :: atoms ((2 * k) - 1) in
  let unchanged = ok_exn ~what:"pinned identity" (project padded_history) in
  Alcotest.(check bool)
    "tagged message does not trigger a cut on its own" true
    (unchanged == padded_history)
;;

let test_pinned_bytes_are_charged_before_atoms () =
  (* Pinned messages cannot be dropped, so they are spent from the budget
     first. With the pinned block alone over capacity the projection refuses
     instead of cutting atoms that cannot help. *)
  let pinned =
    message
      ~metadata:Types.Extra_system_context_provenance.metadata
      ~role:Types.User
      (String.make 50_000 'p')
  in
  match project ~capacity_bytes:10_000 (pinned :: atoms 4) with
  | Ok _ -> Alcotest.fail "expected a typed refusal, not a projection"
  | Error (Window.Reservation_exceeds_capacity { undroppable_bytes; _ }) ->
    Alcotest.(check bool)
      "refusal reports the undroppable bytes" true
      (undroppable_bytes >= 50_000)
  | Error other ->
    Alcotest.failf
      "expected Reservation_exceeds_capacity, got %s"
      (Window.budget_error_to_string other)
;;

let test_reservation_exceeding_capacity_is_typed () =
  match project ~capacity_bytes:1_000 ~reserved_bytes:1_000 (atoms 4) with
  | Ok _ -> Alcotest.fail "expected a typed refusal, not a projection"
  | Error (Window.Reservation_exceeds_capacity { capacity_bytes; reserved_bytes; _ })
    ->
    Alcotest.(check int) "capacity is reported" 1_000 capacity_bytes;
    Alcotest.(check int) "reservation is reported" 1_000 reserved_bytes
  | Error other ->
    Alcotest.failf
      "expected Reservation_exceeds_capacity, got %s"
      (Window.budget_error_to_string other)
;;

let test_single_oversized_atom_is_typed () =
  (* Splitting an atom would separate a tool result from its call, so an atom
     larger than the whole history budget is refused rather than truncated. *)
  let heavy i =
    padded ~role:Types.User ~tag:(Printf.sprintf "heavy-%d|" i) 500_000
  in
  match project ~capacity_bytes:1_000_000 ~reserved_bytes:900_000
          [ heavy 0; heavy 1 ]
  with
  | Ok _ -> Alcotest.fail "expected a typed refusal, not a projection"
  | Error (Window.Newest_atom_exceeds_available { newest_atom_bytes; _ }) ->
    Alcotest.(check int)
      "refusal reports the atom size" 500_000 newest_atom_bytes
  | Error other ->
    Alcotest.failf
      "expected Newest_atom_exceeds_available, got %s"
      (Window.budget_error_to_string other)
;;

let test_never_returns_an_over_budget_projection () =
  (* Termination guard. A projection that returned an over-budget list would
     be refused by the provider without shrinking the next assembly, because a
     failed turn adds no history — the request would repeat byte-for-byte.
     Every accepted capacity across the range must therefore either fit or
     refuse. *)
  let history = atoms (5 * k) in
  let reserved_bytes = 1_000 in
  let projected_count = ref 0 in
  List.iter
    (fun capacity_bytes ->
       match project ~capacity_bytes ~reserved_bytes history with
       | Ok projected ->
         incr projected_count;
         fits_budget ~capacity_bytes ~reserved_bytes projected
       | Error _ -> ())
    [ 5_000; 20_000; 60_000; 150_000; 400_000; 900_000; 2_000_000 ];
  (* Without this the case passes vacuously: a projection that refused every
     capacity would assert nothing at all. *)
  Alcotest.(check bool)
    "at least one capacity produced a projection to check" true
    (!projected_count > 0)
;;

let has_tag tag messages =
  let width = String.length tag in
  List.exists
    (fun (m : Types.message) ->
       match m.content with
       | [ Types.Text text ] ->
         String.length text >= width && String.equal (String.sub text 0 width) tag
       | _ -> false)
    messages
;;

let test_leading_orphan_tools_drop_with_first_atom () =
  let history = tool 9000 :: tool 9001 :: atoms (4 * k) in
  Alcotest.(check bool)
    "the orphan run is present before projection" true
    (has_tag "tool-9000|" history);
  let projected =
    ok_exn ~what:"orphan tools" (project ~capacity_bytes:60_000 history)
  in
  Alcotest.(check bool)
    "orphan head tools are not transmitted" false
    (has_tag "tool-9000|" projected)
;;

let test_deterministic () =
  let history = atoms ((2 * k) + 7) in
  let capacity_bytes = 90_000 in
  let a = ok_exn ~what:"first" (project ~capacity_bytes history) in
  let b = ok_exn ~what:"second" (project ~capacity_bytes history) in
  Alcotest.(check int) "same length" (List.length a) (List.length b);
  Alcotest.(check bool)
    "same head" true
    (String.equal (first_text a) (first_text b))
;;

let () =
  Alcotest.run
    "runtime_model_input_tail_window"
    [ ( "tail_window"
      , [ Alcotest.test_case "identity when everything fits" `Quick
            test_identity_when_everything_fits
        ; Alcotest.test_case "empty list identity" `Quick
            test_empty_list_identity
        ; Alcotest.test_case "cut when over capacity" `Quick
            test_cut_when_over_capacity
        ; Alcotest.test_case "heavy atoms cut below the count threshold" `Quick
            test_heavy_atoms_cut_below_the_count_threshold
        ; Alcotest.test_case
            "next shrink clamps to lopsided newest atom"
            `Quick
            test_next_shrink_capacity_clamps_to_lopsided_newest_atom
        ; Alcotest.test_case
            "next shrink ignores materialized preamble"
            `Quick
            test_next_shrink_capacity_ignores_materialized_preamble
        ; Alcotest.test_case
            "next shrink rejects larger framed retry"
            `Quick
            test_next_shrink_rejects_larger_framed_retry
        ; Alcotest.test_case
            "next shrink walks past a boundary that frames larger"
            `Quick
            test_next_shrink_walks_past_a_boundary_that_frames_larger
        ; Alcotest.test_case
            "next shrink reaches the empty history past a larger clamp"
            `Quick
            test_next_shrink_reaches_the_empty_history_past_a_larger_clamp
        ; Alcotest.test_case
            "bootstrap floor drops the only prior atom"
            `Quick
            test_bootstrap_floor_drops_the_only_prior_atom
        ; Alcotest.test_case
            "bootstrap next shrink reaches zero history"
            `Quick
            test_bootstrap_next_shrink_reaches_zero_history
        ; Alcotest.test_case "cut is quantized when a quantized cut fits" `Quick
            test_cut_is_quantized_when_a_quantized_cut_fits
        ; Alcotest.test_case "cut point is stable while the budget holds" `Quick
            test_cut_point_is_stable_while_the_budget_holds
        ; Alcotest.test_case "exact cut when no quantized cut fits" `Quick
            test_exact_cut_when_no_quantized_cut_fits
        ; Alcotest.test_case "projection reports how much history it carried"
            `Quick test_projection_reports_how_much_history_it_carried
        ; Alcotest.test_case "uncut history reports everything carried" `Quick
            test_uncut_history_reports_everything_carried
        ; Alcotest.test_case "chained cut keeps the whole history as denominator"
            `Quick test_chained_cut_keeps_the_whole_history_as_denominator
        ; Alcotest.test_case "dropping unsent reasoning widens the window"
            `Quick test_dropping_unsent_reasoning_widens_the_window
        ; Alcotest.test_case "tool results stay with their call" `Quick
            test_tool_results_stay_with_their_call
        ; Alcotest.test_case "preamble on assistant head" `Quick
            test_preamble_on_assistant_head
        ; Alcotest.test_case "no preamble when nothing is cut" `Quick
            test_no_preamble_when_nothing_is_cut
        ; Alcotest.test_case "extra context pinned" `Quick
            test_extra_context_pinned
        ; Alcotest.test_case "pinned bytes are charged before atoms" `Quick
            test_pinned_bytes_are_charged_before_atoms
        ; Alcotest.test_case "reservation exceeding capacity is typed" `Quick
            test_reservation_exceeding_capacity_is_typed
        ; Alcotest.test_case "single oversized atom is typed" `Quick
            test_single_oversized_atom_is_typed
        ; Alcotest.test_case "never returns an over-budget projection" `Quick
            test_never_returns_an_over_budget_projection
        ; Alcotest.test_case "leading orphan tools drop" `Quick
            test_leading_orphan_tools_drop_with_first_atom
        ; Alcotest.test_case "deterministic" `Quick test_deterministic
        ] )
    ]
;;
