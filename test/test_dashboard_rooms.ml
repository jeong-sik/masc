open Masc_mcp

let temp_dir prefix =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d"
         prefix
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let with_room f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir "masc_rooms" in
  Fun.protect
    ~finally:(fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.reset config);
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       let config = Coord.default_config dir in
       ignore (Coord.init config ~agent_name:(Some "operator"));
       f config)
;;

let list_field key json = Yojson.Safe.Util.(json |> member key |> to_list)
let string_field key json = Yojson.Safe.Util.(json |> member key |> to_string)

let string_list_field key json =
  Yojson.Safe.Util.(json |> member key |> to_list |> List.map to_string)
;;

let test_rooms_projection_includes_messages_and_mentions () =
  with_room
  @@ fun config ->
  ignore (Coord.join config ~agent_name:"sangsu" ~capabilities:[] ());
  ignore (Coord.broadcast config ~from_agent:"operator" ~content:"hello @sangsu");
  ignore
    (Coord.broadcast
       config
       ~from_agent:"sangsu"
       ~msg_type:"state_block:plan"
       ~content:"{\"phase\":\"next\"}");
  let json = Dashboard_rooms.json ~config ~me:"sangsu" ~limit:10 () in
  let rooms = list_field "rooms" json in
  let messages = list_field "messages" json in
  let inbox = list_field "mentions_inbox" json in
  Alcotest.(check int) "one default room" 1 (List.length rooms);
  Alcotest.(check int) "two messages" 2 (List.length messages);
  Alcotest.(check int) "one mention" 1 (List.length inbox);
  let room = List.hd rooms in
  Alcotest.(check string) "room id" "default" (string_field "id" room);
  Alcotest.(check bool)
    "participants include sangsu"
    true
    (List.mem "sangsu" (string_list_field "participants" room));
  let first = List.hd messages in
  Alcotest.(check string) "first sender" "operator" (string_field "sender" first);
  Alcotest.(check (list string))
    "mentions"
    [ "sangsu" ]
    (string_list_field "mentions" first);
  let second = List.nth messages 1 in
  Alcotest.(check string) "block kind" "plan" (string_field "block_kind" second);
  let inbox_item = List.hd inbox in
  Alcotest.(check string) "inbox sender" "operator" (string_field "sender" inbox_item)
;;

let test_mentions_without_me_returns_all_mentions () =
  with_room
  @@ fun config ->
  ignore (Coord.broadcast config ~from_agent:"operator" ~content:"hello @rama");
  ignore (Coord.broadcast config ~from_agent:"operator" ~content:"plain broadcast");
  let json = Dashboard_rooms.json ~config ~limit:10 () in
  Alcotest.(check int) "all mentions" 1 (List.length (list_field "mentions_inbox" json))
;;

let () =
  Alcotest.run
    "Dashboard_rooms"
    [ ( "projection"
      , [ Alcotest.test_case
            "rooms projection includes messages and mentions"
            `Quick
            test_rooms_projection_includes_messages_and_mentions
        ; Alcotest.test_case
            "mentions without me returns all mentions"
            `Quick
            test_mentions_without_me_returns_all_mentions
        ] )
    ]
;;
