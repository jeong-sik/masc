(* A broadcast is stored as it was written.

   It used to be HTML-escaped on the way in, so a message containing a double
   quote was persisted as [&quot;] and every consumer read the entity: the TUI,
   the Keeper prompts, the connectors. Models then quoted [&quot;] back out of
   their own transcript into new broadcasts.

   The escape protected nothing. The one consumer that needs escaping does it at
   its own boundary — [Keeper_chat_blocks.escape_html] builds the [html] block
   the dashboard renders — so escaping here only made that boundary escape an
   entity twice and draw it as text. *)

open Masc

module Workspace = Workspace
module Workspace_broadcast = Workspace_broadcast

let check = Alcotest.check

(* A real filesystem backend, because the assertion is about what lands on
   disk. Under the memory backend the durable row this pins does not exist. *)
let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-broadcast-raw-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.) mod 100_000))
  in
  let config = Workspace_core.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "raw-text-probe"));
  Fun.protect
    ~finally:(fun () ->
      try
        ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
      with _ -> ())
    (fun () -> f config)

let broadcast config ~content =
  match
    Workspace.broadcast ~audience:Workspace_broadcast.System_record config
      ~from_agent:"raw-text-probe" ~content
  with
  | Ok delivery -> delivery
  | Error _ -> Alcotest.fail "broadcast was rejected"

(* Every character the old escaper rewrote, in one message. *)
let markup_sample =
  "quoted \"raw\" and 'single' with a < b && c > d"

let test_delivery_carries_what_was_written () =
  with_workspace (fun config ->
      let delivery = broadcast config ~content:markup_sample in
      check Alcotest.string "the delivery echoes the message" markup_sample
        delivery.Workspace_broadcast.content)

(* The durable row is what the TUI, the Keeper prompts and the connectors all
   read, so it is the one that has to hold the original bytes. Read off disk
   rather than through a projection: a projection that re-encoded would hide
   exactly the defect this pins. *)
let stored_content config ~(delivery : Workspace_broadcast.broadcast_delivery) =
  let dir = Workspace_utils_paths_backend.messages_dir config in
  let name =
    Printf.sprintf "%09d_%s_%s_broadcast.json" delivery.seq
      (Common.safe_filename delivery.from_agent)
      delivery.request_id
  in
  let path = Filename.concat dir name in
  let contents =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  match Yojson.Safe.from_string contents with
  | `Assoc fields -> (
      match List.assoc_opt "content" fields with
      | Some (`String value) -> value
      | Some _ | None -> Alcotest.fail "the stored row has no string content")
  | _ -> Alcotest.fail "the stored row is not a JSON object"

let test_durable_row_carries_what_was_written () =
  with_workspace (fun config ->
      let delivery = broadcast config ~content:markup_sample in
      check Alcotest.string "the stored row is the message" markup_sample
        (stored_content config ~delivery))

(* The specific shape that was visible on screen: a quoted phrase inside prose.
   Named separately because this is the one an operator reported. *)
let test_a_quoted_phrase_keeps_its_quotes () =
  with_workspace (fun config ->
      let content = "정정: 아까 \"끝까지 간 적이 없다\" 고 적었는데 틀렸습니다." in
      let delivery = broadcast config ~content in
      check Alcotest.bool "no entity in the delivery" false
        (String_util.contains_substring delivery.Workspace_broadcast.content
           "&quot;");
      check Alcotest.string "the phrase is intact" content
        delivery.Workspace_broadcast.content)

let () =
  Alcotest.run "broadcast-stores-raw-text"
    [ ( "raw text"
      , [ Alcotest.test_case "the delivery carries what was written" `Quick
            test_delivery_carries_what_was_written
        ; Alcotest.test_case "the durable row carries what was written" `Quick
            test_durable_row_carries_what_was_written
        ; Alcotest.test_case "a quoted phrase keeps its quotes" `Quick
            test_a_quoted_phrase_keeps_its_quotes
        ] )
    ]
