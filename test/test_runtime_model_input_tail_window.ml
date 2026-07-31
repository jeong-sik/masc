(** Tests for {!Runtime_model_input_tail_window} (RFC #26534 PR-C, #26544).

    The projection is a pure function of the message list, so every case
    builds a synthetic history and checks the transmitted view directly:
    identity below the threshold, quantized cut placement, tool-call atom
    integrity, extra-context pinning, and the synthetic [User] preamble. *)

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

let user i = message ~role:Types.User (Printf.sprintf "user-%d" i)
let assistant i = message ~role:Types.Assistant (Printf.sprintf "assistant-%d" i)
let tool i = message ~role:Types.Tool (Printf.sprintf "tool-%d" i)

let extra_context =
  message
    ~metadata:Types.Extra_system_context_provenance.metadata
    ~role:Types.User
    "extra-system-context"
;;

(* [atoms n] builds [n] atoms alternating [user] and [assistant]+2 tools so
   both atom shapes and tool attachment are exercised. *)
let atoms n =
  List.concat
    (List.init n (fun i ->
       if i mod 2 = 0
       then [ user i ]
       else [ assistant i; tool i; tool (i + 1000) ]))
;;

let count_atoms messages =
  List.fold_left
    (fun count (m : Types.message) ->
       match m.role with
       | Types.User | Types.Assistant ->
         (match Types.Extra_system_context_provenance.classify m.metadata with
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

let is_preamble (m : Types.message) =
  List.mem_assoc Window.preamble_marker_key m.metadata
;;

let test_identity_below_threshold () =
  let history = atoms ((2 * k) - 1) in
  let projected = Window.project history in
  Alcotest.(check bool)
    "physically unchanged below 2K-1 atoms" true
    (projected == history)
;;

let test_empty_list_identity () =
  Alcotest.(check int) "empty stays empty" 0 (List.length (Window.project []))
;;

let test_cut_at_threshold () =
  let history = atoms (2 * k) in
  let projected = Window.project history in
  Alcotest.(check int) "keeps exactly K atoms at 2K" k (count_atoms projected)
;;

let test_quantized_cut_point () =
  (* Between 2K and 3K-1 atoms the drop count stays at K, so the retained
     head atom is stable while the tail grows — the prompt-cache-stable
     plateau. At 3K the drop jumps to 2K. *)
  let head_after n =
    let projected = Window.project (atoms n) in
    first_text (List.filter (fun m -> not (is_preamble m)) projected)
  in
  let plateau_start = head_after (2 * k) in
  Alcotest.(check string)
    "cut point unchanged while the tail grows"
    plateau_start
    (head_after ((3 * k) - 1));
  Alcotest.(check bool)
    "cut point jumps at 3K"
    false
    (String.equal plateau_start (head_after (3 * k)))
;;

let test_tool_results_stay_with_their_call () =
  let history = atoms (2 * k) in
  let projected = Window.project history in
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
    List.concat (List.init (2 * k) (fun i -> [ assistant i; tool i ]))
  in
  let projected = Window.project history in
  match projected with
  | head :: _ ->
    Alcotest.(check bool) "head is the tagged preamble" true (is_preamble head);
    Alcotest.(check bool)
      "preamble is a user message" true
      (head.role = Types.User)
  | [] -> Alcotest.fail "projection returned an empty list"
;;

let test_no_preamble_on_user_head () =
  (* Even atom count with the user/assistant alternation puts a user atom at
     every even index, so a drop of K (even) lands on a user head. *)
  let history = atoms (2 * k) in
  let projected = Window.project history in
  Alcotest.(check bool)
    "no preamble when the retained head is a user message" false
    (List.exists is_preamble projected)
;;

let test_extra_context_pinned () =
  (* 2K organic atoms force a cut; the tagged extra-context message must
     survive it and must not count toward the window. *)
  let projected = Window.project (atoms (2 * k) @ [ extra_context ]) in
  Alcotest.(check bool)
    "extra context survives the cut" true
    (List.exists
       (fun (m : Types.message) ->
          match Types.Extra_system_context_provenance.classify m.metadata with
          | Types.Extra_system_context_provenance.Present -> true
          | _ -> false)
       projected);
  (* Below the threshold the tagged message must not tip the atom count
     over the cut boundary. *)
  let padded = extra_context :: atoms ((2 * k) - 1) in
  Alcotest.(check bool)
    "tagged message does not trigger a cut" true
    (Window.project padded == padded)
;;

let test_leading_orphan_tools_drop_with_first_atom () =
  let history = tool 9000 :: tool 9001 :: atoms (2 * k) in
  let projected = Window.project history in
  Alcotest.(check bool)
    "orphan head tools are not transmitted" false
    (List.exists
       (fun (m : Types.message) ->
          match m.content with
          | [ Types.Text text ] -> String.equal text "tool-9000"
          | _ -> false)
       projected)
;;

let test_deterministic () =
  let history = atoms ((2 * k) + 7) in
  let a = Window.project history in
  let b = Window.project history in
  Alcotest.(check int) "same length" (List.length a) (List.length b);
  Alcotest.(check bool)
    "same head" true
    (String.equal (first_text a) (first_text b))
;;

let () =
  Alcotest.run
    "runtime_model_input_tail_window"
    [ ( "tail_window"
      , [ Alcotest.test_case "identity below threshold" `Quick
            test_identity_below_threshold
        ; Alcotest.test_case "empty list identity" `Quick
            test_empty_list_identity
        ; Alcotest.test_case "cut at threshold keeps K atoms" `Quick
            test_cut_at_threshold
        ; Alcotest.test_case "cut point is quantized" `Quick
            test_quantized_cut_point
        ; Alcotest.test_case "tool results stay with their call" `Quick
            test_tool_results_stay_with_their_call
        ; Alcotest.test_case "preamble on assistant head" `Quick
            test_preamble_on_assistant_head
        ; Alcotest.test_case "no preamble on user head" `Quick
            test_no_preamble_on_user_head
        ; Alcotest.test_case "extra context pinned" `Quick
            test_extra_context_pinned
        ; Alcotest.test_case "leading orphan tools drop" `Quick
            test_leading_orphan_tools_drop_with_first_atom
        ; Alcotest.test_case "deterministic" `Quick test_deterministic
        ] )
    ]
;;
