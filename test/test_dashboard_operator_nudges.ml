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
  let dir = temp_dir "masc_nudges" in
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

let nudges json = Yojson.Safe.Util.(json |> member "nudges" |> to_list)
let field_string key json = Yojson.Safe.Util.(json |> member key |> to_string)
let field_bool key json = Yojson.Safe.Util.(json |> member key |> to_bool)

let field_string_list key json =
  Yojson.Safe.Util.(json |> member key |> to_list |> List.map to_string)
;;

let test_structured_operator_nudge () =
  with_room
  @@ fun config ->
  ignore
    (Coord.broadcast
       config
       ~from_agent:"operator"
       ~msg_type:"operator_nudge"
       ~content:
         {|{"kind":"operator_nudge","channel":"approve","to":["sangsu"],"body":"ship it","ack":true}|});
  let json = Dashboard_operator_nudges.json ~config ~limit:10 () in
  let items = nudges json in
  Alcotest.(check int) "count" 1 (List.length items);
  let item = List.hd items in
  Alcotest.(check string) "channel" "approve" (field_string "channel" item);
  Alcotest.(check (list string)) "to" [ "sangsu" ] (field_string_list "to" item);
  Alcotest.(check string) "body" "ship it" (field_string "body" item);
  Alcotest.(check bool) "ack" true (field_bool "ack" item)
;;

let test_tagged_broadcast_nudge () =
  with_room
  @@ fun config ->
  ignore
    (Coord.broadcast
       config
       ~from_agent:"operator"
       ~content:"[nudge:redirect] @rama @scholar focus ar-93ff2489");
  let json = Dashboard_operator_nudges.json ~config ~limit:10 () in
  let items = nudges json in
  Alcotest.(check int) "count" 1 (List.length items);
  let item = List.hd items in
  Alcotest.(check string) "channel" "redirect" (field_string "channel" item);
  Alcotest.(check (list string)) "to" [ "rama"; "scholar" ] (field_string_list "to" item);
  Alcotest.(check string) "body" "focus ar-93ff2489" (field_string "body" item);
  Alcotest.(check bool) "ack" false (field_bool "ack" item)
;;

let test_structured_nudge_preserves_angle_entities () =
  with_room
  @@ fun config ->
  ignore
    (Coord.broadcast
       config
       ~from_agent:"operator"
       ~msg_type:"operator_nudge"
       ~content:
         {|{"kind":"operator_nudge","channel":"hint","body":"<b>&#39;&#039;&apos;&quot;</b>"}|});
  let json = Dashboard_operator_nudges.json ~config ~limit:10 () in
  let items = nudges json in
  Alcotest.(check int) "count" 1 (List.length items);
  let item = List.hd items in
  Alcotest.(check string) "body" "&lt;b&gt;'''\"&lt;/b&gt;" (field_string "body" item)
;;

let test_non_nudge_broadcast_ignored () =
  with_room
  @@ fun config ->
  ignore (Coord.broadcast config ~from_agent:"operator" ~content:"plain update");
  let json = Dashboard_operator_nudges.json ~config ~limit:10 () in
  Alcotest.(check int) "count" 0 (List.length (nudges json))
;;

let () =
  Alcotest.run
    "Dashboard_operator_nudges"
    [ ( "feed"
      , [ Alcotest.test_case
            "structured operator nudge"
            `Quick
            test_structured_operator_nudge
        ; Alcotest.test_case "tagged broadcast nudge" `Quick test_tagged_broadcast_nudge
        ; Alcotest.test_case
            "structured nudge preserves angle entities"
            `Quick
            test_structured_nudge_preserves_angle_entities
        ; Alcotest.test_case
            "non nudge broadcast ignored"
            `Quick
            test_non_nudge_broadcast_ignored
        ] )
    ]
;;
