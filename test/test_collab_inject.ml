(** Stack 4 tests for RFC-0471: guest injection against the real keeper
    registry and chat store — prompt submit lands a durable queued
    operation with collab provenance, abort names the exact operation,
    transcript fetches page and render history. *)

open Alcotest

module Inject = Server_collab_inject
module Store = Masc.Keeper_chat_store
module Registry = Masc.Keeper_owner_registry
module Operation = Keeper_chat_operation
module Payload = Masc.Keeper_chat_operation_payload
module Delivery = Keeper_chat_delivery_identity

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let temp_dir () =
  let dir = Filename.temp_file "collab-inject-test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  dir
;;

(* Mirror test_keeper_waiting_inventory: a bare workspace plus an owner
   inventory with no executor (queue-only; nothing runs turns). *)
let with_registry f =
  Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let base_dir = temp_dir () in
      Eio.Switch.run (fun sw ->
          Eio.Switch.on_release sw (fun () -> rm_rf base_dir);
          let config = Workspace_core.default_config base_dir in
          ignore (Workspace_core.init config ~agent_name:(Some "test"));
          (match
             Registry.install_from_store ~sw ~operation_runner:None
               ~on_turn_slot_released:None config
           with
           | Ok _ -> ()
           | Error error ->
             fail
               ("owner inventory install failed: "
                ^ Registry.install_error_to_string error));
          f ~base_dir))
;;

