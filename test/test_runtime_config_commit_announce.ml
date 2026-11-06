(* RFC-0480 §3.4: every runtime.toml commit attempt reports to the installed
   observer, including one the validator refuses, because a failed commit can
   still have replaced the file. *)

open Alcotest

let test_every_commit_attempt_reports () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Unix.realpath (Filename.temp_dir "runtime-config-announce-" "") in
  let path = Filename.concat dir "runtime.toml" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.install_config_commit_observer (fun ~runtime_config_path:_ -> ());
      Fs_compat.remove_tree dir)
    (fun () ->
      let reported = ref [] in
      Runtime.install_config_commit_observer (fun ~runtime_config_path ->
        reported := runtime_config_path :: !reported);
      (match Runtime.commit_config_text_locked ~runtime_config_path:path "not = [toml" with
       | Ok _ -> fail "an unparsable runtime.toml was committed"
       | Error _ -> ());
      check (list string) "the refused attempt is reported with its path" [ path ] !reported)
;;

let () =
  run "runtime_config_commit_announce"
    [ "commit", [ test_case "every commit attempt reports" `Quick test_every_commit_attempt_reports ] ]
;;
