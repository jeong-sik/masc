(** test_fs_compat.ml - Fs_compat safety + behavior tests

    Focus: ensure mkdir_p fallback does not invoke a shell and correctly creates
    nested directories with tricky path characters.
*)

open Alcotest

let rec rm_rf (path : string) : unit =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_tmp_dir (f : string -> unit) : unit =
  let tmp = Filename.temp_file "masc_fs_compat_" ".tmp" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf tmp)
    (fun () -> f tmp)

let test_mkdir_p_creates_nested_dirs () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let path = Filename.concat base "a/b/c" in
  Fs_compat.mkdir_p path;
  check bool "created leaf dir" true (Sys.file_exists path && Sys.is_directory path)

let test_mkdir_p_does_not_shell_inject () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let pwned = Filename.concat base "pwned" in
  let dangerous = Filename.concat base ("dir;touch " ^ pwned ^ "/x") in
  Fs_compat.mkdir_p dangerous;
  (* If mkdir_p used a shell (`mkdir -p <path>`), this would create pwned. *)
  check bool "no shell side-effect file created" false (Sys.file_exists pwned);
  check bool "dangerous path exists" true (Sys.file_exists dangerous && Sys.is_directory dangerous)

let test_save_file_atomic_leaves_no_tmp_on_success () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let target = Filename.concat base "out.json" in
  (match Fs_compat.save_file_atomic target {|{"ok":true}|} with
   | Ok () -> ()
   | Error msg -> fail msg);
  check bool "target exists" true (Sys.file_exists target);
  check string "content matches" {|{"ok":true}|} (Fs_compat.load_file target);
  let leftover_tmps =
    Sys.readdir base
    |> Array.to_list
    |> List.filter (fun n ->
        String.length n >= 8 && String.sub n 0 8 = ".atomic_")
  in
  check (list string) "no leftover .atomic_ tmp files" [] leftover_tmps

let test_save_file_atomic_overwrites_existing () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let target = Filename.concat base "out.json" in
  Fs_compat.save_file target "old";
  (match Fs_compat.save_file_atomic target "new" with
   | Ok () -> ()
   | Error msg -> fail msg);
  check string "overwrite succeeded" "new" (Fs_compat.load_file target)

let with_redirected_stderr (f : unit -> 'a) : 'a * string =
  let tmp = Filename.temp_file "masc_stderr_" ".log" in
  let saved = Unix.dup Unix.stderr in
  let fd = Unix.openfile tmp [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let result =
    Fun.protect
      ~finally:(fun () ->
        flush stderr;
        Unix.dup2 saved Unix.stderr;
        Unix.close saved)
      f
  in
  let captured =
    let ic = open_in tmp in
    let len = in_channel_length ic in
    let s = really_input_string ic len in
    close_in ic;
    Sys.remove tmp;
    s
  in
  (result, captured)

let test_load_jsonl_diagnostics_counts_malformed_lines () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let path = Filename.concat base "broken.jsonl" in
  Fs_compat.save_file path "{\"ok\":1}\nnot-json\n{\"ok\":2}\n";
  let (parsed, malformed), _ =
    with_redirected_stderr (fun () -> Fs_compat.load_jsonl_diagnostics path)
  in
  check int "parsed count" 2 (List.length parsed);
  check int "malformed count" 1 malformed

let test_load_jsonl_diagnostics_warn_includes_full_path () =
  Fs_compat.clear_fs ();
  with_tmp_dir @@ fun base ->
  let path = Filename.concat base "broken.jsonl" in
  Fs_compat.save_file path "garbage\n";
  let _, captured =
    with_redirected_stderr (fun () -> Fs_compat.load_jsonl_diagnostics path)
  in
  let contains hay needle =
    let nlen = String.length needle in
    let hlen = String.length hay in
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub hay i nlen = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  check bool "warn message contains full path (not just basename)" true
    (contains captured path)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "fs_compat" [
    ( "mkdir_p"
    , [
        test_case "creates nested dirs" `Quick test_mkdir_p_creates_nested_dirs;
        test_case "no shell injection" `Quick test_mkdir_p_does_not_shell_inject;
      ]
    );
    ( "save_file_atomic"
    , [
        test_case "leaves no .atomic_ tmp on success" `Quick
          test_save_file_atomic_leaves_no_tmp_on_success;
        test_case "overwrites existing target" `Quick
          test_save_file_atomic_overwrites_existing;
      ]
    );
    ( "load_jsonl_diagnostics"
    , [
        test_case "counts malformed lines" `Quick
          test_load_jsonl_diagnostics_counts_malformed_lines;
        test_case "warn includes full path" `Quick
          test_load_jsonl_diagnostics_warn_includes_full_path;
      ]
    );
  ]

