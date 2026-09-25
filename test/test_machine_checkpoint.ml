(* Machine_checkpoint — the slot store every machine lane shares.

   What it pins: a slot is a file name and never a path; a checkpoint reads
   back only as the machine and the format that wrote it; the core identity
   is carried and not compared; a flipped byte, a truncation or garbage is
   refused as corrupt; a replace is atomic (no temporary file stays, and a
   failed write leaves the old checkpoint); and a listing names every slot,
   including one whose header does not read. *)

open Alcotest
module C = Machine_checkpoint

let with_dir f =
  let dir = Filename.temp_dir "masc-machine-checkpoint-" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; dir ])))
    (fun () -> f dir)
;;

let slot s =
  match C.slot_of_string s with
  | Ok slot -> slot
  | Error message -> fail message
;;

let header ?(machine = C.Dos) ?(format = 1) ?(core = "core-a") () =
  { C.machine; format; core }
;;

(* Large enough and repetitive enough that zstd takes it, so the compressed
   path is the one exercised. *)
let machine_bytes = String.concat "" (List.init 4096 (fun i -> string_of_int (i mod 97)))
let meta = `Assoc [ ("steps", `Int 42) ]

let write_ok dir s h =
  match C.write ~dir (slot s) h ~meta ~machine_bytes with
  | Ok () -> ()
  | Error message -> fail message
;;

let read dir s = C.read ~dir (slot s) ~machine:C.Dos ~format:1
let file dir s = C.path ~dir (slot s)
let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let expect_error name pred result =
  match result with
  | Error e when pred e -> ()
  | Error e -> fail (Printf.sprintf "%s: wrong error %s" name (C.error_to_string e))
  | Ok _ -> fail (name ^ ": read")
;;

let test_slot_names () =
  List.iter
    (fun s -> check bool (s ^ " is a slot") true (Result.is_ok (C.slot_of_string s)))
    [ "quick"; "a"; "liu-bei_209-05"; String.make 64 'x' ];
  List.iter
    (fun s -> check bool (Printf.sprintf "%S is refused" s) false (Result.is_ok (C.slot_of_string s)))
    [ ""; String.make 65 'x'; "../up"; "a/b"; "a.b"; "with space"; "슬롯"; "." ]
;;

let test_round_trip () =
  with_dir (fun dir ->
    write_ok dir "one" (header ());
    match read dir "one" with
    | Ok { C.header = h; meta = m; machine_bytes = b } ->
      check string "machine bytes" machine_bytes b;
      check string "meta" (Yojson.Safe.to_string meta) (Yojson.Safe.to_string m);
      check string "core carried" "core-a" h.core;
      check bool "stored compressed" true
        (String.length (read_file (file dir "one")) < String.length machine_bytes)
    | Error e -> fail (C.error_to_string e))
;;

let test_refusals () =
  with_dir (fun dir ->
    expect_error "never saved" (function C.No_slot _ -> true | _ -> false) (read dir "none");
    write_ok dir "msx" (header ~machine:C.Msx ());
    expect_error "another machine"
      (function C.Other_machine { saved = C.Msx; expected = C.Dos } -> true | _ -> false)
      (read dir "msx");
    write_ok dir "v2" (header ~format:2 ());
    expect_error "another format"
      (function C.Other_format { saved = 2; expected = 1 } -> true | _ -> false)
      (read dir "v2");
    write_ok dir "other-core" (header ~core:"core-b" ());
    check bool "another core reads" true (Result.is_ok (read dir "other-core"));
    write_ok dir "flip" (header ());
    let s = read_file (file dir "flip") in
    let b = Bytes.of_string s in
    let last = Bytes.length b - 1 in
    Bytes.set b last (Char.chr (Char.code s.[last] lxor 1));
    write_file (file dir "flip") (Bytes.to_string b);
    expect_error "a flipped byte" (function C.Corrupt _ -> true | _ -> false) (read dir "flip");
    write_ok dir "short" (header ());
    let s = read_file (file dir "short") in
    write_file (file dir "short") (String.sub s 0 (String.length s - 10));
    expect_error "a truncated file" (function C.Corrupt _ -> true | _ -> false) (read dir "short");
    List.iter
      (fun (name, garbage) ->
        write_file (file dir name) garbage;
        expect_error name (function C.Corrupt _ -> true | _ -> false) (read dir name))
      [ ("empty", ""); ("text", "not a checkpoint at all"); ("magic-only", "MASC-MACHINE-CHECKPOINT\000") ])
;;

let test_replace_is_atomic () =
  with_dir (fun dir ->
    write_ok dir "slot" (header ~core:"first" ());
    write_ok dir "slot" (header ~core:"second" ());
    (match read dir "slot" with
     | Ok { C.header = h; _ } -> check string "the second write replaced the first" "second" h.core
     | Error e -> fail (C.error_to_string e));
    check (list string) "no temporary file stays" [ "slot.ckpt" ]
      (Array.to_list (Sys.readdir dir));
    (* A write that cannot finish leaves the old checkpoint whole. A directory
       where the file would go makes the rename fail after the bytes landed. *)
    let blocked = Filename.concat dir "blocked" in
    Sys.mkdir blocked 0o755;
    Sys.mkdir (file blocked "slot") 0o755;
    check bool "the write reports it" true
      (Result.is_error (C.write ~dir:blocked (slot "slot") (header ()) ~meta ~machine_bytes));
    check (list string) "and leaves no temporary file" [ "slot.ckpt" ]
      (Array.to_list (Sys.readdir blocked)))
;;

let test_list () =
  with_dir (fun dir ->
    check int "a missing directory lists nothing" 0
      (match C.list ~dir:(Filename.concat dir "missing") with
       | Ok l -> List.length l
       | Error message -> fail message);
    write_ok dir "b" (header ());
    write_ok dir "a" (header ~machine:C.Msx ~format:3 ());
    write_file (file dir "broken") "garbage";
    write_file (Filename.concat dir "notes.txt") "not a checkpoint name";
    match C.list ~dir with
    | Error message -> fail message
    | Ok listed ->
      check (list string) "every slot, by name" [ "a"; "b"; "broken" ]
        (List.map (fun (l : C.listed) -> C.slot_to_string l.slot) listed);
      (match listed with
       | [ a; b; broken ] ->
         check bool "a header reads" true
           (match a.header with Ok { C.machine = C.Msx; format = 3; _ } -> true | _ -> false);
         check bool "b's too" true (Result.is_ok b.header);
         check bool "a broken one is listed with why" true (Result.is_error broken.header);
         check bool "sizes are the files'" true (b.size > 0)
       | _ -> fail "three rows"))
;;

let () =
  run "machine-checkpoint"
    [ ( "store"
      , [ test_case "slot names" `Quick test_slot_names
        ; test_case "round trip" `Quick test_round_trip
        ; test_case "refusals" `Quick test_refusals
        ; test_case "atomic replace" `Quick test_replace_is_atomic
        ; test_case "list" `Quick test_list
        ] )
    ]
;;
