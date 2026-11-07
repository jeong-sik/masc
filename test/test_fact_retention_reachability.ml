(* RFC-0228 P2 — fact-retention harness, deterministic half.

   Proves the *mechanism*: every fact planted in a lane is reachable
   through the actual local surface-read handler and its physical cursor, at the expected
   page depth, with one call per page. The non-deterministic half —
   whether a live keeper chooses to walk — is the live runner
   (scripts/harness/fact-retention.sh) and is gated outside CI.

   Fixture is formula-generated (no Random): reproducible by
   construction. *)

module K = Masc.Keeper_chat_store
module H = Masc.Keeper_tool_in_process_runtime

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let keeper_name = "fact-retention-keeper"

(* The surface-read handler classifies "discord" through the runtime's
   binding store: an empty discord list refuses the read as
   Unbound_connector (keeper_surface_read.ml). The store is a plain file
   read with Unix.openfile, resolved against the workspace base path,
   which the handler syncs to this test's [base_dir] on every read
   (workspace_utils_backend_setup.ml). Plant one binding for this test's
   keeper so the paged reads exercise the retention mechanism instead of
   the unbound-connector refusal. The whole [base_dir] is removed by the
   test's own cleanup, so nothing persists. *)
let discord_channel_id = "1234567890"

let write_discord_binding ~base_dir =
  let dir = Filename.concat base_dir ".gate/runtime/discord" in
  let rec mkdir_p d =
    if d = "" || d = "." || d = "/" || Sys.file_exists d then ()
    else begin
      mkdir_p (Filename.dirname d);
      Unix.mkdir d 0o755
    end
  in
  mkdir_p dir;
  let oc = open_out (Filename.concat dir "bindings.json") in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc
      (Yojson.Safe.to_string
         (`Assoc [ (discord_channel_id, `String keeper_name) ])))

let chat_path ~base_dir =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name
    ^ ".jsonl")

(* 1,100 physical rows = 11 pages at limit 100. Facts planted at
   line numbers chosen to land on pages 1, 4, and 11 (counted from the
   tail): page k covers lines (total - k*100 + 1) .. (total - (k-1)*100). *)
let total_lines = 1100
let facts = [ ("ALPHA", 1050, 1); ("BRAVO", 750, 4); ("CHARLIE", 50, 11) ]

let fact_token key = Printf.sprintf "FACT-%s-7319" key

let write_fixture ?(stamp = float_of_int) ?(surface_for = fun _ -> "discord") ~path () =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "" || d = "." || d = "/" || Sys.file_exists d then ()
    else begin
      mkdir_p (Filename.dirname d);
      Unix.mkdir d 0o755
    end
  in
  mkdir_p dir;
  let buf = Buffer.create (total_lines * 90) in
  for i = 1 to total_lines do
    let content =
      match List.find_opt (fun (_, line, _) -> line = i) facts with
      | Some (key, _, _) ->
          Printf.sprintf "the %s deployment token is %s" (String.lowercase_ascii key)
            (fact_token key)
      | None -> Printf.sprintf "filler chatter %04d" i
    in
    Buffer.add_string buf
      (Yojson.Safe.to_string
         (`Assoc
           [
             (* keeper_chat_store drops any row without a nonblank id, so a
                fixture that omits it yields empty pages and every planted
                fact reads as unreachable. *)
             ("id", `String (Printf.sprintf "fact-retention-%04d" i));
             ("role", `String (if i mod 2 = 1 then "user" else "assistant"));
             ("content", `String content);
             ("ts", `Float (stamp i));
             ("surface", Masc.Surface_ref.to_json
                (Masc.Surface_ref.Gate { label = surface_for i; address = [] }));
           ]));
    Buffer.add_char buf '\n'
  done;
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Buffer.contents buf))

let make_meta () =
  match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper_name; "trace_id", `String "surface-page-test"]) with
  | Ok meta -> meta
  | Error detail -> Alcotest.fail detail

