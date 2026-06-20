(** [Keeper_memory_os_io.with_out_channel] fd-release guarantee.

    Regression for the write-path fd leak: both [write_file_atomically] and
    [append_line] used to set a [close_attempted] flag BEFORE [close_out], so
    when [close_out]'s internal flush raised (OCaml's [close_out = flush;
    close_out_channel] never reaches the close on flush failure) the exception
    handler skipped the recovery [close_out_noerr] and the descriptor leaked.
    [with_out_channel] now closes via a [Fun.protect] finally, releasing the fd
    on every exit while still propagating the body's exception. *)

open Alcotest
module Io = Masc.Keeper_memory_os_io

(* A closed out_channel raises Sys_error "Bad file descriptor" on further use;
   that is our portable proxy for "the descriptor was released". *)
let channel_is_closed oc =
  try
    output_string oc "x";
    flush oc;
    false
  with
  | Sys_error _ -> true

let test_closes_on_body_exception () =
  let tmp = Filename.temp_file "masc_woc_exn" ".txt" in
  let oc = open_out tmp in
  let raised =
    try
      Io.with_out_channel oc ~f:(fun _ -> failwith "boom");
      false
    with
    | Failure "boom" -> true
  in
  check bool "body exception propagates unchanged" true raised;
  check bool "channel closed after exception (fd released)" true (channel_is_closed oc);
  Sys.remove tmp

let test_writes_and_closes_on_success () =
  let tmp = Filename.temp_file "masc_woc_ok" ".txt" in
  let oc = open_out tmp in
  Io.with_out_channel oc ~f:(fun oc -> output_string oc "hello");
  check bool "channel closed after success" true (channel_is_closed oc);
  let ic = open_in tmp in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  check string "content flushed to disk" "hello" content;
  Sys.remove tmp

let () =
  run
    "keeper_memory_os_io_fd"
    [ ( "with_out_channel"
      , [ test_case "closes the fd when the body raises" `Quick test_closes_on_body_exception
        ; test_case "writes and closes on success" `Quick test_writes_and_closes_on_success
        ] )
    ]
