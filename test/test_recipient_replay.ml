(* tools/recipient_replay: which input the tool refuses.

   The exit code is the tool's contract with whoever runs it. 0 means every
   line was read. 1 means a line could not be read, and the numbers of that run
   are not a source. 2 means the input is wrong as a whole.

   A line is readable when the server's own decoder reads it. Each row below is
   first put to that decoder, so a row that is supposed to be refused is one
   the server would drop at load, and the tool is not tested against a rule it
   made up. *)

open Alcotest

let tool = "../tools/recipient_replay/main.exe"
let decoder = Masc_board_handlers.Board_votes_json.post_of_yojson

(* A post as the server writes it, addressed to [alice]. The test below checks
   that the server's decoder reads it, so this row cannot drift from the
   format unnoticed. *)
let base_row =
  `Assoc
    [ "id", `String "p-0123456789abcdef0123456789abcdef"
    ; "author", `String "writer"
    ; "title", `String "review"
    ; "body", `String "ask @alice to look"
    ; "post_kind", `String "direct"
    ; "visibility", `String "internal"
    ; "created_at", `Float 1.0
    ; "content_updated_at", `Float 1.0
    ; "updated_at", `Float 1.0
    ; "expires_at", `Float 0.0
    ; "votes_up", `Int 0
    ; "votes_down", `Int 0
    ; "reply_count", `Int 0
    ; "pinned", `Bool false
    ; "audience", `Assoc [ "kind", `String "targets"; "targets", `List [ `String "alice" ] ]
    ]

let fields = function
  | `Assoc fields -> fields
  | _ -> fail "a row is an object"

let row_with key value =
  `Assoc (List.map (fun (name, old) -> name, if String.equal name key then value else old) (fields base_row))

let row_without key = `Assoc (List.remove_assoc key (fields base_row))
let row_plus field = `Assoc (fields base_row @ [ field ])

let audience_row audience = row_with "audience" audience

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let write path text = Out_channel.with_open_text path (fun oc -> output_string oc text)

(* A folder with Keeper settings for [alice], who lists the alias [al]. *)
let with_workspace f =
  let dir = Filename.temp_dir "recipient-replay" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree dir)
    (fun () ->
       let keepers = Filename.concat dir "keepers" in
       Unix.mkdir keepers 0o755;
       write (Filename.concat keepers "alice.toml") "[keeper]\nmention_targets = [\"al\"]\n";
       f ~dir ~keepers)

let run_tool ~keepers ~posts =
  Sys.command
    (Filename.quote_command ~stdout:"/dev/null" ~stderr:"/dev/null" tool
       [ "--keepers"; keepers; "--posts"; posts ])

let exit_code_on ~lines =
  with_workspace (fun ~dir ~keepers ->
    let posts = Filename.concat dir "posts.jsonl" in
    write posts (String.concat "\n" lines ^ "\n");
    run_tool ~keepers ~posts)

let row_text row = Yojson.Safe.to_string row

let test_the_base_row_is_a_server_row () =
  check bool "the server's decoder reads the base row" true
    (Option.is_some (decoder base_row))

let test_a_run_that_reads_every_line_exits_0 () =
  let discoverable = audience_row (`Assoc [ "kind", `String "discoverable" ]) in
  let system = row_with "post_kind" (`String "system") in
  List.iter
    (fun row -> check bool "the server's decoder reads the row" true (Option.is_some (decoder row)))
    [ base_row; discoverable; system ];
  check int "an addressed post, an open one and a system one" 0
    (exit_code_on ~lines:(List.map row_text [ base_row; discoverable; system ]));
  (* Two Keepers listing the alias make that name a lookup failure. It is a
     result of the run, counted in its output, and not a line that was refused. *)
  with_workspace (fun ~dir ~keepers ->
    write (Filename.concat keepers "bob.toml") "[keeper]\nmention_targets = [\"al\"]\n";
    let posts = Filename.concat dir "posts.jsonl" in
    write posts
      (row_text (audience_row (`Assoc [ "kind", `String "targets"; "targets", `List [ `String "al" ] ]))
       ^ "\n");
    check int "a recorded alias that two Keepers list" 0 (run_tool ~keepers ~posts))

(* Rows the server's decoder drops. Each is also checked against the decoder,
   so the list stays a list of rows the server refuses. *)
let refused_rows =
  [ "audience is null", row_with "audience" `Null;
    "audience key is misspelt",
      `Assoc (List.map (fun (name, value) -> (if String.equal name "audience" then "audiance" else name), value)
                (fields base_row));
    "a key the row never has", row_plus ("surprise", `Int 1);
    "a key written twice", row_plus ("pinned", `Bool false);
    "broadcast with a target list",
      audience_row (`Assoc [ "kind", `String "broadcast"; "targets", `List [ `String "alice" ] ]);
    "a target with an empty name",
      audience_row (`Assoc [ "kind", `String "targets"; "targets", `List [ `String "" ] ]);
    "targets that name no one",
      audience_row (`Assoc [ "kind", `String "targets"; "targets", `List [] ]);
    "an audience kind nobody knows", audience_row (`Assoc [ "kind", `String "mentions" ]);
    "targets that are not a list",
      audience_row (`Assoc [ "kind", `String "targets"; "targets", `String "alice" ]);
    "a post kind nobody knows", row_with "post_kind" (`String "robot");
    "a row without a body", row_without "body" ]

let test_a_line_the_server_drops_exits_1 () =
  List.iter
    (fun (label, row) ->
       check bool (label ^ ": the server's decoder drops the row") true (Option.is_none (decoder row));
       check int (label ^ ": exit code") 1 (exit_code_on ~lines:[ row_text row ]))
    refused_rows;
  check int "a line that is not JSON" 1 (exit_code_on ~lines:[ "{\"id\":" ]);
  check int "one refused line beside a readable one" 1
    (exit_code_on ~lines:[ row_text base_row; row_text (row_with "audience" `Null) ])

let test_input_that_is_wrong_as_a_whole_exits_2 () =
  with_workspace (fun ~dir ~keepers ->
    let posts = Filename.concat dir "posts.jsonl" in
    write posts (row_text base_row ^ "\n");
    let empty_posts = Filename.concat dir "empty.jsonl" in
    write empty_posts "\n  \n";
    check int "a posts file with no line" 2 (run_tool ~keepers ~posts:empty_posts);
    check int "a posts file that is missing" 2
      (run_tool ~keepers ~posts:(Filename.concat dir "absent.jsonl"));
    let no_settings = Filename.concat dir "no-settings" in
    Unix.mkdir no_settings 0o755;
    check int "a folder without Keeper settings" 2 (run_tool ~keepers:no_settings ~posts);
    check int "a folder that is missing" 2
      (run_tool ~keepers:(Filename.concat dir "absent") ~posts);
    write (Filename.concat keepers "broken.toml") "[keeper\n";
    check int "Keeper settings that do not parse" 2 (run_tool ~keepers ~posts);
    check int "no arguments" 2
      (Sys.command (Filename.quote_command ~stdout:"/dev/null" ~stderr:"/dev/null" tool [])))

let () =
  run "recipient_replay"
    [ ( "exit code",
        [ test_case "the base row is a server row" `Quick test_the_base_row_is_a_server_row;
          test_case "a run that reads every line exits 0" `Quick
            test_a_run_that_reads_every_line_exits_0;
          test_case "a line the server drops exits 1" `Quick test_a_line_the_server_drops_exits_1;
          test_case "input that is wrong as a whole exits 2" `Quick
            test_input_that_is_wrong_as_a_whole_exits_2 ] ) ]