let read ~base_dir ?cursor ?(limit = 100) () =
  let args = ["surface", `String "discord"; "limit", `Int limit]
    @ (match cursor with None -> [] | Some cursor -> ["cursor", `String cursor]) in
  H.handle_surface_read_with_outcome
    ~config:(Masc.Workspace.default_config base_dir) ~meta:(make_meta ())
    ~args:(`Assoc args)

let body_of execution =
  match execution.Masc.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> Yojson.Safe.from_string execution.raw_output
  | Deferred _ | Failed _ -> Alcotest.fail execution.raw_output

let next_cursor body =
  match Yojson.Safe.Util.member "next_cursor" body with
  | `String cursor -> Some cursor
  | `Null -> None
  | _ -> Alcotest.fail "invalid next-page authority"

let page_contains token body =
  Yojson.Safe.Util.member "messages" body |> Yojson.Safe.Util.to_list
  |> List.exists (fun row ->
       let content = Yojson.Safe.Util.member "content" row |> Yojson.Safe.Util.to_string in
       Astring.String.is_infix ~affix:token content)

(* The caller forwards only the exact next cursor supplied by the real handler. *)
let pages_to_find ?(limit = 100) ~base_dir token : int option =
  let rec go cursor page_no =
    let body = read ~base_dir ?cursor ~limit () |> body_of in
    if page_contains token body then Some page_no
    else match next_cursor body with
      | None -> None
      | Some cursor -> go (Some cursor) (page_no + 1)
  in
  go None 1

let test_every_planted_fact_is_reachable_at_depth () =
  let base_dir = temp_base_path "fact-retention" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      write_fixture ~path:(chat_path ~base_dir) ();
      write_discord_binding ~base_dir;
      List.iter
        (fun (key, _line, expected_page) ->
          match pages_to_find ~base_dir (fact_token key) with
          | Some n ->
              Alcotest.(check int)
                (Printf.sprintf "%s found at expected depth" key)
                expected_page n
          | None ->
              Alcotest.failf "fact %s unreachable through paged pull" key)
        facts)

let test_walk_terminates_at_history_start () =
  let base_dir = temp_base_path "fact-retention-end" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      write_fixture ~path:(chat_path ~base_dir) ();
      write_discord_binding ~base_dir;
      (* A token that was never planted: the walk must exhaust all 11
         pages and stop on has_more=false, not loop. *)
      Alcotest.(check (option int))
        "absent fact exhausts cleanly" None
        (pages_to_find ~base_dir "FACT-NEVER-0000"))

let with_fixture prefix write check =
  let base_dir = temp_base_path prefix in
  Fun.protect ~finally:(fun () -> remove_tree base_dir) (fun () ->
    write (chat_path ~base_dir);
    write_discord_binding ~base_dir;
    check base_dir)

let file_contents path =
  let channel = open_in path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec read acc =
      match input_line channel with
      | line ->
        let content = Yojson.Safe.from_string line |> Yojson.Safe.Util.member "content"
          |> Yojson.Safe.Util.to_string in
        read (content :: acc)
      | exception End_of_file -> List.rev acc
    in
    read [])

let walk_contents ~base_dir ~limit =
  let rec walk cursor contents =
    let body = read ~base_dir ?cursor ~limit () |> body_of in
    let page = Yojson.Safe.Util.member "messages" body |> Yojson.Safe.Util.to_list
      |> List.map (fun row -> Yojson.Safe.Util.member "content" row |> Yojson.Safe.Util.to_string) in
    let contents = page @ contents in
    match next_cursor body with
    | None -> contents
    | Some cursor -> walk (Some cursor) contents
  in
  walk None []

let test_equal_timestamps_keep_every_fact () =
  with_fixture "surface-same-ts"
    (fun path -> write_fixture ~stamp:(fun _ -> 7.) ~path ())
    (fun base_dir ->
      Alcotest.(check (list string)) "every persisted row exactly once and in append order"
        (file_contents (chat_path ~base_dir)) (walk_contents ~base_dir ~limit:100);
      List.iter (fun (key, _, depth) ->
        Alcotest.(check (option int)) key (Some depth)
          (pages_to_find ~base_dir (fact_token key))) facts)

