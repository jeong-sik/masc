open Alcotest
module Search = Server_dashboard_task_search_text

let task id description =
  match Masc_domain.task_of_yojson (`Assoc [
    "id", `String id; "title", `String id; "description", `String description;
    "priority", `Int 2; "status", `String "todo"; "files", `List [];
    "created_at", `String "2026-09-09T00:00:00Z" ]) with
  | Ok task -> task | Error error -> fail error

let test_search_source () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "task-search-text-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let config = Masc.Workspace.default_config base in
    check bool "filesystem source" true (match config.backend with
      | Workspace_utils_backend_setup.FileSystem _ -> true
      | Workspace_utils_backend_setup.Memory _ -> false);
    let unavailable () =
      let status, body = Search.read ~config |> Search.response in
      check bool "unavailable is 503" true (status = `Service_unavailable);
      check string "redacted storage error" {|{"error":"task search text unavailable"}|}
        (Yojson.Safe.to_string body) in
    unavailable ();
    ignore (Masc.Workspace.init config ~agent_name:(Some "search-text-test"));
    let read_rows () =
      let status, body = Search.read ~config |> Search.response in
      check bool "available is 200" true (status = `OK);
      Yojson.Safe.Util.(body |> member "tasks" |> to_list) in
    check int "empty authoritative workspace is empty" 0 (List.length (read_rows ()));
    let backlog = match Workspace_backlog.read_backlog_r config with
      | Ok b -> b | Error e -> fail e in
    let description = "  indentation\n" ^ String.make 65536 'x' ^ " 끝단 검색어 Σİß\n" in
    let write description = Workspace_backlog.write_backlog config
      {backlog with tasks = [task "one" description; task "empty" ""]} in
    write description;
    let rows = read_rows () in
    check int "all tasks retained" 2 (List.length rows);
    let field row key = Yojson.Safe.Util.(row |> member key |> to_string) in
    let first = List.hd rows in
    check string "exact identity" "one" (field first "id");
    check string "untruncated and unnormalized description" description (field first "description");
    check string "empty description stays empty" "" (field (List.nth rows 1) "description");
    check string "empty description has the known SHA-256 digest"
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      (field (List.nth rows 1) "description_revision");
    let revision = field first "description_revision" in
    check int "full digest" 64 (String.length revision);
    let revised = description ^ " new tail" in
    write revised;
    let changed = List.hd (read_rows ()) in
    check string "reads latest text" revised (field changed "description");
    check bool "tail change invalidates description revision" false
      (String.equal revision (field changed "description_revision"));
    Out_channel.with_open_bin (Workspace_backlog.backlog_path config)
      (fun oc -> output_string oc "{broken");
    (* A saved recovery snapshot must not masquerade as current search data. *)
    unavailable ())

let () = run "Dashboard task search text"
  ["source", [test_case "exact text, revisions, empty and unavailable" `Quick test_search_source]]
