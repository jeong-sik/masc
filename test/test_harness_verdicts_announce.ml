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
      Eval_calibration.install_written_observer (fun () -> ());
      Eval_calibration.For_testing.reset_store ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      Eval_calibration.For_testing.set_store ~base_path;
      let written = ref 0 in
      Eval_calibration.install_written_observer (fun () -> incr written);
      Eval_calibration.record_human_label ~notes_hash:"0123" ~human_verdict:Eval_calibration.Approve_label
        ~labeler:"operator" ~reason:"matches the evidence";
      check int "the appended label is reported" 1 !written;
      Eval_calibration.record_human_label ~notes_hash:"4567" ~human_verdict:Eval_calibration.Reject_label
        ~labeler:"operator" ~reason:"missed a step";
      check int "each append is reported" 2 !written)
;;

let () =
  run "harness_verdicts_announce"
    [ "store", [ test_case "a label append reports once" `Quick test_a_label_append_reports_once ] ]
;;