let ensure_keeper ~base_dir keeper_name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ ("name", `String keeper_name) ])
    with
    | Ok meta -> meta
    | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
  in
  match Registry.create_meta ~base_path:base_dir meta with
  | Ok (Some _) -> ()
  | Ok None -> fail "owner create did not persist keeper meta"
  | Error err ->
    fail ("owner create failed: " ^ Registry.command_error_to_string err)
;;

let room = String.make 16 '\x07'

let check_queued ~base_dir ~keeper op_id =
  match Registry.list_queued_operations ~base_path:base_dir ~keeper_name:keeper
          ~after_sequence:None ~limit:16
  with
  | Error error ->
    fail ("list queued: " ^ Registry.command_error_to_string error)
  | Ok ops ->
    let found =
      List.find_opt
        (fun op ->
          String.equal
            (Operation.Operation_id.to_string op.Operation.operation_id)
            op_id)
        ops
    in
    (match found with
     | None -> fail "submitted op not queued"
     | Some op -> op)
;;

let test_submit_prompt_queues () =
  with_registry (fun ~base_dir ->
      ensure_keeper ~base_dir "kinject";
      match
        Inject.submit_prompt ~base_dir ~keeper:"kinject" ~room ~peer:3
          ~label:(Some "Guest Three") ~text:"  hello keeper  "
      with
      | Error err -> fail (Inject.prompt_error_to_string err)
      | Ok op_id ->
        check bool "collab prefix" true
          (String.starts_with ~prefix:"collab-" op_id);
        let op = check_queued ~base_dir ~keeper:"kinject" op_id in
        (match op.Operation.input with
         | None -> fail "queued op has no input"
         | Some input -> (
           match Payload.input_of_json input with
           | Error detail -> fail detail
           | Ok decoded ->
             check string "trimmed prompt" "hello keeper"
               decoded.Payload.message));
        (match Payload.source_of_json op.Operation.source with
         | Error detail -> fail detail
         | Ok decoded ->
           check string "channel" "collab" decoded.Payload.channel;
           check string "guest speaker" "guest-3"
             decoded.Payload.channel_user_id;
           check string "guest name" "Guest Three"
             decoded.Payload.channel_user_name;
           check bool "room workspace" true
             (not (String.equal decoded.Payload.channel_workspace_id ""))))
;;

let test_submit_empty_rejected () =
  with_registry (fun ~base_dir ->
      ensure_keeper ~base_dir "kinject-empty";
      (match
         Inject.submit_prompt ~base_dir ~keeper:"kinject-empty" ~room ~peer:1
           ~label:None ~text:"   \n  "
       with
       | Error Inject.Prompt_empty -> ()
       | Error err -> fail (Inject.prompt_error_to_string err)
       | Ok op_id -> fail ("empty prompt queued as " ^ op_id));
      match
        Registry.list_queued_operations ~base_path:base_dir
          ~keeper_name:"kinject-empty" ~after_sequence:None ~limit:16
      with
      | Error error ->
        fail ("list queued: " ^ Registry.command_error_to_string error)
      | Ok ops -> check int "nothing queued" 0 (List.length ops))
;;

let test_submit_too_large () =
  with_registry (fun ~base_dir ->
      ensure_keeper ~base_dir "kbig";
      let over = String.make (Inject.max_prompt_bytes + 1) 'x' in
      (match
         Inject.submit_prompt ~base_dir ~keeper:"kbig" ~room ~peer:1
           ~label:None ~text:over
       with
       | Error (Inject.Prompt_too_large bytes) ->
         check int "carries size" (Inject.max_prompt_bytes + 1) bytes
       | Error err -> fail (Inject.prompt_error_to_string err)
       | Ok op_id -> fail ("oversize prompt queued as " ^ op_id));
      (match
         Registry.list_queued_operations ~base_path:base_dir ~keeper_name:"kbig"
           ~after_sequence:None ~limit:16
       with
       | Error error ->
         fail ("list queued: " ^ Registry.command_error_to_string error)
       | Ok ops -> check int "nothing queued" 0 (List.length ops));
      (* The boundary byte itself still queues. *)
      let edge = String.make Inject.max_prompt_bytes 'y' in
      (match
         Inject.submit_prompt ~base_dir ~keeper:"kbig" ~room ~peer:1
           ~label:None ~text:edge
       with
       | Error err -> fail (Inject.prompt_error_to_string err)
       | Ok op_id ->
         check bool "edge prefix" true
           (String.starts_with ~prefix:"collab-" op_id)))
;;

let test_abort_paths () =
  with_registry (fun ~base_dir ->
      ensure_keeper ~base_dir "kabort";
      check
        bool
        "no tracked op is silent"
        true
        (match
           Inject.abort_current ~base_dir ~keeper:"kabort" ~latest_op:None
         with
         | Inject.Nothing_running -> true
         | _ -> false);
      let op_id =
        match
          Inject.submit_prompt ~base_dir ~keeper:"kabort" ~room ~peer:2
            ~label:None ~text:"doomed turn"
        with
        | Error err -> fail (Inject.prompt_error_to_string err)
        | Ok op_id -> op_id
      in
      (* No executor runs in the test, so the queued op is never current. *)
      check
        bool
        "queued op aborts to nothing-running"
        true
        (match
           Inject.abort_current ~base_dir ~keeper:"kabort"
             ~latest_op:(Some op_id)
         with
         | Inject.Nothing_running -> true
         | _ -> false);
      (* A tracked id that parses as no operation id is a failure, never
         a blind interrupt. *)
      check
        bool
        "malformed tracked id fails"
        true
        (match
           Inject.abort_current ~base_dir ~keeper:"kabort"
             ~latest_op:(Some "not an operation id !!!")
         with
         | Inject.Abort_failed _ -> true
         | _ -> false);
      (* An interrupt the inventory refuses (here: a keeper it never saw)
         surfaces as a failure, never as a silent nothing-running: the
         caller must not read "nothing was running" when the keeper
         itself was unreachable. *)
      check
        bool
        "unknown keeper abort fails loud"
        true
        (match
           Inject.abort_current ~base_dir ~keeper:"kabort-ghost"
             ~latest_op:(Some op_id)
         with
         | Inject.Abort_failed _ -> true
         | _ -> false))
;;

let delivery_key n =
  match Delivery.Request_id.of_string (Printf.sprintf "transcript-%d" n) with
  | Error detail -> fail detail
  | Ok id -> Delivery.Operation id
;;

let append_user ~base_dir ~keeper n content =
  match
    Store.append_user_message_once ~base_dir ~keeper_name:keeper
      ~delivery_key:(delivery_key n)
      ~content ()
  with
  | Error detail -> fail detail
  | Ok _ -> ()
;;

let append_assistant ~base_dir ~keeper n content =
  match
    Store.append_assistant_message_once ~base_dir ~keeper_name:keeper
      ~delivery_key:(delivery_key (100000 + n))
      ~content ()
  with
  | Error detail -> fail detail
  | Ok _ -> ()
;;

let contains needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h
    then None
    else if String.sub haystack i n = needle
    then Some i
    else loop (i + 1)
  in
  loop 0
;;

(* Fetch runs its page walk in a systhread, so it needs an Eio context;
   the chat store itself needs no registry. *)
let with_eio_base_dir f =
  Eio_main.run (fun _env ->
      let base_dir = temp_dir () in
      Fun.protect ~finally:(fun () -> rm_rf base_dir) (fun () -> f ~base_dir))
;;

let test_fetch_transcript () =
  with_eio_base_dir (fun ~base_dir ->
      append_user ~base_dir ~keeper:"kscroll" 1 "first question";
      append_assistant ~base_dir ~keeper:"kscroll" 2 "first answer";
      append_user ~base_dir ~keeper:"kscroll" 3 "second question";
      let full =
        Inject.fetch_transcript ~base_dir ~keeper:"kscroll" ~max_bytes:65536
      in
      check bool "not capped" false full.Inject.capped;
      check int "total is rendered" (String.length full.Inject.text)
        full.Inject.total_bytes;
      let pos sub =
        match contains sub full.Inject.text with
        | None -> fail ("missing " ^ sub)
        | Some i -> i
      in
      check bool "chronological" true
        (pos "first question" < pos "second question");
      (* A tiny budget tails at a line boundary when the window holds a
         newline, else hard-cuts: 20 bytes span no newline here (the last
         line alone is 21), so the tail is the last 20 bytes exactly. *)
      let tail =
        Inject.fetch_transcript ~base_dir ~keeper:"kscroll" ~max_bytes:20
      in
      check int "same total" full.Inject.total_bytes tail.Inject.total_bytes;
      check int "hard tail" 20 (String.length tail.Inject.text);
      check string "hard tail bytes"
        (String.sub full.Inject.text
           (String.length full.Inject.text - 20)
           20)
        tail.Inject.text;
      (* A budget spanning newlines aligns to one. *)
      let aligned =
        Inject.fetch_transcript ~base_dir ~keeper:"kscroll" ~max_bytes:40
      in
      check bool "aligned head" true
        (let before =
           String.sub full.Inject.text 0
             (String.length full.Inject.text
              - String.length aligned.Inject.text)
         in
         before = "" || before.[String.length before - 1] = '\n');
      (* Zero probes the size. *)
      let probe =
        Inject.fetch_transcript ~base_dir ~keeper:"kscroll" ~max_bytes:0
      in
      check string "probe empty" "" probe.Inject.text;
      check int "probe total" full.Inject.total_bytes probe.Inject.total_bytes)
;;

let is_leading_byte c = Char.code c land 0xC0 <> 0x80

let test_fetch_utf8_tail () =
  with_eio_base_dir (fun ~base_dir ->
      (* One line: "USER: " + 30 x + é (2 bytes) + 30 y. Budget 31 lands
         the naive cut on é's continuation byte; the tail must retreat to
         the leading byte instead of emitting a split scalar. *)
      let content = String.make 30 'x' ^ "\xC3\xA9" ^ String.make 30 'y' in
      append_user ~base_dir ~keeper:"kutf8" 1 content;
      let full =
        Inject.fetch_transcript ~base_dir ~keeper:"kutf8" ~max_bytes:65536
      in
      check bool "not capped" false full.Inject.capped;
      let total = String.length full.Inject.text in
      check int "rendered size" 68 total;
      let tail = Inject.fetch_transcript ~base_dir ~keeper:"kutf8" ~max_bytes:31 in
      check int "same total" total tail.Inject.total_bytes;
      check bool "nonempty tail" true (String.length tail.Inject.text > 0);
      check bool "scalar boundary" true
        (is_leading_byte tail.Inject.text.[0]);
      check bool "keeps the scalar" true
        (String.starts_with ~prefix:"\xC3\xA9" tail.Inject.text);
      check int "retreat grows by one" 32 (String.length tail.Inject.text))
;;

let test_fetch_window_capped () =
  with_eio_base_dir (fun ~base_dir ->
      (* 401 user rows overflow the 100-primary tail window: the fetch
         keeps the newest share and says older history exists. *)
      for n = 1 to 401 do
        append_user ~base_dir ~keeper:"kfull" n (Printf.sprintf "line %d" n)
      done;
      let fetched =
        Inject.fetch_transcript ~base_dir ~keeper:"kfull" ~max_bytes:1048576
      in
      check bool "capped" true fetched.Inject.capped;
      check bool "newest kept" true
        (contains "line 401" fetched.Inject.text <> None);
      check bool "oldest shed" true
        (contains "line 1\n" fetched.Inject.text = None))
;;

let test_fetch_empty_keeper () =
  with_eio_base_dir (fun ~base_dir ->
      let fetched =
        Inject.fetch_transcript ~base_dir ~keeper:"knobody" ~max_bytes:1024
      in
      check string "no text" "" fetched.Inject.text;
      check int "no bytes" 0 fetched.Inject.total_bytes;
      check bool "not capped" false fetched.Inject.capped)
;;

let () =
  run
    "collab-inject"
    [
      ( "prompt",
        [
          test_case "submit queues" `Quick test_submit_prompt_queues;
          test_case "empty rejected" `Quick test_submit_empty_rejected;
          test_case "too large rejected" `Quick test_submit_too_large;
        ] );
      ("abort", [ test_case "paths" `Quick test_abort_paths ]);
      ( "transcript",
        [
          test_case "fetch renders" `Quick test_fetch_transcript;
          test_case "utf8 tail" `Quick test_fetch_utf8_tail;
          test_case "window capped" `Quick test_fetch_window_capped;
          test_case "empty keeper" `Quick test_fetch_empty_keeper;
        ] );
    ]
;;
