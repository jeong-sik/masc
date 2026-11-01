(* RFC-0223 P3 — Keeper_surface_read lane filter + roster fold.

   Pure-module tests: chat_message fixtures in, JSON out. The store
   I/O path (Keeper_chat_store.load) is covered by
   test_keeper_chat_store; the tool dispatch path by
   test_keeper_tool_matrix_cases. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SR = Masc.Keeper_surface_read
module Cursor = Masc.Keeper_chat_history_page

let fixture_cursor =
  let path = Filename.temp_file "surface-page-cursor" ".jsonl" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let channel = open_out path in
    Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
      output_string channel "{\"id\":\"first\"}\n{\"id\":\"last\"}\n");
    match Cursor.read ~path ~owner:"surface-projection-test" ~max_rows:1 () with
    | Ok { next_cursor = Some cursor; _ } -> cursor
    | Ok _ | Error _ -> fail "fixture must produce a physical cursor")

let respond ?bindings ~surface ~cursor ~next_cursor ~notes history_messages =
  SR.respond ?bindings ~surface ~cursor ~notes
    { Store.history_messages; next_cursor }

let msg ~ts ?lane ?speaker ~role content : Store.chat_message =
  let surface =
    Option.map
      (fun label -> Masc.Surface_ref.Gate { label; address = [] })
      lane
  in
  {
    id = "test-msg";
    role;
    content;
    ts;
    attachments = None;
    tool_call_id = None;
    execution_id = None;
    tool_call_name = None;
    surface;
    conversation_id = None;
    external_message_id = None;
    workspace_id = None;
    speaker;
    audio = None;
    blocks = None;
    mentions = [];
    turn_ref = None;
    stream_lifecycle = None;
    approval_lifecycle = None;
    delivery_provenance = None;
  }

let external_speaker ?name id : Store.speaker =
  { speaker_id = Some id; speaker_name = name; speaker_authority = Store.External }

let parse s = Yojson.Safe.from_string s

let answered = function
  | Ok body -> parse body
  | Error refusal -> failf "expected an answer, got the refusal %S" refusal

let refused = function
  | Error refusal -> refusal
  | Ok body -> failf "expected a refusal, got %s" body

let member key json = Yojson.Safe.Util.member key json

let to_list json = Yojson.Safe.Util.to_list json

let to_int json = Yojson.Safe.Util.to_int json

let to_string_j json = Yojson.Safe.Util.to_string json

let discord_fixture : Store.chat_message list =
  [
    msg ~ts:1.0 ~lane:"dashboard" ~role:Store.Role.User "hello from owner";
    msg ~ts:2.0 ~lane:"discord"
      ~speaker:(external_speaker ~name:"minsu_old" "98791450001")
      ~role:Store.Role.User "first discord message";
    msg ~ts:2.5 ~lane:"discord" ~role:Store.Role.Assistant "keeper reply";
    msg ~ts:3.0 ~lane:"discord"
      ~speaker:(external_speaker ~name:"Minsu" "98791450001")
      ~role:Store.Role.User "second discord message";
    msg ~ts:4.0 ~lane:"discord"
      ~speaker:(external_speaker "55500001111")
      ~role:Store.Role.User "drive-by, no display name";
    msg ~ts:5.0 ~role:Store.Role.User "unscoped row";
  ]

let test_lane_filter_excludes_other_surfaces_and_unscoped () =
  let json = answered (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes:[] discord_fixture) in
  check int "lane rows" 4 (to_int (member "lane_row_count" json));
  check int "returned" 4 (to_int (member "returned" json));
  let contents =
    to_list (member "messages" json)
    |> List.map (fun m -> to_string_j (member "content" m))
  in
  check (list string) "chronological lane contents"
    [
      "first discord message";
      "keeper reply";
      "second discord message";
      "drive-by, no display name";
    ]
    contents

