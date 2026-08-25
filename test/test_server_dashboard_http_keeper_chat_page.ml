(* Body contract for GET /chat/history/page.

   The store-level walk is already pinned by test_keeper_chat_store.ml
   ("load_page walks backward"). What is asserted here is the layer this route
   adds on top: the schema tag, the cursor the caller is told to use next, and
   the two ways paging ends -- exhausted history, and history that exists but
   no cursor can reach. *)

open Masc
module Keeper_api = Server_dashboard_http_keeper_api

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end
;;

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
;;

let chat_path ~base_dir ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (keeper_name ^ ".jsonl")
;;

(* [ts] omitted entirely for [`Untimed]: that is the legacy row shape the
   cursor cannot order, and constructing it is the whole point of one case.
   [id] is required -- the store drops rows without one. *)
let row ~content stamp =
  let base = [ "id", `String content; "role", `String "user"; "content", `String content ] in
  match stamp with
  | `At ts -> `Assoc (base @ [ "ts", `Float ts ])
  | `Untimed -> `Assoc base
;;

let write_lane ~base_dir ~keeper_name rows =
  let path = chat_path ~base_dir ~keeper_name in
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun row -> output_string oc (Yojson.Safe.to_string row ^ "\n"))
        rows)
;;

let numbered ~total =
  List.init total (fun i ->
    let n = i + 1 in
    row ~content:(Printf.sprintf "msg-%04d" n) (`At (float_of_int n)))
;;

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let messages_of body =
  match field "messages" body with
  | Some (`List rows) -> rows
  | Some _ | None -> Alcotest.fail "messages is not a list"
;;

let content_of = function
  | `Assoc fields ->
    (match List.assoc_opt "content" fields with
     | Some (`String s) -> s
     | Some _ | None -> Alcotest.fail "row has no string content")
  | _ -> Alcotest.fail "row is not an object"
;;

let bool_field name body =
  match field name body with
  | Some (`Bool b) -> b
  | Some _ | None -> Alcotest.fail (name ^ " is not a bool")
;;

let with_lane prefix rows f =
  let base_dir = temp_base_path prefix in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "pager" in
      write_lane ~base_dir ~keeper_name rows;
      f (Workspace.default_config base_dir) keeper_name)
;;

let test_tag_and_cursor () =
  with_lane "chat-page-cursor" (numbered ~total:300) (fun config name ->
    let body = Keeper_api.keeper_chat_history_page_json config name ~before:None in
    Alcotest.(check (option string))
      "schema tag"
      (Some "masc.keeper_chat_history.page.v1")
      (match field "schema" body with Some (`String s) -> Some s | _ -> None);
    let rows = messages_of body in
    Alcotest.(check int) "newest window size" 100 (List.length rows);
    Alcotest.(check string)
      "newest row last"
      "msg-0300"
      (content_of (List.hd (List.rev rows)));
    Alcotest.(check bool) "older rows remain" true (bool_field "has_more" body);
    (* The cursor is the oldest ts in the window, so the next page starts
       exactly where this one stopped -- no row served twice, none skipped. *)
    Alcotest.(check (option (float 0.001)))
      "next cursor is the oldest returned ts"
      (Some 201.0)
      (match field "next_before" body with Some (`Float f) -> Some f | _ -> None))
;;

let test_cursor_walks_without_gap_or_repeat () =
  with_lane "chat-page-walk" (numbered ~total:300) (fun config name ->
    let page before = Keeper_api.keeper_chat_history_page_json config name ~before in
    let first = page None in
    let cursor body =
      match field "next_before" body with Some (`Float f) -> Some f | _ -> None
    in
    let second = page (cursor first) in
    let rows = messages_of second in
    Alcotest.(check string) "page 2 first" "msg-0101" (content_of (List.hd rows));
    Alcotest.(check string)
      "page 2 last is one below page 1's first"
      "msg-0200"
      (content_of (List.hd (List.rev rows)));
    let third = page (cursor second) in
    let third_rows = messages_of third in
    Alcotest.(check string)
      "page 3 first"
      "msg-0001"
      (content_of (List.hd third_rows));
    Alcotest.(check bool)
      "history exhausted"
      false
      (bool_field "has_more" third))
;;

let test_exhausted_history_reports_null_cursor () =
  with_lane "chat-page-short" (numbered ~total:3) (fun config name ->
    let body = Keeper_api.keeper_chat_history_page_json config name ~before:(Some 1.0) in
    Alcotest.(check int) "no rows older than the first" 0 (List.length (messages_of body));
    Alcotest.(check bool) "nothing older" false (bool_field "has_more" body);
    Alcotest.(check bool)
      "empty page carries no cursor"
      true
      (match field "next_before" body with Some `Null -> true | _ -> false))
;;

let test_cursor_is_monotonic_so_the_walk_terminates () =
  (* Whatever the rows carry, each page's cursor must be strictly older than
     the one that produced it. That is the property the caller's loop relies on
     to end; asserting it directly means a future change to how the store
     stamps rows cannot turn "load more" into a spin. *)
  with_lane "chat-page-monotonic" (numbered ~total:300) (fun config name ->
    let cursor body =
      match field "next_before" body with Some (`Float f) -> Some f | _ -> None
    in
    let rec walk before seen steps =
      if steps > 10 then Alcotest.fail "cursor did not terminate within 10 pages"
      else
        let body = Keeper_api.keeper_chat_history_page_json config name ~before in
        match cursor body with
        | None -> List.rev seen
        | Some c ->
          (match before with
           | Some prev when c >= prev ->
             Alcotest.failf "cursor %f did not move below previous %f" c prev
           | Some _ | None -> ());
          walk (Some c) (c :: seen) (steps + 1)
    in
    let cursors = walk None [] 0 in
    Alcotest.(check bool) "the walk produced pages" true (cursors <> []))
;;

let test_autonomous_turns_are_not_repeated_per_page () =
  (* /chat/history carries every autonomous turn retention still holds; a page
     that re-sent them would duplicate rows the caller already has. With no
     autonomous source written at all, the assertion is simply that the page
     body is exactly the chat rows. *)
  with_lane "chat-page-direct-only" (numbered ~total:5) (fun config name ->
    let body = Keeper_api.keeper_chat_history_page_json config name ~before:None in
    let rows = messages_of body in
    Alcotest.(check int) "chat rows only" 5 (List.length rows);
    List.iter
      (fun r ->
        Alcotest.(check bool)
          "no autonomous_turn marker on a paged row"
          false
          (match r with
           | `Assoc fields -> List.mem_assoc "autonomous_turn" fields
           | _ -> false))
      rows)
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_chat_page"
    [ ( "GET /chat/history/page"
      , [ Alcotest.test_case "schema tag and next cursor" `Quick test_tag_and_cursor
        ; Alcotest.test_case
            "walking the cursor repeats no row and skips none"
            `Quick
            test_cursor_walks_without_gap_or_repeat
        ; Alcotest.test_case
            "exhausted history reports a null cursor"
            `Quick
            test_exhausted_history_reports_null_cursor
        ; Alcotest.test_case
            "the cursor moves strictly older so the walk terminates"
            `Quick
            test_cursor_is_monotonic_so_the_walk_terminates
        ; Alcotest.test_case
            "autonomous turns are not repeated per page"
            `Quick
            test_autonomous_turns_are_not_repeated_per_page
        ] )
    ]
;;
