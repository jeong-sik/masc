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

let with_history_state f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = temp_base_path "chat-history-truth" in
    Unix.mkdir base_dir 0o700;
    Dashboard_cache.invalidate_all ();
    Fun.protect
      ~finally:(fun () -> Dashboard_cache.invalidate_all (); remove_tree base_dir)
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:base_dir in
        f state (Mcp_server.workspace_config state)))
;;

(* Exercise the actual GET subroute, including status and cache disposition. *)
let get_history state name =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    let req = Httpun.Reqd.request reqd in
    Keeper_api.handle_keeper_get_subroutes state req req reqd) in
  let wire = Printf.sprintf
      "GET /api/v1/keepers/%s/chat/history HTTP/1.1\r\nHost: localhost\r\n\r\n" name in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let length = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok length);
      drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let lines = Buffer.contents output |> String.split_on_char '\n' in
  let status = match lines with
    | first :: _ ->
      (match String.split_on_char ' ' first with
       | _ :: status :: _ -> int_of_string status
       | _ -> Alcotest.fail "invalid HTTP status line")
    | [] -> Alcotest.fail "missing HTTP response" in
  let rec body = function
    | "\r" :: rest -> String.concat "\n" rest
    | _ :: rest -> body rest
    | [] -> Alcotest.fail "missing HTTP header boundary" in
  status, Yojson.Safe.from_string (body lines)
;;

