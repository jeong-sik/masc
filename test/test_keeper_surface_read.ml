(* RFC-0223 P3 — Keeper_surface_read lane filter + roster fold.

   Pure-module tests: chat_message fixtures in, JSON out. The store
   I/O path (Keeper_chat_store.load) is covered by
   test_keeper_chat_store; the tool dispatch path by
   test_keeper_tool_matrix_cases. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SR = Masc.Keeper_surface_read

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
    kind = Store.Row_kind.Utterance;
    turn_ref = None;
    stream_lifecycle = None;
    approval_lifecycle = None;
    delivery_provenance = None;
  }

let external_speaker ?name id : Store.speaker =
  { speaker_id = Some id; speaker_name = name; speaker_authority = Store.External }

let parse s = Yojson.Safe.from_string s

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
  let json = parse (SR.respond ~surface:"discord" ~limit:50 ~has_more:false ~notes:[] discord_fixture) in
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
  let json = parse (SR.respond ~surface:"discord" ~limit:50 ~has_more:false ~notes:[] discord_fixture) in
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

let test_limit_truncates_messages_not_roster () =
  let json = parse (SR.respond ~surface:"discord" ~limit:2 ~has_more:false ~notes:[] discord_fixture) in
  check int "returned capped" 2 (to_int (member "returned" json));
  check int "lane count still full" 4 (to_int (member "lane_row_count" json));
  check int "roster still full" 2
    (List.length (to_list (member "participants" json)));
  let contents =
    to_list (member "messages" json)
    |> List.map (fun m -> to_string_j (member "content" m))
  in
  check (list string) "last two rows kept"
    [ "second discord message"; "drive-by, no display name" ]
    contents

let test_keeper_own_lines_are_not_participants () =
  let json = parse (SR.respond ~surface:"discord" ~limit:50 ~has_more:false ~notes:[] discord_fixture) in
  let ids =
    to_list (member "participants" json)
    |> List.map (fun p -> to_string_j (member "id" p))
  in
  check bool "assistant line contributed no participant" false
    (List.exists (fun id -> String.equal id "keeper") ids)

let test_blank_surface_is_error () =
  let json = parse (SR.respond ~surface:"  " ~limit:10 ~has_more:false ~notes:[] discord_fixture) in
  check bool "error field present" true (member "error" json <> `Null)

let test_empty_lane_is_success_with_zero_rows () =
  let json = parse (SR.respond ~surface:"slack" ~limit:10 ~has_more:false ~notes:[] discord_fixture) in
  check int "lane empty" 0 (to_int (member "lane_row_count" json));
  check int "no participants" 0
    (List.length (to_list (member "participants" json)))

(* RFC-0228 P1 — paging fields. oldest_ts spans the whole page (the
   dashboard ts=1.0 row), not just the discord lane, so a walk makes
   progress through pages that hold no rows for the requested lane. *)
let test_paging_fields_reflect_page_not_lane () =
  let json =
    parse (SR.respond ~surface:"discord" ~limit:50 ~has_more:true ~notes:[] discord_fixture)
  in
  check bool "has_more passthrough" true
    (Yojson.Safe.Util.to_bool (member "has_more" json));
  check (float 0.0001) "oldest_ts is page-wide" 1.0
    (Yojson.Safe.Util.to_number (member "oldest_ts" json))

(* RFC-0229 P1 — roster union with person notes. *)
let test_notes_annotate_and_resurrect_participants () =
  let notes =
    [ ("98791450001", "deploy owner"); ("00009999", "met three weeks ago") ]
  in
  let json =
    parse
      (SR.respond ~surface:"discord" ~limit:50 ~has_more:false ~notes
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

let test_oldest_ts_absent_when_page_empty () =
  let json =
    parse (SR.respond ~surface:"discord" ~limit:10 ~has_more:false ~notes:[] [])
  in
  check bool "oldest_ts omitted" true (member "oldest_ts" json = `Null)

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
  let json =
    parse
      (SR.respond ~bindings ~surface:"slack" ~limit:10 ~has_more:false ~notes:[]
         discord_fixture)
  in
  check bool "unbound slack is an error" true (member "error" json <> `Null);
  let error = to_string_j (member "error" json) in
  check bool "error names the label" true (contains error "surface slack");
  check bool "error names the binding state" true
    (contains error "no bound channels there (slack: [none]")

let test_unknown_label_is_error_with_page_labels () =
  let json =
    parse
      (SR.respond ~bindings ~surface:"dicsord" ~limit:10 ~has_more:false
         ~notes:[] discord_fixture)
  in
  check bool "typo label is an error" true (member "error" json <> `Null);
  let error = to_string_j (member "error" json) in
  check bool "hint names the page's real labels" true
    (contains error "dashboard, discord")

let test_gate_label_present_on_page_reads () =
  let gate_fixture =
    [ msg ~ts:6.0 ~lane:"calendar" ~role:Store.Role.User "standup moved" ]
  in
  let json =
    parse
      (SR.respond ~bindings ~surface:"calendar" ~limit:10 ~has_more:false
         ~notes:[] gate_fixture)
  in
  check int "gate label present on the page is a legitimate lane" 1
    (to_int (member "lane_row_count" json))

let test_gate_label_absent_from_page_is_error () =
  let json =
    parse
      (SR.respond ~bindings ~surface:"calendar" ~limit:10 ~has_more:false
         ~notes:[] discord_fixture)
  in
  check bool "gate label with no rows anywhere is refused" true
    (member "error" json <> `Null)

(* The page is the newest window. A gate lane whose rows are all older reads
   as an empty page with the cursor the caller pages back with. *)
let test_gate_label_behind_the_page_reads_with_a_cursor () =
  let json =
    parse
      (SR.respond ~bindings ~surface:"calendar" ~limit:10 ~has_more:true
         ~notes:[] discord_fixture)
  in
  check bool "not refused while older rows remain" true (member "error" json = `Null);
  check int "no rows of it on this page" 0 (to_int (member "lane_row_count" json));
  check bool "the cursor to page back is there" true
    (Yojson.Safe.Util.to_bool (member "has_more" json)
     && member "oldest_ts" json <> `Null)

let test_known_lanes_still_read_with_bindings () =
  let json =
    parse
      (SR.respond ~bindings ~surface:"discord" ~limit:50 ~has_more:false
         ~notes:[] discord_fixture)
  in
  check int "bound connector lane reads as before" 4
    (to_int (member "lane_row_count" json));
  let json =
    parse
      (SR.respond ~bindings ~surface:"dashboard" ~limit:50 ~has_more:false
         ~notes:[] discord_fixture)
  in
  check int "core lane reads as before" 1
    (to_int (member "lane_row_count" json))

let () =
  run "keeper_surface_read"
    [
      ( "paging (RFC-0228)",
        [
          test_case "has_more + page-wide oldest_ts" `Quick
            test_paging_fields_reflect_page_not_lane;
          test_case "oldest_ts absent when page empty" `Quick
            test_oldest_ts_absent_when_page_empty;
          test_case "notes annotate and resurrect participants" `Quick
            test_notes_annotate_and_resurrect_participants;
        ] );
      ( "lane filter",
        [
          test_case "excludes other surfaces and unscoped rows" `Quick
            test_lane_filter_excludes_other_surfaces_and_unscoped;
          test_case "limit truncates messages, not roster" `Quick
            test_limit_truncates_messages_not_roster;
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
          test_case "gate label absent from the page is refused" `Quick
            test_gate_label_absent_from_page_is_error;
          test_case "known lanes still read with bindings" `Quick
            test_known_lanes_still_read_with_bindings;
        ] );
    ]