let test_small_lane_pages_do_not_hide_older_rows () =
  with_fixture "surface-small-page"
    (fun path -> write_fixture ~path ())
    (fun base_dir ->
      Alcotest.(check (list string)) "small pages retain the complete lane"
        (file_contents (chat_path ~base_dir)) (walk_contents ~base_dir ~limit:20);
      List.iter (fun (key, line, _) ->
        let depth = ((total_lines - line) / 20) + 1 in
        Alcotest.(check (option int)) key (Some depth)
          (pages_to_find ~limit:20 ~base_dir (fact_token key))) facts)

let test_clock_regression_preserves_append_order () =
  with_fixture "surface-regressing-clock"
    (fun path -> write_fixture ~stamp:(fun i -> if i < 600 then 1000. else 500.) ~path ())
    (fun base_dir ->
      Alcotest.(check (list string)) "clock regression cannot reorder or skip rows"
        (file_contents (chat_path ~base_dir)) (walk_contents ~base_dir ~limit:20))

let test_empty_lane_page_retains_next_cursor () =
  with_fixture "surface-empty-lane"
    (fun path -> write_fixture
      ~surface_for:(fun i -> if i > 1000 then "dashboard" else "discord") ~path ())
    (fun base_dir ->
      let body = read ~base_dir () |> body_of in
      Alcotest.(check int) "empty lane page" 0
        (Yojson.Safe.Util.member "returned" body |> Yojson.Safe.Util.to_int);
      Alcotest.(check bool) "earlier page remains requestable" true
        (Option.is_some (next_cursor body));
      Alcotest.(check (option int)) "older fact remains reachable" (Some 4)
        (pages_to_find ~base_dir (fact_token "BRAVO")))

let failed_without_cursor execution =
  Alcotest.(check bool) "failed outcome" true
    (match execution.Masc.Keeper_tool_execution.disposition with
     | Tool_result.Failed _ -> true | Completed _ | Deferred _ -> false);
  let body = Yojson.Safe.from_string execution.raw_output in
  Alcotest.(check bool) "no successful next-page authority" true
    (Yojson.Safe.Util.member "next_cursor" body = `Null)

let test_invalid_cursor_refuses_before_read () =
  let base_dir = temp_base_path "surface-invalid-cursor" in
  read ~base_dir ~cursor:"not-a-cursor" () |> failed_without_cursor;
  Alcotest.(check bool) "no notes/store directory created" false (Sys.file_exists base_dir)

let test_unreadable_history_is_not_empty_success () =
  with_fixture "surface-unreadable"
    (fun path -> write_fixture ~path (); Sys.remove path; Unix.mkdir path 0o700)
    (fun base_dir -> read ~base_dir () |> failed_without_cursor)

let test_replaced_history_refuses_old_cursor () =
  with_fixture "surface-replaced"
    (fun path -> write_fixture ~path ())
    (fun base_dir ->
      let cursor = read ~base_dir () |> body_of |> next_cursor |> Option.get in
      let path = chat_path ~base_dir in
      let replacement = path ^ ".replacement" in
      write_fixture ~path:replacement ();
      Unix.rename replacement path;
      read ~base_dir ~cursor () |> failed_without_cursor)

let () =
  Alcotest.run "fact_retention_reachability"
    [
      ( "paged reachability (RFC-0228 P2)",
        [
          Alcotest.test_case "every planted fact reachable at its depth"
            `Quick test_every_planted_fact_is_reachable_at_depth;
          Alcotest.test_case "walk terminates at history start" `Quick
            test_walk_terminates_at_history_start;
          Alcotest.test_case "equal timestamps retain every fact" `Quick test_equal_timestamps_keep_every_fact;
          Alcotest.test_case "small pages never hide lane rows" `Quick test_small_lane_pages_do_not_hide_older_rows;
          Alcotest.test_case "clock regression keeps append order" `Quick test_clock_regression_preserves_append_order;
          Alcotest.test_case "empty lane page retains next cursor" `Quick test_empty_lane_page_retains_next_cursor;
          Alcotest.test_case "invalid cursor refuses before read" `Quick test_invalid_cursor_refuses_before_read;
          Alcotest.test_case "unreadable history is not empty success" `Quick test_unreadable_history_is_not_empty_success;
          Alcotest.test_case "replaced history refuses old cursor" `Quick test_replaced_history_refuses_old_cursor;
        ] );
    ]
