#use "topfind";;
#require "alcotest";;
#load "unix.cma";;
let with_fault f =
  let saved = Format.pp_get_formatter_out_functions Format.err_formatter () in
  let channel = Unix.out_channel_of_descr (Unix.dup Unix.stderr) in
  Format.pp_set_formatter_out_channel Format.err_formatter channel;
  Fun.protect ~finally:(fun () ->
    Format.pp_set_formatter_out_functions Format.err_formatter saved;
    close_out_noerr channel;
    Format.pp_print_flush Format.err_formatter ())
    (fun () -> close_out_noerr channel; f ());;
let operation () = 42;;
let test_inside () =
  let result = with_fault (fun () ->
    let result = operation () in
    Alcotest.(check int) "the already-correct value" 42 result;
    result) in
  Alcotest.(check int) "result after restoration" 42 result;;
let test_outside () =
  let result = with_fault operation in
  Alcotest.(check int) "the already-correct value" 42 result;;
Alcotest.run ~argv:[|"formatter-probe";"--verbose"|] "Actual Alcotest formatter boundary"
  ["fixture", [Alcotest.test_case "assertions inside closed formatter" `Quick test_inside;
                Alcotest.test_case "assertions after restoration" `Quick test_outside]];;
