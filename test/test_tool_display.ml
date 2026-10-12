(* Display labels only. The wire name is the identity and is never changed. *)

let check name ~input ~expected () =
  Alcotest.(check string) name expected (Masc.Tool_display.label input)

let tests =
  [
    ("snake prefix kept", `Quick, check "snake" ~input:"keeper_task_done" ~expected:"KeeperTaskDone");
    ("masc prefix kept", `Quick, check "masc" ~input:"masc_board_post" ~expected:"MascBoardPost");
    ("pascal unchanged", `Quick, check "pascal" ~input:"WebFetch" ~expected:"WebFetch");
    ("single word", `Quick, check "single" ~input:"Execute" ~expected:"Execute");
    ("empty segments", `Quick, check "empty" ~input:"a__b" ~expected:"AB");
    ("empty string", `Quick, check "empty-string" ~input:"" ~expected:"");
  ]

(* task-2239: the gate row a human decides on draws its tool through the same
   label. A row whose operation is not an identity call shows the label while
   the wire name stays the identity on gp_operation. (The identity-call row,
   whose display comes from the stored input, keeps its own decode test.) *)
let gate_row_shows_the_display_label () =
  let queue =
    `List
      [ `Assoc
          [ ("id", `String "appr-2");
            ("keeper_name", `String "echo");
            ("tool_name", `String "keeper_memory_search");
            ("phase", `String "queued");
            ("input_preview", `String "{}");
            ("waiting_s", `Int 7);
          ] ]
  in
  let snapshot_json =
    `Assoc
      [ ("approval_queue", queue);
        ("approval_queue_state", `Null);
        ("hitl", `Null);
        ("approval_rules", `Null);
        ("approval_rules_state", `Null);
      ]
  in
  match Masc.Tui_decode.decode_gate_snapshot snapshot_json with
  | Error message -> Alcotest.failf "the snapshot did not decode: %s" message
  | Ok snapshot -> (
      match snapshot.Masc.Tui_decode.gs_pending with
      | [ pending ] ->
          Alcotest.check Alcotest.string "operation keeps the wire name"
            "keeper_memory_search" pending.Masc.Tui_decode.gp_operation;
          Alcotest.check Alcotest.string "display shows the label"
            "KeeperMemorySearch" pending.Masc.Tui_decode.gp_display_tool
      | rows ->
          Alcotest.failf "expected one pending row, got %d" (List.length rows))

(* Every registered public and internal name must get a label that no other
   registered name shares. A collision here would make two tools look the
   same in the TUI, so it fails the build instead of shipping silently. *)
let registry_is_injective () =
  let module Descriptor = Masc.Keeper_tool_descriptor in
  let by_label : (string, string) Hashtbl.t = Hashtbl.create 128 in
  let collisions = ref [] in
  let note name =
    let label = Masc.Tool_display.label name in
    match Hashtbl.find_opt by_label label with
    | None -> Hashtbl.replace by_label label name
    | Some other when String.equal other name -> ()
    | Some other -> collisions := (label, other, name) :: !collisions
  in
  List.iter
    (fun (d : Descriptor.t) ->
      note d.Descriptor.public_name;
      note d.Descriptor.internal_name)
    (Descriptor.all_descriptors ());
  match !collisions with
  | [] -> ()
  | cs ->
      let show (label, a, b) = Printf.sprintf "%s <- {%s, %s}" label a b in
      Alcotest.fail
        ("label collisions: " ^ String.concat "; " (List.map show cs))

let () =
  Alcotest.run "tool_display"
    [
      ("label", tests);
      ("gate row", [ ("non-identity row shows the label", `Quick, gate_row_shows_the_display_label) ]);
      ("registry", [ ("labels are injective", `Quick, registry_is_injective) ]);
    ]