let test_roster_groups_by_id_latest_name_wins () =
  let json = answered (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes:[] discord_fixture) in
  let participants = to_list (member "participants" json) in
  check int "two participants" 2 (List.length participants);
  let find id =
    List.find
      (fun p -> String.equal (to_string_j (member "id" p)) id)
      participants
  in
  let minsu = find "98791450001" in
  check string "latest name wins" "Minsu" (to_string_j (member "name" minsu));
  check int "message_count" 2 (to_int (member "message_count" minsu));
  check (float 0.001) "first_seen" 2.0
    (Yojson.Safe.Util.to_number (member "first_seen" minsu));
  check (float 0.001) "last_seen" 3.0
    (Yojson.Safe.Util.to_number (member "last_seen" minsu));
  let driveby = find "55500001111" in
  check bool "no name field when never given" true
    (member "name" driveby = `Null);
  (* Sorted by last_seen descending: the drive-by (4.0) outranks Minsu (3.0). *)
  check string "roster order: most recent first" "55500001111"
    (to_string_j (member "id" (List.hd participants)))

let test_page_preserves_all_lane_rows () =
  let json = answered (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes:[] discord_fixture) in
  check int "all page rows returned" 4 (to_int (member "returned" json));
  check int "lane count still full" 4 (to_int (member "lane_row_count" json));
  check int "roster still full" 2
    (List.length (to_list (member "participants" json)));
  let contents =
    to_list (member "messages" json)
    |> List.map (fun m -> to_string_j (member "content" m))
  in
  check (list string) "every lane row kept"
    [ "first discord message"; "keeper reply"; "second discord message"; "drive-by, no display name" ]
    contents

let test_keeper_own_lines_are_not_participants () =
  let json = answered (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes:[] discord_fixture) in
  let ids =
    to_list (member "participants" json)
    |> List.map (fun p -> to_string_j (member "id" p))
  in
  check bool "assistant line contributed no participant" false
    (List.exists (fun id -> String.equal id "keeper") ids)

let test_blank_surface_is_error () =
  let refusal =
    refused (respond ~surface:"  " ~cursor:None ~next_cursor:None ~notes:[] discord_fixture)
  in
  check bool "the refusal says surface is required" true
    (String.length refusal > 0 && String.sub refusal 0 7 = "surface")

let test_empty_lane_is_success_with_zero_rows () =
  let json = answered (respond ~surface:"slack" ~cursor:None ~next_cursor:None ~notes:[] discord_fixture) in
  check int "lane empty" 0 (to_int (member "lane_row_count" json));
  check int "no participants" 0
    (List.length (to_list (member "participants" json)))

(* The physical store cursor spans the whole page, including rows outside
   the requested lane. The projection must publish it unchanged. *)
let test_paging_fields_reflect_page_not_lane () =
  let json =
    answered (respond ~surface:"discord" ~cursor:None ~next_cursor:(Some fixture_cursor) ~notes:[] discord_fixture)
  in
  check bool "has_more passthrough" true
    (Yojson.Safe.Util.to_bool (member "has_more" json));
  check string "cursor is the store cursor" (Cursor.cursor_to_string fixture_cursor)
    (to_string_j (member "next_cursor" json))

(* RFC-0229 P1 — roster union with person notes. *)
let test_notes_annotate_and_resurrect_participants () =
  let notes =
    [ ("98791450001", "deploy owner"); ("00009999", "met three weeks ago") ]
  in
  let json =
    answered
      (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes
         discord_fixture)
  in
  let participants = to_list (member "participants" json) in
  let find id =
    List.find
      (fun p -> to_string_j (member "id" p) = id)
      participants
  in
  check string "lane participant annotated" "deploy owner"
    (to_string_j (member "note" (find "98791450001")));
  let ghost = find "00009999" in
  check string "note-only participant resurrected" "met three weeks ago"
    (to_string_j (member "note" ghost));
  check int "note-only has no sightings" 0
    (to_int (member "message_count" ghost));
  check bool "unnoted participant carries no note field" true
    (member "note" (find "55500001111") = `Null)

