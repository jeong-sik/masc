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
    (* task-2327: the label pipeline itself is byte-faithful on non-ASCII
       input (bytes >= 0x80 pass through, like capitalize_ascii); the ASCII
       assumption lives at the registry boundary, not inside label. The JS
       port keeps the same behavior by lifting only [a-z] as the first
       letter, so both sides render "über_agent" as "überAgent". *)
    ( "non-ascii passes through"
    , `Quick
    , check "non-ascii" ~input:"über_agent" ~expected:"überAgent" );
  ]

(* task-2245: the tools list mixes wire tool names with skill slugs. A slug
   contains '-' and is already the readable name, so it passes through;
   snake_case and Pascal names still get the Pascal label. *)
let list_check name ~input ~expected () =
  Alcotest.(check string) name expected (Masc.Tool_display.list_label input)

let list_tests =
  [
    ("slug unchanged", `Quick, list_check "slug" ~input:"browser-lanes" ~expected:"browser-lanes");
    ("slug multi dash", `Quick, list_check "slug" ~input:"msx-play" ~expected:"msx-play");
    ("snake labeled", `Quick, list_check "snake" ~input:"keeper_task_done" ~expected:"KeeperTaskDone");
    ("pascal unchanged", `Quick, list_check "pascal" ~input:"WebFetch" ~expected:"WebFetch");
    ("empty string", `Quick, list_check "empty" ~input:"" ~expected:"");
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

(* task-2325 (P3 follow-up to #42979): the dashboard port mirrors this rule
   with JS [toUpperCase], which lifts any Unicode cased letter where
   [capitalize_ascii] lifts ASCII [a-z] only. The two implementations stay a
   faithful mirror as long as the names that reach the label are ASCII — so
   assert that on the same registered-name universe the injectivity check
   walks. A non-ASCII registration turns this red at build time and asks for
   an explicit mirror-rule change on both sides instead of drifting silently. *)
let registry_names_are_ascii () =
  let module Descriptor = Masc.Keeper_tool_descriptor in
  let not_ascii name =
    let rec check i =
      if i >= String.length name then false
      else Char.code (String.get name i) >= 0x80 || check (i + 1)
    in
    check 0
  in
  let registered_names () =
    Descriptor.all_descriptors ()
    |> List.concat_map (fun (d : Descriptor.t) ->
           [ d.Descriptor.public_name; d.Descriptor.internal_name ])
  in
  let bad = registered_names () |> List.filter (fun name -> not_ascii name) in
  match bad with
  | [] -> ()
  | xs ->
      let show name = Printf.sprintf "%S contains non-ASCII bytes" name in
      Alcotest.fail
        ( "tool names must stay ASCII for the JS port mirror "
        ^ "(dashboard/src/lib/tool-display-label.ts): "
        ^ String.concat "; " (List.map show xs))

(* task-2245 (leader's term: the two implementations assert the same input
   table in one PR). The dashboard reads this exact file from its vitest suite
   (dashboard/src/lib/tool-display-label.shared-table.test.ts), so a mapping
   change landing on only one side fails the other side's test too — the same
   togetherness promise as the sync rule (task-2258). *)
let shared_table_rows name =
  let json = Yojson.Safe.from_file ("fixtures/" ^ name) in
  match json with
  | `List rows ->
      List.map
        (fun row ->
          match row with
          | `Assoc fields ->
              let find key =
                match List.assoc_opt key fields with
                | Some (`String value) -> value
                | _ -> Alcotest.failf "the shared table row misses %s" key
              in
              (find "name", find "label")
          | _ -> Alcotest.fail "the shared table row is not an object")
        rows
  | _ -> Alcotest.fail "the shared table is not a list"

let shared_table () =
  let rows = shared_table_rows "tool-display-labels.json" in
  Alcotest.(check bool) "the shared table is not empty" true (List.length rows > 0);
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string) ("shared table: " ^ name) expected
        (Masc.Tool_display.list_label name))
    rows

let () =
  Alcotest.run "tool_display"
    [
      ("label", tests);
      ("list label", list_tests);
      ("gate row", [ ("non-identity row shows the label", `Quick, gate_row_shows_the_display_label) ]);
      ("registry", [ ("labels are injective", `Quick, registry_is_injective); ("names are ascii", `Quick, registry_names_are_ascii) ]);
      ( "shared table"
      , [ ("the dashboard port maps the shared table identically", `Quick, shared_table) ] );
    ]
