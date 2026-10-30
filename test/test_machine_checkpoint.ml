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

(* Bytes the listing allocates are the proof it read the front of the file and
   not the file: the fixture is a valid header followed by a 256 MiB sparse
   body, which a whole-file read would allocate and a header read never
   touches. Allocation, not time, so a slow machine cannot fake a pass. *)
let test_list_reads_only_the_header () =
  with_dir (fun dir ->
    write_ok dir "small" (header ~core:"small-core" ());
    let big = file dir "big" in
    let encoded = read_file (file dir "small") in
    let body_bytes = 256 * 1024 * 1024 in
    Out_channel.with_open_bin big (fun oc -> output_string oc encoded);
    let fd = Unix.openfile big [ Unix.O_WRONLY ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.ftruncate fd body_bytes);
    let allocated_before = Gc.allocated_bytes () in
    let listed = match C.list ~dir with Ok l -> l | Error message -> fail message in
    let allocated = Gc.allocated_bytes () -. allocated_before in
    check bool "the listing allocated far less than the body" true
      (allocated < float_of_int (1024 * 1024));
    match listed with
    | [ big_row; small_row ] ->
      check int "the size is the file's, not what was read" body_bytes big_row.size;
      check bool "the big file's header reads" true
        (match big_row.header with Ok { C.core = "small-core"; _ } -> true | _ -> false);
      check bool "and so does the small one's" true (Result.is_ok small_row.header)
    | _ -> fail "two rows")
;;

(* The header's own lengths are not trusted past the end of the file: a length
   no file can honour is a truncation, never an allocation. *)
let test_list_refuses_a_header_that_outgrows_its_file () =
  with_dir (fun dir ->
    let int64_bytes n =
      let b = Bytes.create 8 in
      Bytes.set_int64_be b 0 (Int64.of_int n);
      Bytes.to_string b
    in
    write_file (file dir "liar")
      ("MASC-MACHINE-CHECKPOINT\000" ^ int64_bytes (1 lsl 40) ^ "dos");
    let allocated_before = Gc.allocated_bytes () in
    let listed = match C.list ~dir with Ok l -> l | Error message -> fail message in
    check bool "nothing near the claimed length was allocated" true
      (Gc.allocated_bytes () -. allocated_before < float_of_int (1024 * 1024));
    match listed with
    | [ row ] ->
      check bool "the row says the file is corrupt" true
        (match row.header with Error (C.Corrupt _) -> true | _ -> false)
    | _ -> fail "one row")
;;

(* A copy is the bytes of one slot under another, replaced as a write is: the
   source is never touched, the target is the old file or the whole copy, and
   a file this server cannot decode copies like any other. *)
let test_copy () =
  with_dir (fun dir ->
    write_ok dir "from" (header ~core:"source" ());
    let source_before = Digest.file (file dir "from") in
    write_ok dir "to" (header ~core:"old" ());
    check bool "the copy succeeds" true (Result.is_ok (C.copy ~dir ~from:(slot "from") ~to_:(slot "to")));
    check string "the target is the source's bytes" source_before (Digest.file (file dir "to"));
    check string "the source is untouched" source_before (Digest.file (file dir "from"));
    check (list string) "no temporary file stays" [ "from.ckpt"; "to.ckpt" ]
      (List.sort String.compare (Array.to_list (Sys.readdir dir)));
    write_file (file dir "junk") "not a checkpoint";
    check bool "a file that does not decode copies" true
      (Result.is_ok (C.copy ~dir ~from:(slot "junk") ~to_:(slot "junk-copy")));
    check string "byte for byte" "not a checkpoint" (read_file (file dir "junk-copy")))
;;

let test_copy_failures_leave_the_target () =
  with_dir (fun dir ->
    write_ok dir "to" (header ~core:"old" ());
    let target_before = Digest.file (file dir "to") in
    check bool "a missing source is an error" true
      (Result.is_error (C.copy ~dir ~from:(slot "missing") ~to_:(slot "to")));
    check string "and the target is as it was" target_before (Digest.file (file dir "to"));
    write_ok dir "from" (header ());
    Sys.mkdir (file dir "blocked") 0o755;
    check bool "a target that cannot be replaced is an error" true
      (Result.is_error (C.copy ~dir ~from:(slot "from") ~to_:(slot "blocked")));
    check bool "and the blocker stays a directory" true (Sys.is_directory (file dir "blocked"));
    check (list string) "no temporary file stays" [ "blocked.ckpt"; "from.ckpt"; "to.ckpt" ]
      (List.sort String.compare (Array.to_list (Sys.readdir dir))))
;;

let read_meta dir s = C.read_meta ~dir (slot s) ~machine:C.Dos ~format:1

