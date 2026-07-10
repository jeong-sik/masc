open Masc

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

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir "masc_workspace" in
  Fun.protect
    ~finally:(fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.reset config);
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       f config)
;;

let list_field key json = Yojson.Safe.Util.(json |> member key |> to_list)
let string_field key json = Yojson.Safe.Util.(json |> member key |> to_string)

let string_list_field key json =
  Yojson.Safe.Util.(json |> member key |> to_list |> List.map to_string)
;;

let test_workspace_projection_includes_messages_and_mentions () =
  with_workspace
  @@ fun config ->
  ignore (Workspace.bind_session config ~agent_name:"sangsu" ~capabilities:[] ());
  ignore (Workspace.broadcast config ~from_agent:"operator" ~content:"hello @sangsu");
  ignore
    (Workspace.broadcast
       config
       ~from_agent:"sangsu"
       ~msg_type:"status"
       ~content:"work remains in progress");
  let json = Dashboard_workspace.json ~config ~me:"sangsu" ~limit:10 () in
  let workspace = Yojson.Safe.Util.(json |> member "workspace") in
  let messages = list_field "messages" json in
  let inbox = list_field "mentions_inbox" json in
  Alcotest.(check int) "two messages" 2 (List.length messages);
  Alcotest.(check int) "one mention" 1 (List.length inbox);
  Alcotest.(check string) "workspace id" "workspace" (string_field "id" workspace);
  Alcotest.(check bool)
    "participants include sangsu"
    true
    (List.mem "sangsu" (string_list_field "participants" workspace));
  let first = List.hd messages in
  Alcotest.(check string) "first sender" "operator" (string_field "sender" first);
  Alcotest.(check string) "first type" "broadcast" (string_field "type" first);
  Alcotest.(check string) "first relevance" "medium" (string_field "relevance" first);
  Alcotest.(check bool)
    "first expires_at null"
    true
    Yojson.Safe.Util.(first |> member "expires_at" = `Null);
  Alcotest.(check (list string))
    "mentions"
    [ "sangsu" ]
    (string_list_field "mentions" first);
  let second = List.nth messages 1 in
  Alcotest.(check string) "second type" "status" (string_field "type" second);
  Alcotest.(check string) "second body" "work remains in progress"
    (string_field "body" second);
  let inbox_item = List.hd inbox in
  Alcotest.(check string) "inbox sender" "operator" (string_field "sender" inbox_item)
;;

let test_mentions_without_me_returns_all_mentions () =
  with_workspace
  @@ fun config ->
  ignore (Workspace.broadcast config ~from_agent:"operator" ~content:"hello @rama");
  ignore (Workspace.broadcast config ~from_agent:"operator" ~content:"plain broadcast");
  let json = Dashboard_workspace.json ~config ~limit:10 () in
  Alcotest.(check int) "all mentions" 1 (List.length (list_field "mentions_inbox" json))
;;

let () =
  Alcotest.run
    "Dashboard_workspace"
    [ ( "projection"
      , [ Alcotest.test_case
            "workspace projection includes messages and mentions"
            `Quick
            test_workspace_projection_includes_messages_and_mentions
        ; Alcotest.test_case
            "mentions without me returns all mentions"
            `Quick
            test_mentions_without_me_returns_all_mentions
        ] )
    ]
;;