let test_cursor_absent_when_page_empty () =
  let json =
    answered (respond ~surface:"discord" ~cursor:None ~next_cursor:None ~notes:[] [])
  in
  check bool "prefix exhausted" true (member "next_cursor" json = `Null)

(* Task-1596 — with binding knowledge, a label the runtime can prove
   wrong is refused with the post-shaped error JSON instead of a silent
   zero-row page. Without bindings the cases above keep the pure,
   unverified projection. *)
let bindings = { SR.slack = []; discord = [ "9876543210" ] }

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let test_unbound_connector_label_is_error () =
  let error =
    refused
      (respond ~bindings ~surface:"slack" ~cursor:None ~next_cursor:None ~notes:[]
         discord_fixture)
  in
  check bool "error names the label" true (contains error "surface slack");
  check bool "error names the binding state" true
    (contains error "no bound channels there (slack: [none]")

let test_unknown_label_is_error_with_page_labels () =
  let error =
    refused
      (respond ~bindings ~surface:"dicsord" ~cursor:None ~next_cursor:None
         ~notes:[] discord_fixture)
  in
  check bool "hint names the page's real labels" true
    (contains error "dashboard, discord")

let test_gate_label_present_on_page_reads () =
  let gate_fixture =
    [ msg ~ts:6.0 ~lane:"calendar" ~role:Store.Role.User "standup moved" ]
  in
  let json =
    answered
      (respond ~bindings ~surface:"calendar" ~cursor:None ~next_cursor:None
         ~notes:[] gate_fixture)
  in
  check int "gate label present on the page is a legitimate lane" 1
    (to_int (member "lane_row_count" json))

let test_gate_label_absent_from_page_is_error () =
  let error =
    refused
      (respond ~bindings ~surface:"calendar" ~cursor:None ~next_cursor:None
         ~notes:[] discord_fixture)
  in
  check bool "gate label with no rows anywhere is refused" true
    (contains error "surface calendar matches no lane")

(* The page is the newest window. A gate lane whose rows are all older reads
   as an empty page with the cursor the caller pages back with. *)
let test_gate_label_behind_the_page_reads_with_a_cursor () =
  let json =
    answered
      (respond ~bindings ~surface:"calendar" ~cursor:None ~next_cursor:(Some fixture_cursor)
         ~notes:[] discord_fixture)
  in
  check int "no rows of it on this page" 0 (to_int (member "lane_row_count" json));
  check bool "the cursor to page back is there" true
    (Yojson.Safe.Util.to_bool (member "has_more" json)
     && member "next_cursor" json <> `Null)

(* Paging back with [cursor] until [has_more] is false ends on the oldest
   page. That page is not the whole history either: the lane the caller just
   read may sit on a newer page, so its absence here is an empty page. *)
let test_gate_label_absent_from_the_oldest_page_reads () =
  let json =
    answered
      (respond ~bindings ~surface:"calendar" ~cursor:(Some fixture_cursor)
         ~next_cursor:None ~notes:[] discord_fixture)
  in
  check int "no rows of it on this page" 0 (to_int (member "lane_row_count" json))

let test_known_lanes_still_read_with_bindings () =
  let json =
    answered
      (respond ~bindings ~surface:"discord" ~cursor:None ~next_cursor:None
         ~notes:[] discord_fixture)
  in
  check int "bound connector lane reads as before" 4
    (to_int (member "lane_row_count" json));
  let json =
    answered
      (respond ~bindings ~surface:"dashboard" ~cursor:None ~next_cursor:None
         ~notes:[] discord_fixture)
  in
  check int "core lane reads as before" 1
    (to_int (member "lane_row_count" json))

let () =
  run "keeper_surface_read"
    [
      ( "paging (RFC-0228)",
        [
          test_case "has_more + physical store cursor" `Quick
            test_paging_fields_reflect_page_not_lane;
          test_case "cursor absent when page empty" `Quick
            test_cursor_absent_when_page_empty;
          test_case "notes annotate and resurrect participants" `Quick
            test_notes_annotate_and_resurrect_participants;
        ] );
      ( "lane filter",
        [
          test_case "excludes other surfaces and unscoped rows" `Quick
            test_lane_filter_excludes_other_surfaces_and_unscoped;
          test_case "page rows are never hidden from the cursor" `Quick
            test_page_preserves_all_lane_rows;
          test_case "blank surface is an error" `Quick
            test_blank_surface_is_error;
          test_case "empty lane is success with zero rows" `Quick
            test_empty_lane_is_success_with_zero_rows;
        ] );
      ( "roster",
        [
          test_case "groups by id, latest name wins" `Quick
            test_roster_groups_by_id_latest_name_wins;
          test_case "keeper's own lines are not participants" `Quick
            test_keeper_own_lines_are_not_participants;
        ] );
      ( "refused labels (task-1596)",
        [
          test_case "unbound connector label is an error" `Quick
            test_unbound_connector_label_is_error;
          test_case "unknown label names the page's labels" `Quick
            test_unknown_label_is_error_with_page_labels;
          test_case "gate label present on the page reads" `Quick
            test_gate_label_present_on_page_reads;
          test_case "gate label behind the page reads with a cursor" `Quick
            test_gate_label_behind_the_page_reads_with_a_cursor;
          test_case "gate label absent from the oldest page reads" `Quick
            test_gate_label_absent_from_the_oldest_page_reads;
          test_case "gate label absent from the page is refused" `Quick
            test_gate_label_absent_from_page_is_error;
          test_case "known lanes still read with bindings" `Quick
            test_known_lanes_still_read_with_bindings;
        ] );
    ]