(* What [read_meta] gives up to stay cheap: the machine bytes never come
   back, so it cannot claim to carry them. What it keeps: the same header,
   the same meta, and the same refusals [read] gives -- checked here against
   [read] on the same files, not restated by hand. *)
let test_read_meta_matches_read_without_the_machine_bytes () =
  with_dir (fun dir ->
    write_ok dir "one" (header ());
    match read_meta dir "one", read dir "one" with
    | Ok { C.header = mh; meta = mm; modified }, Ok { C.header = rh; meta = rm; machine_bytes = _ } ->
      check string "same header core" rh.core mh.core;
      check int "same header format" rh.format mh.format;
      check string "same meta" (Yojson.Safe.to_string rm) (Yojson.Safe.to_string mm);
      check bool "modified is the file's own mtime" true
        (Float.abs (modified -. (Unix.stat (file dir "one")).Unix.st_mtime) < 1.0)
    | Error e, _ | _, Error e -> fail (C.error_to_string e))
;;

let test_read_meta_refusals_match_read () =
  with_dir (fun dir ->
    check bool "never saved" true
      (match read_meta dir "none", read dir "none" with
       | Error (C.No_slot _), Error (C.No_slot _) -> true
       | _ -> false);
    write_ok dir "msx" (header ~machine:C.Msx ());
    check bool "another machine" true
      (match read_meta dir "msx", read dir "msx" with
       | Error (C.Other_machine _ as a), Error (C.Other_machine _ as b) ->
         String.equal (C.error_to_string a) (C.error_to_string b)
       | _ -> false);
    write_ok dir "v2" (header ~format:2 ());
    check bool "another format" true
      (match read_meta dir "v2", read dir "v2" with
       | Error (C.Other_format _ as a), Error (C.Other_format _ as b) ->
         String.equal (C.error_to_string a) (C.error_to_string b)
       | _ -> false);
    write_ok dir "flip" (header ());
    let s = read_file (file dir "flip") in
    let b = Bytes.of_string s in
    let last = Bytes.length b - 1 in
    Bytes.set b last (Char.chr (Char.code s.[last] lxor 1));
    write_file (file dir "flip") (Bytes.to_string b);
    check bool "a flipped byte" true
      (match read_meta dir "flip" with Error (C.Corrupt _) -> true | _ -> false))
;;

(* The slot a checkpoint call names. The MSX tool and its HTTP route both read
   their arguments through this one definition. *)
let test_slot_of_arguments () =
  let named json =
    match C.slot_of_arguments ~default:"quick" json with
    | Ok slot -> Some (C.slot_to_string slot)
    | Error _ -> None in
  check (option string) "no field is the default" (Some "quick") (named (`Assoc []));
  check (option string) "a named slot" (Some "campaign-2")
    (named (`Assoc [ "slot", `String "campaign-2" ]));
  List.iter (fun (label, json) -> check (option string) label None (named json))
    [ "a slot that is not a string", `Assoc [ "slot", `Int 3 ]
    ; "a slot that is a path", `Assoc [ "slot", `String "../escape" ]
    ; "an empty slot", `Assoc [ "slot", `String "" ]
    ; "a slot of 65 characters", `Assoc [ "slot", `String (String.make 65 'a') ]
    ; "two slot fields", `Assoc [ "slot", `String "a"; "slot", `String "b" ]
    ; "another field", `Assoc [ "extra", `Bool true ]
    ; "a field beside the slot", `Assoc [ "slot", `String "a"; "extra", `Bool true ]
    ; "arguments that are not an object", `List [] ];
  check bool "a default that is not a valid slot is an error, not a silent pass" true
    (Result.is_error (C.slot_of_arguments ~default:"not a slot" (`Assoc [])))

let () =
  run "machine-checkpoint"
    [ ( "store"
      , [ test_case "slot names" `Quick test_slot_names
        ; test_case "slot of arguments" `Quick test_slot_of_arguments
        ; test_case "round trip" `Quick test_round_trip
        ; test_case "refusals" `Quick test_refusals
        ; test_case "atomic replace" `Quick test_replace_is_atomic
        ; test_case "copy" `Quick test_copy
        ; test_case "a failed copy leaves the target" `Quick test_copy_failures_leave_the_target
        ; test_case "list" `Quick test_list
        ; test_case "list reads only the header" `Quick test_list_reads_only_the_header
        ; test_case "list refuses a header that outgrows its file" `Quick
            test_list_refuses_a_header_that_outgrows_its_file
        ; test_case "read_meta matches read" `Quick
            test_read_meta_matches_read_without_the_machine_bytes
        ; test_case "read_meta refusals match read" `Quick test_read_meta_refusals_match_read
        ] )
    ]
;;
