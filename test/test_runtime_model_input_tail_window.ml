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
module Types = Agent_sdk.Types

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

let project ?(capacity_bytes = unbounded_capacity) ?(reserved_bytes = 0) history =
  Window.project
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
  List.iter
    (fun capacity_bytes ->
       match project ~capacity_bytes ~reserved_bytes history with
       | Ok projected -> fits_budget ~capacity_bytes ~reserved_bytes projected
       | Error _ -> ())
    [ 5_000; 20_000; 60_000; 150_000; 400_000; 900_000; 2_000_000 ]
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
        ; Alcotest.test_case "cut is quantized when a quantized cut fits" `Quick
            test_cut_is_quantized_when_a_quantized_cut_fits
        ; Alcotest.test_case "cut point is stable while the budget holds" `Quick
            test_cut_point_is_stable_while_the_budget_holds
        ; Alcotest.test_case "exact cut when no quantized cut fits" `Quick
            test_exact_cut_when_no_quantized_cut_fits
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
