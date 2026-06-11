(* RFC-0228 P2 — fact-retention harness, deterministic half.

   Proves the *mechanism*: every fact planted in a lane is reachable
   through the paged pull (load_page before-walk), at the expected
   page depth, with one call per page. The non-deterministic half —
   whether a live keeper chooses to walk — is the live runner
   (scripts/harness/fact-retention.sh) and is gated outside CI.

   Fixture is formula-generated (no Random): reproducible by
   construction. *)

module K = Masc.Keeper_chat_store

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

let chat_path ~base_dir =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:base_dir)
       "keeper_chat")
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name
    ^ ".jsonl")

(* 1,100 primaries = 11 pages of [max_history] = 100. Facts planted at
   line numbers chosen to land on pages 1, 4, and 11 (counted from the
   tail): page k covers lines (total - k*100 + 1) .. (total - (k-1)*100). *)
let total_lines = 1100
let facts = [ ("ALPHA", 1050, 1); ("BRAVO", 750, 4); ("CHARLIE", 50, 11) ]

let fact_token key = Printf.sprintf "FACT-%s-7319" key

let write_fixture ~path =
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
             ("role", `String (if i mod 2 = 1 then "user" else "assistant"));
             ("content", `String content);
             ("ts", `Float (float_of_int i));
             ("source", `String "discord");
           ]));
    Buffer.add_char buf '\n'
  done;
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Buffer.contents buf))

let page_contains token (page : K.page) =
  List.exists
    (fun (m : K.chat_message) ->
      Astring.String.is_infix ~affix:token m.K.content)
    page.K.messages

let oldest_ts (page : K.page) =
  match page.K.messages with
  | [] -> None
  | first :: _ -> first.K.ts

(* Walk back from the tail until [token] appears; return pages read. *)
let pages_to_find ~base_dir token : int option =
  let max_pages = 50 in
  let rec go ~before ~page_no =
    if page_no > max_pages then None
    else
      let page =
        match before with
        | None -> K.load_page ~base_dir ~keeper_name ()
        | Some b -> K.load_page ~base_dir ~keeper_name ~before:b ()
      in
      if page_contains token page then Some page_no
      else if not page.K.has_more then None
      else
        match oldest_ts page with
        | None -> None
        | Some ts -> go ~before:(Some ts) ~page_no:(page_no + 1)
  in
  go ~before:None ~page_no:1

let test_every_planted_fact_is_reachable_at_depth () =
  let base_dir = temp_base_path "fact-retention" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      write_fixture ~path:(chat_path ~base_dir);
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
      write_fixture ~path:(chat_path ~base_dir);
      (* A token that was never planted: the walk must exhaust all 11
         pages and stop on has_more=false, not loop. *)
      Alcotest.(check (option int))
        "absent fact exhausts cleanly" None
        (pages_to_find ~base_dir "FACT-NEVER-0000"))

let () =
  Alcotest.run "fact_retention_reachability"
    [
      ( "paged reachability (RFC-0228 P2)",
        [
          Alcotest.test_case "every planted fact reachable at its depth"
            `Quick test_every_planted_fact_is_reachable_at_depth;
          Alcotest.test_case "walk terminates at history start" `Quick
            test_walk_terminates_at_history_start;
        ] );
    ]
