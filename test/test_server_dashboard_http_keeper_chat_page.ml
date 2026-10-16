(* Body contract for GET /chat/history/page.

   Exact physical cursors must preserve append order across clock collisions
   and regression, bound consecutive rows, and refuse changed or unreadable
   transcripts before publishing any continuation. *)

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

let cursor_of body =
  match field "next_cursor" body with
  | Some (`String encoded) ->
    (match Keeper_chat_history_page.cursor_of_string encoded with
     | Ok cursor -> Some cursor
     | Error error -> Alcotest.fail (Keeper_chat_history_page.error_to_string error))
  | Some `Null -> None
  | _ -> Alcotest.fail "missing next_cursor"

let page ?max_total config name cursor =
  match Keeper_api.keeper_chat_history_page_json ?max_total config name ~cursor with
  | Ok page -> page
  | Error error -> Alcotest.fail (Keeper_chat_history_page.error_to_string error)

let test_exact_walk_with_colliding_and_regressing_clocks () =
  let original = List.init 907 (fun i ->
    let stamp = if i < 300 then 1000. else if i < 600 then 500. else 1000. in
    row ~content:(Printf.sprintf "row-%04d" i) (`At stamp)) in
  with_lane "chat-exact-clock" original (fun config name ->
    let rec walk cursor collected =
      let body = page ~max_total:100 config name cursor in
      let rows = messages_of body in
      let collected = rows @ collected in
      match cursor_of body with
      | None -> collected
      | Some next -> walk (Some next) collected
    in
    let all = walk None [] |> List.map content_of in
    Alcotest.(check (list string)) "every append row, exactly once, despite equal/backward clocks"
      (List.map content_of original) all)
;;

let test_schema_and_opaque_cursor () =
  with_lane "chat-exact-schema" (numbered ~total:500) (fun config name ->
    let body = page config name None in
    Alcotest.(check (option string)) "v2 contract"
      (Some "masc.keeper_chat_history.page.v2")
      (match field "schema" body with Some (`String tag) -> Some tag | _ -> None);
    Alcotest.(check int) "bounded contiguous page" 400 (List.length (messages_of body));
    Alcotest.(check bool) "physical cursor issued" true (Option.is_some (cursor_of body));
    let oldest = page config name (cursor_of body) in
    Alcotest.(check int) "remaining exact prefix" 100 (List.length (messages_of oldest));
    Alcotest.(check bool) "prefix exhausted" false (bool_field "has_more" oldest))
;;