let cache_entries () =
  match field "entries" (Dashboard_cache.stats ()) with
  | Some (`Int count) -> count
  | _ -> Alcotest.fail "cache stats have no entries count"
;;

let write_offline_meta ?(total_turns = 0) config name =
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("test-" ^ name) ])
      |> Result.get_ok in
  let meta = { meta with runtime =
      { meta.runtime with usage = { meta.runtime.usage with total_turns } } } in
  let path = Filename.concat (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name Keeper_runtime_root_entry.Metadata) in
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Keeper_meta_json.meta_to_json meta |> Yojson.Safe.to_string))
;;

let test_unknown_names_never_register_or_cache_empty_history () =
  with_history_state (fun state config ->
    let before_cache = cache_entries () in
    let before_registry = Keeper_registry.all ~base_path:config.Workspace.base_path () |> List.length in
    for i = 1 to 40 do
      let status, body = get_history state (Printf.sprintf "unknown-history-%d" i) in
      Alcotest.(check int) "unknown is 404" 404 status;
      Alcotest.(check bool) "unknown is an error, not an empty transcript" true
        (Option.is_some (field "error" body))
    done;
    Alcotest.(check int) "no history cache entries" before_cache (cache_entries ());
    Alcotest.(check int) "no registry entries" before_registry
      (Keeper_registry.all ~base_path:config.base_path () |> List.length);
    let name = "unknown-history-1" in
    write_lane ~base_dir:config.base_path ~keeper_name:name [ row ~content:"retained" (`At 1.) ];
    let status, body = get_history state name in
    Alcotest.(check int) "later retained history remains readable without registration" 200 status;
    Alcotest.(check (list string)) "no negative empty cache" [ "retained" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history"))
;;

let test_known_empty_history_observes_later_chat_creation () =
  with_history_state (fun state config ->
    let name = "offline-history" in
    write_offline_meta config name;
    Alcotest.(check bool) "offline fixture has no live authority" false
      (Keeper_registry.is_registered ~base_path:config.Workspace.base_path name);
    let status, body = get_history state name in
    Alcotest.(check int) "known empty history is successful" 200 status;
    Alcotest.(check bool) "actual empty transcript" true (body = `List []);
    write_lane ~base_dir:config.base_path ~keeper_name:name [ row ~content:"created" (`At 2.) ];
    let status, body = get_history state name in
    Alcotest.(check int) "created history is successful" 200 status;
    Alcotest.(check (list string)) "absent fingerprint did not pin empty history" [ "created" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history"))
;;

let test_counter_only_metadata_does_not_recompute_history () =
  with_history_state (fun _state config ->
    let name = "metadata-counter-history" in
    let computes = ref 0 in
    let read () = Server_keeper_chat_history_read.cached_json ~config ~keeper_name:name ~ttl:60.
        ~render:(fun _ _ -> incr computes; `List []) |> Result.get_ok in
    write_offline_meta ~total_turns:1 config name;
    ignore (read ());
    write_offline_meta ~total_turns:2 config name;
    ignore (read ());
    Alcotest.(check int) "counter write preserves successful transcript cache" 1 !computes)
;;

let test_broken_metadata_alone_cannot_authorize_empty_history () =
  with_history_state (fun state config ->
    let name = "broken-metadata-history" in
    let path = Filename.concat (Workspace.keepers_runtime_dir config)
        (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name Keeper_runtime_root_entry.Metadata) in
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    output_string oc "{private-meta-sentinel}\n";
    close_out oc;
    let status, body = get_history state name in
    Alcotest.(check int) "broken metadata alone is unavailable" 503 status;
    Alcotest.(check (option string)) "public error contains no metadata/path detail"
      (Some "Keeper history is temporarily unavailable; retry the request.")
      (match field "error" body with Some (`String text) -> Some text | _ -> None);
    Alcotest.(check int) "invalid authority does not cache empty history" 0 (cache_entries ());
    write_lane ~base_dir:config.Workspace.base_path ~keeper_name:name
      [ row ~content:"retained archive" (`At 1.) ];
    let status, body = get_history state name in
    Alcotest.(check int) "retained chat remains authoritative despite obsolete metadata" 200 status;
    Alcotest.(check (list string)) "archive rows preserved" [ "retained archive" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history"))
;;

let test_unreadable_history_never_becomes_cached_empty_success () =
  with_history_state (fun state config ->
    let name = "broken-history" in
    let path = chat_path ~base_dir:config.Workspace.base_path ~keeper_name:name in
    mkdir_p path;
    let status, body = get_history state name in
    Alcotest.(check int) "non-regular history unavailable" 503 status;
    Alcotest.(check bool) "read failure is explicit" true (Option.is_some (field "error" body));
    Alcotest.(check int) "read failure not cached" 0 (cache_entries ());
    Unix.rmdir path;
    write_lane ~base_dir:config.base_path ~keeper_name:name [ row ~content:"repaired" (`At 1.) ];
    let status, body = get_history state name in
    Alcotest.(check int) "repaired history succeeds immediately" 200 status;
    Alcotest.(check (list string)) "no failed-read empty cache" [ "repaired" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history");
    let oc = open_out_gen [Open_wronly; Open_append] 0o600 path in
    output_string oc "{incomplete";
    close_out oc;
    let status, _ = get_history state name in
    Alcotest.(check int) "incomplete tail refuses partial success" 503 status;
    Alcotest.(check int) "old successful cache retired" 0 (cache_entries ()))
;;

let test_same_stat_atomic_replacement_invalidates_history () =
  with_history_state (fun state config ->
    let name = "replaced-history" in
    write_lane ~base_dir:config.Workspace.base_path ~keeper_name:name [ row ~content:"old" (`At 1.) ];
    let path = chat_path ~base_dir:config.base_path ~keeper_name:name in
    Unix.utimes path 1000. 1000.;
    let status, _ = get_history state name in
    Alcotest.(check int) "initial history" 200 status;
    let before = Unix.stat path in
    let replacement = path ^ ".replacement" in
    let oc = open_out replacement in
    output_string oc (Yojson.Safe.to_string (row ~content:"new" (`At 1.)) ^ "\n");
    close_out oc;
    Unix.utimes replacement before.st_atime before.st_mtime;
    Alcotest.(check int) "same byte length" before.st_size (Unix.stat replacement).st_size;
    Alcotest.(check (float 0.)) "same modification time" before.st_mtime (Unix.stat replacement).st_mtime;
    Unix.rename replacement path;
    let status, body = get_history state name in
    Alcotest.(check int) "replacement history" 200 status;
    Alcotest.(check (list string)) "inode identity invalidates same-size/mtime cache" [ "new" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history"))
;;

let test_failed_autonomous_store_never_becomes_empty_history () =
  with_history_state (fun state config ->
    let name = "broken-autonomous-history" in
    let location = Dated_jsonl.Store.keeper (Workspace.dated_store_root config)
        ~keeper:name Dated_jsonl.Store.Keeper.Turn_records in
    let month = Filename.concat (Dated_jsonl.Store.dir location) "2026-10" in
    mkdir_p month;
    let path = Filename.concat month "16.jsonl" in
    let oc = open_out path in
    output_string oc "{private-provider-response-sentinel}\n";
    close_out oc;
    let status, body = get_history state name in
    Alcotest.(check int) "failed TurnRecord read is unavailable" 503 status;
    Alcotest.(check bool) "TurnRecord error is explicit" true (Option.is_some (field "error" body));
    Alcotest.(check (option string)) "public error contains no provider response or host path"
      (Some "Keeper history is temporarily unavailable; retry the request.")
      (match field "error" body with Some (`String text) -> Some text | _ -> None);
    Alcotest.(check int) "failed TurnRecord read not cached" 0 (cache_entries ()))
;;

let test_compute_commit_returns_body_without_retaining_stale_cache () =
  with_history_state (fun state config ->
    let name = "racing-history" in
    write_offline_meta config name;
    write_lane ~base_dir:config.Workspace.base_path ~keeper_name:name
      [ row ~content:"already read" (`At 1.) ];
    let committed = Atomic.make false in
    let status, body = Server_keeper_chat_history_read.For_testing.with_after_read_hook
        (fun () ->
          if Atomic.compare_and_set committed false true then
            let request_id = Keeper_chat_delivery_identity.Request_id.of_string
                "history-compute-commit" |> Result.get_ok in
            match Keeper_chat_store.append_user_message_once
                ~base_dir:config.Workspace.base_path ~keeper_name:name
                ~delivery_key:(Keeper_chat_delivery_identity.Operation request_id)
                ~content:"committed during read" () with
            | Ok (Keeper_chat_store.Appended _) -> ()
            | Ok (Keeper_chat_store.Already_present _) -> Alcotest.fail "writer did not append its new delivery"
            | Error detail -> Alcotest.fail detail)
        (fun () -> get_history state name) in
    Alcotest.(check bool) "writer committed during the actual history computation" true (Atomic.get committed);
    Alcotest.(check int) "strictly read body remains HTTP 200" 200 status;
    Alcotest.(check (list string)) "current request keeps its observed body" [ "already read" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history");
    Alcotest.(check int) "changed compute lost cache ownership before publication" 0 (cache_entries ());
    let status, body = get_history state name in
    Alcotest.(check int) "next request succeeds without a retry budget" 200 status;
    Alcotest.(check (list string)) "next request reads the newly committed row"
      [ "already read"; "committed during read" ]
      (match body with `List rows -> List.map content_of rows | _ -> Alcotest.fail "not history");
    Alcotest.(check int) "stable recompute can retain its cache" 1 (cache_entries ()))
;;

let test_strict_transcript_preserves_existing_role_window () =
  let rows = List.init 120 (fun i ->
    row ~content:(Printf.sprintf "user-%d" i) (`At (float_of_int i))
    :: List.init 5 (fun j ->
      `Assoc [ "id", `String (Printf.sprintf "tool-%d-%d" i j)
             ; "role", `String "tool"; "content", `String "tool"
             ; "tool_call_name", `String "fixture-tool"
             ; "ts", `Float (float_of_int i) ])) |> List.concat in
  with_lane "chat-strict-window" rows (fun config name ->
    let base_dir = config.Workspace.base_path in
    let permissive = Keeper_chat_store.load ~base_dir ~keeper_name:name in
    let strict = match Keeper_chat_store.load_result ~base_dir ~keeper_name:name with
      | Ok messages -> messages
      | Error error -> Alcotest.fail (Keeper_chat_history_page.error_to_string error) in
    Alcotest.(check (list string)) "same retained durable identities and order"
      (List.map (fun (m : Keeper_chat_store.chat_message) -> m.id) permissive)
      (List.map (fun (m : Keeper_chat_store.chat_message) -> m.id) strict);
    Alcotest.(check int) "100 primary messages survive tool traffic" 100
      (List.filter (fun (m : Keeper_chat_store.chat_message) ->
         Keeper_chat_store.Role.equal m.role Keeper_chat_store.Role.User) strict |> List.length))
;;

let () =
  Server_startup_state.mark_state_ready () |> Result.get_ok;
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
      ]
    ; "legacy history truth boundary",
      [ Alcotest.test_case "unknown names never register or cache empty success" `Quick test_unknown_names_never_register_or_cache_empty_history
      ; Alcotest.test_case "offline empty history observes later file creation" `Quick test_known_empty_history_observes_later_chat_creation
      ; Alcotest.test_case "counter-only metadata keeps transcript cache" `Quick test_counter_only_metadata_does_not_recompute_history
      ; Alcotest.test_case "broken metadata alone cannot authorize empty history" `Quick test_broken_metadata_alone_cannot_authorize_empty_history
      ; Alcotest.test_case "read failure never becomes cached empty success" `Quick test_unreadable_history_never_becomes_cached_empty_success
      ; Alcotest.test_case "same-size/mtime replacement changes identity" `Quick test_same_stat_atomic_replacement_invalidates_history
      ; Alcotest.test_case "failed autonomous storage never becomes empty history" `Quick test_failed_autonomous_store_never_becomes_empty_history
      ; Alcotest.test_case "compute commit returns history without retaining stale cache" `Quick test_compute_commit_returns_body_without_retaining_stale_cache
      ; Alcotest.test_case "strict reads preserve role-based transcript selection" `Quick test_strict_transcript_preserves_existing_role_window
      ] ]
