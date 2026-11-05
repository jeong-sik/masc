(* RFC-0480 §3.4: the judge calibration store reports each record it appends,
   so the server can tell the Harness readers. *)

open Alcotest
open Masc

let test_a_label_append_reports_once () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "harness-announce-" "") in
  Fun.protect
    ~finally:(fun () ->
      Eval_calibration.install_written_observer (fun ~base_path:_ -> ());
      Fs_compat.remove_tree base_path)
    (fun () ->
      (* The observer reports the workspace the store belongs to: the
         announcement of a verdict names that workspace, so the test keeps
         what it heard. *)
      let heard = ref [] in
      Eval_calibration.install_written_observer (fun ~base_path:seen ->
        heard := seen :: !heard);
      Eval_calibration.record_human_label ~base_path ~notes_hash:"0123"
        ~human_verdict:Eval_calibration.Approve_label
        ~labeler:"operator" ~reason:"matches the evidence";
      Eval_calibration.record_human_label ~base_path ~notes_hash:"4567"
        ~human_verdict:Eval_calibration.Reject_label
        ~labeler:"operator" ~reason:"missed a step";
      check (list string) "each append reports the record's workspace"
        [ base_path; base_path ] !heard)
;;

let () =
  run "harness_verdicts_announce"
    [ "store", [ test_case "a label append reports once" `Quick test_a_label_append_reports_once ] ]
;;
