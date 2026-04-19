(* Head+tail truncating accumulator: property + golden tests. *)

open Masc_exec

let check_eq ctx expected actual =
  Alcotest.(check string) ctx expected actual

let check_int ctx expected actual =
  Alcotest.(check int) ctx expected actual

(* Small inputs fit fully inside head_cap and render byte-identical. *)
let test_small_input_no_truncation () =
  let b = Exec_buffer.create ~head_cap:16 ~tail_cap:16 in
  Exec_buffer.add_string b "hello, world";
  check_int "total" 12 (Exec_buffer.total_bytes b);
  check_int "dropped" 0 (Exec_buffer.bytes_dropped b);
  check_eq "render" "hello, world" (Exec_buffer.render b)

(* Input exactly equal to head_cap + tail_cap — no truncation,
   separator must not appear. *)
let test_boundary_no_separator () =
  let b = Exec_buffer.create ~head_cap:4 ~tail_cap:4 in
  Exec_buffer.add_string b "aabbccdd";
  check_int "total" 8 (Exec_buffer.total_bytes b);
  check_int "dropped" 0 (Exec_buffer.bytes_dropped b);
  check_eq "render" "aabbccdd" (Exec_buffer.render b)

(* Middle elision: head, tail, and "(truncated N bytes)" separator. *)
let test_truncation_separator () =
  let b = Exec_buffer.create ~head_cap:4 ~tail_cap:4 in
  Exec_buffer.add_string b "HEADxxxxxxxxxxxxxxTAIL";
  let n = String.length "HEADxxxxxxxxxxxxxxTAIL" in
  check_int "total" n (Exec_buffer.total_bytes b);
  check_eq "head" "HEAD" (Exec_buffer.head b);
  check_eq "tail" "TAIL" (Exec_buffer.tail b);
  let expected =
    Printf.sprintf "HEAD\n...(truncated %d bytes)...\nTAIL"
      (Exec_buffer.bytes_dropped b)
  in
  check_eq "render" expected (Exec_buffer.render b)

(* Ring buffer must reflect only the most-recent tail_cap bytes even
   after many writes. *)
let test_tail_ring_rotates () =
  let b = Exec_buffer.create ~head_cap:0 ~tail_cap:5 in
  for i = 1 to 20 do
    Exec_buffer.add_string b (Printf.sprintf "%d" (i mod 10))
  done;
  check_int "total" 20 (Exec_buffer.total_bytes b);
  check_eq "last 5" "67890" (Exec_buffer.tail b)

(* 1 MB input with 512-byte caps — realistic head/tail budget. *)
let test_large_stream_caps () =
  let head_cap = 512 and tail_cap = 512 in
  let b = Exec_buffer.create ~head_cap ~tail_cap in
  let chunk = Bytes.make 4096 'x' in
  for _ = 1 to 256 do
    Exec_buffer.add_bytes b chunk 0 (Bytes.length chunk)
  done;
  check_int "total" (256 * 4096) (Exec_buffer.total_bytes b);
  check_int "head retained" head_cap
    (String.length (Exec_buffer.head b));
  check_int "tail retained" tail_cap
    (String.length (Exec_buffer.tail b));
  let drop_expected = (256 * 4096) - head_cap - tail_cap in
  check_int "dropped" drop_expected (Exec_buffer.bytes_dropped b)

(* Zero head_cap: only tail is kept. *)
let test_head_cap_zero () =
  let b = Exec_buffer.create ~head_cap:0 ~tail_cap:4 in
  Exec_buffer.add_string b "abcdefg";
  check_eq "head empty" "" (Exec_buffer.head b);
  check_eq "tail last 4" "defg" (Exec_buffer.tail b);
  check_eq "render" "\n...(truncated 3 bytes)...\ndefg" (Exec_buffer.render b)

(* Negative caps rejected. *)
let test_negative_caps_rejected () =
  (try
     let _ = Exec_buffer.create ~head_cap:(-1) ~tail_cap:4 in
     Alcotest.fail "negative head_cap not rejected"
   with Invalid_argument _ -> ());
  (try
     let _ = Exec_buffer.create ~head_cap:4 ~tail_cap:(-1) in
     Alcotest.fail "negative tail_cap not rejected"
   with Invalid_argument _ -> ())

(* add_bytes out-of-range rejected. *)
let test_add_bytes_oob () =
  let b = Exec_buffer.create ~head_cap:8 ~tail_cap:8 in
  let buf = Bytes.of_string "abcd" in
  try
    Exec_buffer.add_bytes b buf 2 10;
    Alcotest.fail "oob not rejected"
  with Invalid_argument _ -> ()

let () =
  test_small_input_no_truncation ();
  test_boundary_no_separator ();
  test_truncation_separator ();
  test_tail_ring_rotates ();
  test_large_stream_caps ();
  test_head_cap_zero ();
  test_negative_caps_rejected ();
  test_add_bytes_oob ();
  print_endline "exec_buffer: 8/8 passed"
