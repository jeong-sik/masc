open Alcotest
open Masc

module Api = Server_dashboard_http_keeper_api
module K = Keeper_chat_store
module Inspector = Masc_tui_context_inspector

let keeper = "omega"
let original = Ids.Turn_ref.make ~trace_id:"original#session" ~absolute_turn:9
let other = Ids.Turn_ref.make ~trace_id:"other-session" ~absolute_turn:9

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let with_workspace fn =
  let base = Filename.temp_dir "exact-transcript-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let config = Workspace.default_config base in
    check string "isolated fixture workspace" (Unix.realpath base) (Unix.realpath config.base_path);
    let path = K.chat_path ~base_dir:config.base_path ~keeper_name:keeper in
    mkdir_p (Filename.dirname path);
    let lookup query =
      let target = Uri.make ~path:("/api/v1/keepers/" ^ keeper ^ "/turn-transcript") ~query ()
          |> Uri.to_string in
      Api.keeper_turn_transcript_lookup_response ~config ~keeper_name:keeper
        (Httpun.Request.create `GET target) in
    fn path lookup)

let query = [ "turn_ref", [ Ids.Turn_ref.to_string original ] ]

let delivery value =
  match Keeper_chat_delivery_identity.Request_id.of_string value with
  | Ok id -> Keeper_chat_delivery_identity.Operation id
  | Error detail -> fail detail

let row ?turn_ref ?provenance ~id ~role ~content () =
  `Assoc
    ([ "id", `String id; "role", `String role; "content", `String content; "ts", `Float 1. ]
     @ Option.fold ~none:[] ~some:(fun reference -> [ "turn_ref", Ids.Turn_ref.to_yojson reference ]) turn_ref
     @ Option.fold ~none:[] ~some:Keeper_chat_delivery_identity.delivery_provenance_fields provenance)

let write_rows path rows =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    List.iter (fun value -> output_string channel (Yojson.Safe.to_string value ^ "\n")) rows)

let decode json = Inspector.decode_exact_turn_transcript
    ~expected_keeper:keeper ~expected_turn_ref:original json

