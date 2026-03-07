open Alcotest

module Lodge_memory = Masc_mcp.Lodge_memory

let temp_dir () =
  let path = Filename.temp_file "test_lodge_memory_" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_temp_me_root f =
  let root = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf root)
    (fun () -> with_env "ME_ROOT" (Some root) (fun () -> f root))

let str_contains haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  if nlen = 0 then true else loop 0

let test_store_and_recall_local_memory () =
  with_temp_me_root (fun root ->
    let content = "OCaml 5.3 multicore benchmark note" in
    Lodge_memory.store
      {
        agent_name = "historian";
        action_type = "post";
        content;
        context = "benchmark";
        board_id = Some "post-1";
        timestamp = Unix.gettimeofday ();
      };
    let recalled = Lodge_memory.recall ~agent_name:"historian" ~query:"benchmark" ~limit:10 in
    check bool "stored content recalled"
      true
      (List.exists (fun (text, _score) -> str_contains text content) recalled);
    let stream_path = Filename.concat root ".masc/memory/historian/stream.jsonl" in
    check bool "memory stream file created" true (Sys.file_exists stream_path);
    let thread_root = Filename.concat root ".masc/conversations" in
    check bool "conversation root created" true (Sys.file_exists thread_root))

let test_skip_with_empty_content_does_not_persist () =
  with_temp_me_root (fun root ->
    Lodge_memory.store
      {
        agent_name = "skeptic";
        action_type = "skip";
        content = "";
        context = "no action";
        board_id = None;
        timestamp = Unix.gettimeofday ();
      };
    let recalled = Lodge_memory.recall ~agent_name:"skeptic" ~query:"" ~limit:10 in
    check int "no recalled entries" 0 (List.length recalled);
    let stream_path = Filename.concat root ".masc/memory/skeptic/stream.jsonl" in
    check bool "memory stream file absent" false (Sys.file_exists stream_path))

let () =
  run "Lodge_memory local persistence"
    [
      ("store", [ test_case "post persists to local recall paths" `Quick test_store_and_recall_local_memory ]);
      ("skip", [ test_case "empty skip does not persist" `Quick test_skip_with_empty_content_does_not_persist ]);
    ]
