(* RFC-0223 P3 — Keeper_surface_read lane filter + roster fold.

   Pure-module tests: chat_message fixtures in, JSON out. The store
   I/O path (Keeper_chat_store.load) is covered by
   test_keeper_chat_store; the tool dispatch path by
   test_keeper_tool_matrix_cases. *)

open Alcotest

module Store = Masc.Keeper_chat_store
module SR = Masc.Keeper_surface_read

let msg ?ts ?source ?speaker ~role content : Store.chat_message =
  {
    id = "test-msg";
    role;
    content;
    ts;
    attachments = None;
    tool_call_id = None;
    tool_call_name = None;
    source;
    surface = None;
    conversation_id = None;
    external_message_id = None;
    queue_receipt_ids = [];
    speaker;
    audio = None;
    blocks = None;
    mentions = [];
    kind = Store.Row_kind.Utterance;
    turn_ref = None;
    stream_lifecycle = None;
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
    msg ~ts:1.0 ~source:"dashboard" ~role:Store.Role.User "hello from owner";
    msg ~ts:2.0 ~source:"discord"
      ~speaker:(external_speaker ~name:"minsu_old" "98791450001")
      ~role:Store.Role.User "first discord message";
    msg ~ts:2.5 ~source:"discord" ~role:Store.Role.Assistant "keeper reply";
    msg ~ts:3.0 ~source:"discord"
      ~speaker:(external_speaker ~name:"Minsu" "98791450001")
      ~role:Store.Role.User "second discord message";
    msg ~ts:4.0 ~source:"discord"
      ~speaker:(external_speaker "55500001111")
      ~role:Store.Role.User "drive-by, no display name";
    msg ~role:Store.Role.User "legacy row without source";
  ]

let test_lane_filter_excludes_other_sources_and_legacy () =
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

let test_oldest_ts_absent_when_page_unstamped () =
  let json =
    parse
      (SR.respond ~surface:"discord" ~limit:10 ~has_more:false ~notes:[]
         [ msg ~source:"discord" ~role:Store.Role.User "no ts row" ])
  in
  check bool "oldest_ts omitted" true (member "oldest_ts" json = `Null)

let () =
  run "keeper_surface_read"
    [
      ( "paging (RFC-0228)",
        [
          test_case "has_more + page-wide oldest_ts" `Quick
            test_paging_fields_reflect_page_not_lane;
          test_case "oldest_ts absent when page unstamped" `Quick
            test_oldest_ts_absent_when_page_unstamped;
          test_case "notes annotate and resurrect participants" `Quick
            test_notes_annotate_and_resurrect_participants;
        ] );
      ( "lane filter",
        [
          test_case "excludes other sources and legacy rows" `Quick
            test_lane_filter_excludes_other_sources_and_legacy;
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
    ]
