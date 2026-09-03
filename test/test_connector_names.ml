(* What the store promises: a name seen once comes back, the newest one wins,
   and an empty answer is never recorded as an answer. *)

open Alcotest
module Names = Masc.Connector_names

let with_temp_base f =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-connector-people-%d-%f" (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match Sys.is_directory path with
        | true ->
          Array.iter
            (fun entry -> remove (Filename.concat path entry))
            (Sys.readdir path);
          Unix.rmdir path
        | false -> Sys.remove path
        | exception Sys_error _ -> ()
      in
      try remove base_path with _ -> ())
    (fun () -> f base_path)

let test_a_name_comes_back () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vincent" ();
  check (option string) "the name it was told" (Some "Vincent")
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1")

let test_an_unseen_id_says_nothing () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vincent" ();
  check (option string) "someone else is not Vincent" None
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U2")

(* Connectors do not share an id space, and a Discord snowflake could collide
   with nothing in Slack -- but the store must not be the reason they could. *)
let test_connectors_do_not_share_names () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vincent" ();
  check (option string) "discord does not read slack's answer" None
    (Names.recall ~base_dir ~connector:"discord" ~scope:Names.Person ~id:"U1")

(* Someone renames themselves. The newest answer is the one to speak. *)
let test_the_newest_name_wins () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vincent" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vince" ();
  check (option string) "the rename is what comes back" (Some "Vince")
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1")

let test_repeating_a_name_does_not_grow_the_log () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1"
    ~name:"Vincent" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1"
    ~name:"Vincent" ();
  let path =
    Filename.concat base_dir ".masc/connector_names/slack-people.jsonl"
  in
  let rows =
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  check int "one durable row for one observed name" 1 (List.length rows)

(* An empty name is the absence this store exists to answer. Recording it
   would let a blank overwrite a name and then be spoken as one. *)
let test_a_blank_is_not_an_answer () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"Vincent" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1" ~name:"  " ();
  check (option string) "the blank did not overwrite the name" (Some "Vincent")
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1");
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"  " ~name:"Nobody" ();
  check (option string) "a blank id records nothing" None
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"  ")

(* People and channels share the store and must not share an id space. A
   Slack channel and a Slack user could in principle be told apart by their
   prefix; the store must not be the reason they could not. *)
let test_people_and_channels_do_not_collide () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"X1"
    ~name:"Vincent" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Channel ~id:"X1"
    ~name:"kinossam-dev" ();
  check (option string) "the person keeps their name" (Some "Vincent")
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"X1");
  check (option string) "and the channel keeps its own" (Some "kinossam-dev")
    (Names.recall ~base_dir ~connector:"slack" ~scope:Names.Channel ~id:"X1")

let test_servers_have_their_own_id_space () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"discord" ~scope:Names.Server ~id:"X1"
    ~name:"MASC Lab" ();
  Names.remember ~base_dir ~connector:"discord" ~scope:Names.Channel ~id:"X1"
    ~name:"general" ();
  check (option string) "server name" (Some "MASC Lab")
    (Names.recall ~base_dir ~connector:"discord" ~scope:Names.Server ~id:"X1");
  check (option string) "channel name" (Some "general")
    (Names.recall ~base_dir ~connector:"discord" ~scope:Names.Channel ~id:"X1")

let test_entries_project_latest_names_in_id_order () =
  with_temp_base @@ fun base_dir ->
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U2"
    ~name:"Second" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U1"
    ~name:"First" ();
  Names.remember ~base_dir ~connector:"slack" ~scope:Names.Person ~id:"U2"
    ~name:"Renamed" ();
  check (list (pair string string)) "latest sorted projection"
    [ ("U1", "First"); ("U2", "Renamed") ]
    (Names.entries ~base_dir ~connector:"slack" ~scope:Names.Person)

let () =
  run "connector names"
    [ ( "recall"
      , [ test_case "a name comes back" `Quick test_a_name_comes_back
        ; test_case "an unseen id says nothing" `Quick
            test_an_unseen_id_says_nothing
        ; test_case "connectors do not share names" `Quick
            test_connectors_do_not_share_names
        ; test_case "the newest name wins" `Quick test_the_newest_name_wins
        ; test_case "repeating a name does not grow the log" `Quick
            test_repeating_a_name_does_not_grow_the_log
        ; test_case "a blank is not an answer" `Quick
            test_a_blank_is_not_an_answer
        ; test_case "people and channels do not collide" `Quick
            test_people_and_channels_do_not_collide
        ; test_case "servers have their own id space" `Quick
            test_servers_have_their_own_id_space
        ; test_case "entries expose latest names in ID order" `Quick
            test_entries_project_latest_names_in_id_order
        ] )
    ]