let test_atomic_replacement_refuses_old_cursor () =
  with_lane "chat-exact-replace" (numbered ~total:500) (fun config name ->
    let cursor = cursor_of (page config name None) in
    let base_dir = (config : Workspace.config).base_path in
    let path = chat_path ~base_dir ~keeper_name:name in
    let replacement = path ^ ".replacement" in
    let oc = open_out replacement in
    output_string oc (Yojson.Safe.to_string (row ~content:"replacement" (`At 0.)) ^ "\n");
    close_out oc;
    Unix.rename replacement path;
    match Keeper_api.keeper_chat_history_page_json config name ~cursor with
    | Error Keeper_chat_history_page.Stale_cursor -> ()
    | Error error -> Alcotest.fail (Keeper_chat_history_page.error_to_string error)
    | Ok _ -> Alcotest.fail "a replaced transcript accepted its old cursor")
;;

let test_malformed_row_fails_the_whole_page () =
  with_lane "chat-exact-malformed"
    [ row ~content:"valid" (`At 1.); `Assoc ["id", `String "invalid"; "role", `String "invented"] ]
    (fun config name ->
      match Keeper_api.keeper_chat_history_page_json config name ~cursor:None with
      | Error (Keeper_chat_history_page.Invalid_row _) -> ()
      | Error error -> Alcotest.fail (Keeper_chat_history_page.error_to_string error)
      | Ok _ -> Alcotest.fail "partial decode advanced an exact page")
;;

let test_page_limit_is_a_contiguous_slice () =
  with_lane "chat-exact-limit" (numbered ~total:300) (fun config name ->
    let body = page ~max_total:100 config name None in
    let rows = messages_of body in
    Alcotest.(check int) "requested rows" 100 (List.length rows);
    Alcotest.(check string) "oldest exact row" "msg-0201" (content_of (List.hd rows));
    Alcotest.(check string) "newest exact row" "msg-0300" (content_of (List.hd (List.rev rows))))
;;

let test_cursor_binding_and_later_incomplete_append () =
  with_lane "chat-exact-binding" (numbered ~total:500) (fun config name ->
    let cursor = cursor_of (page config name None) |> Option.get in
    let path = chat_path ~base_dir:config.Workspace.base_path ~keeper_name:name in
    (match Keeper_chat_history_page.read ~path ~owner:"another-keeper" ~cursor ~max_rows:100 () with
     | Error Keeper_chat_history_page.Stale_cursor -> ()
     | _ -> Alcotest.fail "a cursor crossed its Keeper boundary");
    let oc = open_out_gen [Open_wronly; Open_append] 0o600 path in
    output_string oc "{incomplete later append";
    close_out oc;
    let earlier = page config name (Some cursor) in
    Alcotest.(check int) "later append does not change the issued prefix"
      100 (List.length (messages_of earlier)))
;;

let test_changed_anchor_and_truncation_refuse_cursor () =
  with_lane "chat-exact-anchor" (numbered ~total:500) (fun config name ->
    let cursor = cursor_of (page config name None) in
    let path = chat_path ~base_dir:config.Workspace.base_path ~keeper_name:name in
    let expect_stale () =
      match Keeper_api.keeper_chat_history_page_json config name ~cursor with
      | Error Keeper_chat_history_page.Stale_cursor -> ()
      | _ -> Alcotest.fail "changed physical prefix accepted its old cursor"
    in
    (* Rewrite the same inode with equal-length rows: inode and byte count alone
       cannot certify that the cursor still names its original boundary. *)
    write_lane ~base_dir:config.base_path ~keeper_name:name
      (List.init 500 (fun i -> row ~content:(Printf.sprintf "new-%04d" (i + 1)) (`At (float_of_int (i + 1)))));
    expect_stale ();
    let oc = open_out path in
    close_out oc;
    expect_stale ())
;;

let test_oversize_row_is_an_error_instead_of_exhaustion () =
  with_lane "chat-exact-oversize" [] (fun config name ->
    let path = chat_path ~base_dir:config.Workspace.base_path ~keeper_name:name in
    let oc = open_out path in
    output_string oc (String.make (4 * 1024 * 1024 + 1) 'x');
    output_char oc '\n';
    close_out oc;
    match Keeper_api.keeper_chat_history_page_json config name ~cursor:None with
    | Error Keeper_chat_history_page.Row_exceeds_window -> ()
    | _ -> Alcotest.fail "oversize row was skipped or reported as exhaustion")
;;

let () =
  Alcotest.run "server_dashboard_http_keeper_chat_page"
    [ "exact history paging",
      [ Alcotest.test_case "equal and regressing clocks preserve every row" `Quick test_exact_walk_with_colliding_and_regressing_clocks
      ; Alcotest.test_case "schema and opaque physical cursor" `Quick test_schema_and_opaque_cursor
      ; Alcotest.test_case "atomic replacement refuses old cursor" `Quick test_atomic_replacement_refuses_old_cursor
      ; Alcotest.test_case "one malformed row refuses entire page" `Quick test_malformed_row_fails_the_whole_page
      ; Alcotest.test_case "page hint is a contiguous slice" `Quick test_page_limit_is_a_contiguous_slice
      ; Alcotest.test_case "cursor owner and issued prefix remain bound" `Quick test_cursor_binding_and_later_incomplete_append
      ; Alcotest.test_case "anchor rewrite and truncation refuse cursor" `Quick test_changed_anchor_and_truncation_refuse_cursor
      ; Alcotest.test_case "oversize row fails without skipping" `Quick test_oversize_row_is_an_error_instead_of_exhaustion
      ] ]