let test_old_response_and_delivery_user_cross_pages () =
  with_workspace (fun path lookup ->
    let key = delivery "kmsg-original" in
    let terminal : Keeper_chat_delivery_identity.delivery_provenance =
      { delivery_key = key; transcript_slot = Terminal_result } in
    let user key : Keeper_chat_delivery_identity.delivery_provenance =
      { delivery_key = key; transcript_slot = Accepted_user } in
    let channel = open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
      let emit value = output_string channel (Yojson.Safe.to_string value ^ "\n") in
      emit (row ~turn_ref:original ~provenance:terminal ~id:"original-reply"
        ~role:"assistant" ~content:"original response" ());
      (* More than the actual 4 MiB read window, in individually small valid
         rows. The accepted user deliberately comes after the old terminal;
         delivery identity, not physical order, must join it. *)
      let padding = String.make (16 * 1024) 'x' in
      for i = 1 to 512 do
        emit (row ~turn_ref:other ~id:("newer-" ^ string_of_int i)
          ~role:"assistant" ~content:padding ())
      done;
      emit (row ~provenance:(user (delivery "kmsg-foreign")) ~id:"foreign-user"
        ~role:"user" ~content:"unrelated request" ());
      emit (row ~provenance:(user key) ~id:"matched-user" ~role:"user"
        ~content:"accepted original request" ()));
    check bool "fixture exceeds the real byte window" true ((Unix.stat path).st_size > 4 * 1024 * 1024);
    match lookup query with
    | `OK, json ->
        (match decode json with
         | Ok { parts = [ Inspector.Reply_text text ]; source = Exact_turn_transcript } ->
             check string "old exact response" "original response" text
         | Ok _ -> fail "response was omitted, replaced or mislabeled"
         | Error detail -> fail detail);
        (match json with
         | `Assoc fields ->
             (match List.assoc_opt "user" fields with
              | Some (`List [ `Assoc user ]) ->
                  check (option string) "exact delivery user only" (Some "accepted original request")
                    (match List.assoc_opt "content" user with Some (`String text) -> Some text | _ -> None)
              | _ -> fail "delivery join omitted or borrowed the accepted user")
         | _ -> fail "transcript response is not an object")
    | _ -> fail "historical transcript read failed")

let test_unreadable_history_never_becomes_absence () =
  with_workspace (fun path lookup ->
    (match lookup query with
     | `OK, json ->
         (match decode json with
          | Ok { parts = []; source = Exact_turn_transcript } -> ()
          | _ -> fail "readable missing file is not explicit absence")
     | _ -> fail "readable missing file failed");
    let valid = row ~turn_ref:original ~id:"target" ~role:"assistant" ~content:"retained" () in
    let invalid_identity = row ~id:"bad-identity" ~role:"assistant" ~content:"unknown turn" () in
    let invalid_identity = match invalid_identity with
      | `Assoc fields -> `Assoc (("turn_ref", `String "not-a-turn-ref") :: fields)
      | _ -> fail "row fixture changed" in
    write_rows path [ valid; invalid_identity ];
    (match lookup query with `Service_unavailable, _ -> () | _ -> fail "invalid identity became a complete response");
    let user_provenance : Keeper_chat_delivery_identity.delivery_provenance =
      { delivery_key = delivery "kmsg-unreadable"; transcript_slot = Accepted_user } in
    let invalid_provenance = match row ~provenance:user_provenance ~id:"bad-delivery"
        ~role:"user" ~content:"unidentifiable delivery" () with
      | `Assoc fields -> `Assoc (("delivery_key", `Int 0) :: List.remove_assoc "delivery_key" fields)
      | _ -> fail "row fixture changed" in
    write_rows path [ valid; invalid_provenance ];
    (match lookup query with `Service_unavailable, _ -> () | _ -> fail "invalid delivery provenance became a complete response");
    let duplicate_identity = match valid with
      | `Assoc fields -> `Assoc (("turn_ref", Ids.Turn_ref.to_yojson other) :: fields)
      | _ -> fail "row fixture changed" in
    write_rows path [ duplicate_identity ];
    (match lookup query with `Service_unavailable, _ -> () | _ -> fail "duplicate identities became a complete response");
    let channel = open_out_bin path in
    output_string channel "{unfinished"; close_out channel;
    (match lookup query with `Service_unavailable, _ -> () | _ -> fail "incomplete tail became absence");
    Sys.remove path; Unix.mkdir path 0o700;
    match lookup query with
    | `Service_unavailable, _ -> () | _ -> fail "unreadable history became absence")

let test_failure_and_refusal_remain_typed () =
  with_workspace (fun path lookup ->
    let provenance : Keeper_chat_delivery_identity.delivery_provenance =
      { delivery_key = delivery "kmsg-failed"; transcript_slot = Terminal_result } in
    write_rows path [ row ~turn_ref:original ~provenance ~id:"failed"
        ~role:"request_failure" ~content:"provider unavailable" () ];
    (match lookup query with
     | `OK, json ->
         (match decode json with
          | Ok { parts = [ Inspector.Request_failure _ ]; source = Exact_turn_transcript } -> ()
          | _ -> fail "typed transport failure became Keeper speech")
     | _ -> fail "failure transcript could not be observed");
    List.iter (fun invalid -> match lookup invalid with
      | `Bad_request, _ -> () | _ -> fail "invalid or repeated query reached storage")
      [ []; [ "turn_ref", [ "" ] ]; query @ query; [ "turn_ref", [ "not-a-turn-ref" ] ] ])

let test_strict_source_and_version_binding () =
  let base = Keeper_chat_projection.turn_transcript_to_json ~keeper ~turn_ref:original
      { user = []; assistant = [] } in
  let bad_fields = match base with
    | `Assoc fields ->
        [ List.remove_assoc "schema" fields
        ; ("keeper", `String "foreign") :: List.remove_assoc "keeper" fields
        ; ("turn_ref", Ids.Turn_ref.to_yojson other) :: List.remove_assoc "turn_ref" fields
        ; ("found", `Bool true) :: List.remove_assoc "found" fields
        ; ("keeper", `String keeper) :: fields
        ; ("assistant", `List [ `Assoc [ "role", `String "user"; "content", `String "wrong side"; "ts", `Float 1. ] ])
            :: List.remove_assoc "assistant" fields ]
    | _ -> fail "envelope fixture changed" in
  List.iter (fun fields -> match decode (`Assoc fields) with
    | Error _ -> () | Ok _ -> fail "ambiguous, unversioned or foreign transcript accepted") bad_fields

let () = Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Exact retained turn transcript"
    [ "production response helper to TUI decoder",
        [ test_case "old response and delivery user cross pages" `Quick test_old_response_and_delivery_user_cross_pages
        ; test_case "unreadable history is not absence" `Quick test_unreadable_history_never_becomes_absence
        ; test_case "failure and refusal remain typed" `Quick test_failure_and_refusal_remain_typed
        ; test_case "strict source and version binding" `Quick test_strict_source_and_version_binding ] ])
