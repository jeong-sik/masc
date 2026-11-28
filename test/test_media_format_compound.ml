(* Compound File formats: DOC, XLS, PPT, HWP and encrypted Office Open XML,
   read from the streams under the root storage. The files are built here by
   a small version 3 writer, so each damaged shape is exact: the FAT is
   sector 0, the directory starts at sector 1, then the mini FAT, the mini
   stream and the regular streams follow in that order. *)

open Alcotest
module C = Compound_file
module M = Media_format

let fixture name =
  In_channel.with_open_bin ("fixtures/media_format/" ^ name) In_channel.input_all
;;

type item =
  | Stream of string * string
  | Storage of string * (string * string) list

let sector_bytes = 512
let free = 0xFFFFFFFF
let end_of_chain = 0xFFFFFFFE
let no_stream = 0xFFFFFFFF
let set32 b offset v = Bytes.set_int32_le b offset (Int32.of_int (v land 0xFFFF_FFFF))
let set16 b offset v = Bytes.set_uint16_le b offset v
let le16 v = String.init 2 (fun k -> Char.chr ((v lsr (8 * k)) land 0xff))
let le32 v = String.init 4 (fun k -> Char.chr ((v lsr (8 * k)) land 0xff))
let sectors_for n unit = (n + unit - 1) / unit

let cfb items =
  (* Directory entries in id order: root, then each item, a storage's
     streams right after it. Siblings link through [right]. *)
  let entries = ref [ "Root Entry", 5, None ] in
  let add name kind data = entries := (name, kind, data) :: !entries in
  let links = Hashtbl.create 8 in
  let chain_ids ids = List.iteri (fun i id -> Hashtbl.replace links id (List.nth_opt ids (i + 1))) ids in
  let id () = List.length !entries in
  let top =
    List.map
      (function
        | Stream (name, data) ->
          let me = id () in
          add name 2 (Some data);
          me, None
        | Storage (name, streams) ->
          let me = id () in
          add name 1 None;
          let children =
            List.map
              (fun (name, data) ->
                 let child = id () in
                 add name 2 (Some data);
                 child)
              streams
          in
          chain_ids children;
          me, List.nth_opt children 0)
      items
  in
  chain_ids (List.map fst top);
  let entries = Array.of_list (List.rev !entries) in
  let count = Array.length entries in
  let mini = Buffer.create 256 and mini_fat = ref [] and regular = ref [] in
  let starts = Array.make count end_of_chain in
  Array.iteri
    (fun i (_, _, data) ->
       match data with
       | Some data when String.length data < 4096 && String.length data > 0 ->
         let first = Buffer.length mini / 64 in
         let n = sectors_for (String.length data) 64 in
         starts.(i) <- first;
         Buffer.add_string mini data;
         Buffer.add_string mini (String.make ((n * 64) - String.length data) '\000');
         mini_fat := !mini_fat @ List.init n (fun k -> if k = n - 1 then end_of_chain else first + k + 1)
       | Some data when String.length data >= 4096 -> regular := !regular @ [ i, data ]
       | Some _ | None -> ())
    entries;
  let directory_sectors = sectors_for count 4 in
  let has_mini = Buffer.length mini > 0 in
  let mini_fat_sector = 1 + directory_sectors in
  let mini_stream_sector = mini_fat_sector + if has_mini then 1 else 0 in
  let mini_stream_sectors = sectors_for (Buffer.length mini) sector_bytes in
  let next = ref (mini_stream_sector + mini_stream_sectors) in
  let fat = Array.make 128 free in
  let run first n = for k = 0 to n - 1 do fat.(first + k) <- (if k = n - 1 then end_of_chain else first + k + 1) done in
  fat.(0) <- 0xFFFFFFFD;
  run 1 directory_sectors;
  if has_mini then (run mini_fat_sector 1; run mini_stream_sector mini_stream_sectors);
  let placed =
    List.map
      (fun (i, data) ->
         let first = !next and n = sectors_for (String.length data) sector_bytes in
         starts.(i) <- first;
         run first n;
         next := first + n;
         first, data)
      !regular
  in
  let b = Bytes.make ((!next + 1) * sector_bytes) '\000' in
  Bytes.blit_string C.signature 0 b 0 8;
  set16 b 0x18 0x3E;
  set16 b 0x1A 3;
  set16 b 0x1C 0xFFFE;
  set16 b 0x1E 9;
  set16 b 0x20 6;
  set32 b 0x2C 1;
  set32 b 0x30 1;
  set32 b 0x38 4096;
  set32 b 0x3C (if has_mini then mini_fat_sector else end_of_chain);
  set32 b 0x40 (if has_mini then 1 else 0);
  set32 b 0x44 end_of_chain;
  for k = 0 to 108 do set32 b (0x4C + (4 * k)) (if k = 0 then 0 else free) done;
  let at sector = (sector + 1) * sector_bytes in
  Array.iteri (fun k v -> set32 b (at 0 + (4 * k)) v) fat;
  Array.iteri
    (fun i (name, kind, data) ->
       let o = at 1 + (i * 128) in
       String.iteri (fun k c -> set16 b (o + (2 * k)) (Char.code c)) name;
       set16 b (o + 0x40) ((String.length name + 1) * 2);
       Bytes.set b (o + 0x42) (Char.chr kind);
       Bytes.set b (o + 0x43) '\001';
       set32 b (o + 0x44) no_stream;
       set32 b (o + 0x48) (Option.value ~default:no_stream (Option.join (Hashtbl.find_opt links i)));
       let child =
         if i = 0 then Option.map fst (List.nth_opt top 0)
         else Option.join (List.assoc_opt i top)
       in
       set32 b (o + 0x4C) (Option.value ~default:no_stream child);
       let start, size =
         if i = 0 then (if has_mini then mini_stream_sector else end_of_chain), Buffer.length mini
         else starts.(i), Option.fold ~none:0 ~some:String.length data
       in
       set32 b (o + 0x74) start;
       set32 b (o + 0x78) size)
    entries;
  (* Unused directory slots stay zero, which reads as unallocated with
     sibling 0; point them nowhere. *)
  for i = count to (directory_sectors * 4) - 1 do
    let o = at 1 + (i * 128) in
    set32 b (o + 0x44) no_stream; set32 b (o + 0x48) no_stream; set32 b (o + 0x4C) no_stream
  done;
  if has_mini then (
    List.iteri (fun k v -> set32 b (at mini_fat_sector + (4 * k)) v) !mini_fat;
    for k = List.length !mini_fat to 127 do set32 b (at mini_fat_sector + (4 * k)) free done;
    Bytes.blit_string (Buffer.contents mini) 0 b (at mini_stream_sector) (Buffer.length mini));
  List.iter (fun (first, data) -> Bytes.blit_string data 0 b (at first) (String.length data)) placed;
  Bytes.to_string b
;;

let patch bytes offset value =
  let b = Bytes.of_string bytes in
  Bytes.blit_string value 0 b offset (String.length value);
  Bytes.to_string b
;;

let describe = function
  | M.Document format -> "document " ^ Document_format.extension format
  | M.Encrypted (Some format) -> "encrypted " ^ Document_format.extension format
  | M.Encrypted None -> "encrypted ?"
  | M.Unknown No_document_signature -> "no_document_signature"
  | M.Unknown (Zip_package _) -> "zip_package"
  | M.Unknown (Compound_file fault) ->
    (match fault with
     | Compound _ -> "compound"
     | No_document_stream -> "no_document_stream"
     | Several_document_streams names -> "several " ^ String.concat "," names
     | Missing_stream name -> "missing " ^ name
     | Short_stream { name; bytes } -> Printf.sprintf "short %s %d" name bytes
     | Workbook_without_bof -> "workbook_without_bof"
     | Unknown_header_token token -> Printf.sprintf "token %x" token
     | Current_edit_past_end { offset } -> Printf.sprintf "current_edit_past_end %d" offset
     | Not_a_user_edit_atom { offset; record_type; length } ->
       Printf.sprintf "not_user_edit %d %x %x" offset record_type length)
;;

let expect expected items = check string expected expected (describe (M.detect (cfb items)))

(* Stream contents *)

let fib ?(size = 64) ~encrypted () =
  let b = Bytes.make size '\000' in
  set16 b 0 0xA5EC;
  set16 b 2 0x00C1;
  set16 b 0x0A (if encrypted then 0x0100 lor 0x0200 else 0x0200);
  Bytes.to_string b
;;

let record kind body = le16 kind ^ le16 (String.length body) ^ body
let bof = record 0x0809 (String.make 16 '\000')
let file_pass = record 0x002F (String.make 54 '\001')
let write_protect = record 0x0086 ""
let code_page = record 0x0042 (le16 1200)
let current_user ~edit token =
  le16 0 ^ le16 0x0FF6 ^ le32 20 ^ le32 20 ^ le32 token ^ le32 edit ^ String.make 4 '\000'
;;

(* A UserEditAtom: 0x1C bytes, or 0x20 with encryptSessionPersistIdRef. *)
let user_edit length = le16 0 ^ le16 0x0FF5 ^ le32 length ^ String.make length '\000'

let powerpoint ?(before = 40) ?(edit_length = 0x1C) ?edit token =
  let edit = Option.value edit ~default:before in
  [ Stream ("PowerPoint Document", String.make before 'p' ^ user_edit edit_length)
  ; Stream ("Current User", current_user ~edit token)
  ]
;;

let hwp_header ?(signature = "HWP Document File") properties =
  signature ^ String.make (32 - String.length signature) '\000' ^ le32 0x05000300 ^ le32 properties
  ^ String.make 216 '\000'
;;

let test_word () =
  expect "document .doc" [ Stream ("WordDocument", fib ~encrypted:false ()) ];
  expect "encrypted .doc" [ Stream ("WordDocument", fib ~encrypted:true ()) ];
  expect "document .doc" [ Stream ("WORDDOCUMENT", fib ~encrypted:false ()) ];
  expect "encrypted .doc" [ Stream ("WordDocument", fib ~size:5000 ~encrypted:true ()) ];
  expect "short WordDocument 8" [ Stream ("WordDocument", String.make 8 '\000') ]
;;

let test_excel () =
  expect "document .xls" [ Stream ("Workbook", bof ^ code_page) ];
  expect "encrypted .xls" [ Stream ("Workbook", bof ^ file_pass) ];
  expect "encrypted .xls" [ Stream ("Workbook", bof ^ write_protect ^ file_pass) ];
  expect "document .xls" [ Stream ("Workbook", bof ^ write_protect ^ code_page) ];
  expect "encrypted .xls" [ Stream ("Book", bof ^ file_pass) ];
  expect "document .xls" [ Stream ("Book", bof ^ code_page); Stream ("Workbook", bof ^ code_page) ];
  expect "workbook_without_bof" [ Stream ("Workbook", code_page ^ bof) ];
  expect "short Workbook 20" [ Stream ("Workbook", bof) ];
  expect
    "document .xls"
    [ Stream ("Workbook", bof ^ code_page)
    ; Storage ("ObjectPool", [ "WordDocument", fib ~encrypted:false () ])
    ]
;;

let test_powerpoint () =
  expect "document .ppt" (powerpoint 0xE391C05F);
  expect "encrypted .ppt" (powerpoint 0xF3D1C4DF);
  (* PowerPoint 2002 keeps the plain token on an encrypted file. *)
  expect "encrypted .ppt" (powerpoint ~edit_length:0x20 0xE391C05F);
  (* The current edit past the mini stream cutoff, across sector edges. *)
  expect "encrypted .ppt" (powerpoint ~before:6000 ~edit_length:0x20 0xE391C05F);
  expect "document .ppt" (powerpoint ~before:6000 0xE391C05F);
  expect "not_user_edit 0 7070 70707070" (powerpoint ~edit:0 0xE391C05F);
  expect "not_user_edit 40 ff5 24" (powerpoint ~edit_length:0x24 0xE391C05F);
  expect "current_edit_past_end 70" (powerpoint ~edit:70 0xE391C05F);
  expect "current_edit_past_end 4294967295" (powerpoint ~edit:0xFFFFFFFF 0xE391C05F);
  expect "token 12345678" (powerpoint 0x12345678);
  expect "missing Current User" [ Stream ("PowerPoint Document", String.make 40 '\000') ]
;;

let test_hwp () =
  expect "document .hwp" [ Stream ("FileHeader", hwp_header 0x01) ];
  expect "encrypted .hwp" [ Stream ("FileHeader", hwp_header 0x03) ];
  (* Distribution documents (bit 2) carry their key and open without a
     password. *)
  expect "document .hwp" [ Stream ("FileHeader", hwp_header 0x05) ];
  (* DRM (bit 4), certificate encryption (bit 8) and certificate DRM (bit 10)
     encrypt the body too; a certificate signature (bit 7) does not. *)
  List.iter
    (fun properties -> expect "encrypted .hwp" [ Stream ("FileHeader", hwp_header properties) ])
    [ 0x11; 0x101; 0x401 ];
  expect "document .hwp" [ Stream ("FileHeader", hwp_header 0x81) ];
  expect "no_document_stream" [ Stream ("FileHeader", hwp_header ~signature:"Other File" 0x01) ];
  expect "short FileHeader 20" [ Stream ("FileHeader", String.sub (hwp_header 0x01) 0 20) ]
;;

let test_claims () =
  expect "encrypted ?" [ Stream ("EncryptionInfo", String.make 200 'i'); Stream ("EncryptedPackage", String.make 5000 'p') ];
  expect "no_document_stream" [ Stream ("EncryptionInfo", String.make 200 'i') ];
  expect "no_document_stream" [ Stream ("SummaryInformation", String.make 100 's') ];
  expect
    "several WordDocument,Workbook"
    [ Stream ("WordDocument", fib ~encrypted:false ()); Stream ("Workbook", bof ^ code_page) ]
;;

(* Reader faults, on the Compound_file interface itself *)

let reader_fault bytes =
  match C.read bytes with
  | Ok file ->
    (match C.stream_slice file "WordDocument" ~offset:0 ~max_bytes:6000 with
     | Ok _ -> "ok"
     | Error fault -> "prefix " ^ (match fault with
       | C.Short_stream { read; declared; _ } -> Printf.sprintf "short %d of %d" read declared
       | Chain_cycle _ -> "chain_cycle" | Bad_sector { sector } -> Printf.sprintf "bad_sector %d" sector
       | Truncated_header | Bad_header _ | Bad_directory _ -> "other"))
  | Error fault ->
    (match fault with
     | C.Truncated_header -> "truncated_header"
     | Bad_header _ -> "bad_header"
     | Bad_sector { sector } -> Printf.sprintf "bad_sector %d" sector
     | Chain_cycle _ -> "chain_cycle"
     | Bad_directory _ -> "bad_directory"
     | Short_stream _ -> "short_stream")
;;

(* One 5000-byte stream: directory in sector 1, data in sectors 2..11, so FAT
   entry [k] sits at 512 + 4k. The stream's directory entry is entry 1. *)
let single = cfb [ Stream ("WordDocument", String.make 5000 'w') ]
let fat_entry k = sector_bytes + (4 * k)
let stream_entry field = (2 * sector_bytes) + 128 + field

let test_reader_faults () =
  let fault = reader_fault in
  check string "whole" "ok" (fault single);
  check (list string) "root streams" [ "WordDocument" ] (Result.fold ~ok:C.root_streams ~error:(fun _ -> []) (C.read single));
  check string "truncated" "truncated_header" (fault (String.sub single 0 100));
  check string "byte order" "bad_header" (fault (patch single 0x1C (le16 0xFEFF)));
  check string "version" "bad_header" (fault (patch single 0x1A (le16 5)));
  check string "cutoff" "bad_header" (fault (patch single 0x38 (le32 8192)));
  check string "cycle" "prefix chain_cycle" (fault (patch single (fat_entry 3) (le32 2)));
  check string "out of range" "prefix bad_sector 200" (fault (patch single (fat_entry 3) (le32 200)));
  check string "declared longer" "prefix short 5120 of 6000" (fault (patch single (stream_entry 0x78) (le32 6000)));
  check string "sibling cycle" "bad_directory" (fault (patch single (stream_entry 0x48) (le32 1)));
  check string "sibling past the end" "bad_directory" (fault (patch single (stream_entry 0x48) (le32 9)));
  check string "size past the file" "bad_directory" (fault (patch single (stream_entry 0x78) (le32 100_000)));
  (* Version 4, 4096-byte sectors: a FileHeader whose size has its high dword
     set, which a 63-bit shift turned negative. A review generator wrote it. *)
  check string "v4 size past 63 bits" "bad_directory" (fault (fixture "v4-size-past-63-bits.cfb"));
  check string "fat count" "bad_header" (fault (patch single 0x2C (le32 100_000)));
  (* A 200-byte stream in the mini stream: mini FAT in sector 2. *)
  let small = cfb [ Stream ("WordDocument", String.make 200 'w') ] in
  check string "mini whole" "ok" (fault small);
  check string "mini cycle" "prefix chain_cycle" (fault (patch small ((3 * sector_bytes) + 4) (le32 0)));
  let root_entry field = (2 * sector_bytes) + field in
  check string "child is the root" "bad_directory" (fault (patch single (root_entry 0x4C) (le32 0)));
  (* Sector 11 moved to the middle of the chain (2, 11, 3 ... 10) and the
     file cut 450 bytes into it. The 62 missing bytes fit in the last
     sector's slack, so copying on past the gap would return 5000 bytes. *)
  let reordered =
    patch (patch (patch single (fat_entry 2) (le32 11)) (fat_entry 11) (le32 3)) (fat_entry 10) (le32 end_of_chain)
  in
  check string "sector cut mid-chain" "prefix short 962 of 5000" (fault (String.sub reordered 0 ((12 * sector_bytes) + 450)))
;;

let slice bytes ~offset ~max_bytes =
  match C.read bytes with
  | Error _ -> Alcotest.fail "the file does not read"
  | Ok file ->
    (match C.stream_slice file "WordDocument" ~offset ~max_bytes with
     | Ok (Some data) -> data
     | Ok None -> Alcotest.fail "no WordDocument"
     | Error _ -> Alcotest.fail "the slice fails")
;;

let test_stream_slice () =
  let content length = String.init length (fun i -> Char.chr (i mod 251)) in
  List.iter
    (fun (label, length, offset, max_bytes) ->
       let data = content length in
       let first = min (max 0 offset) length in
       let expected = String.sub data first (min (max 0 max_bytes) (length - first)) in
       check string label expected (slice (cfb [ Stream ("WordDocument", data) ]) ~offset ~max_bytes))
    [ "regular, across a sector edge", 5000, 508, 10
    ; "regular, the tail", 5000, 4990, 100
    ; "mini, across a mini sector edge", 200, 60, 10
    ; "mini, the tail", 200, 195, 100
    ; "past the end", 200, 300, 10
    ; "negative bytes", 200, 0, -1
    ; "negative offset", 200, -5, 4
    ]
;;

(* Every byte string gets an answer. Flipping or cutting bytes of Compound
   Files never raises; the seed is fixed so a failure reproduces. *)
let test_mutations_always_answer () =
  let state = Random.State.make [| 20261128 |] in
  let mutate seed =
    let b = Bytes.of_string seed in
    for _ = 1 to 1 + Random.State.int state 6 do
      Bytes.set b (Random.State.int state (Bytes.length b)) (Char.chr (Random.State.int state 256))
    done;
    let s = Bytes.to_string b in
    if Random.State.int state 20 = 0 then String.sub s 0 (Random.State.int state (String.length s)) else s
  in
  List.iter
    (fun (name, seed) ->
       for _ = 1 to 2000 do
         let input = mutate seed in
         match M.detect input with
         | M.Document _ | M.Encrypted _ | M.Unknown _ -> ()
         | exception e -> Alcotest.failf "%s mutation raised %s" name (Printexc.to_string e)
       done)
    [ "word", single
    ; "mini stream", cfb [ Stream ("WordDocument", fib ~encrypted:false ()) ]
    ; "excel", cfb [ Stream ("Workbook", bof ^ write_protect ^ file_pass) ]
    ; "powerpoint", cfb (powerpoint 0xE391C05F)
    ; "powerpoint 2002", cfb (powerpoint ~before:6000 ~edit_length:0x20 0xE391C05F)
    ; "hwp", cfb [ Stream ("FileHeader", hwp_header 0x01); Stream ("BodyText", String.make 5000 'b') ]
    ; "v4", fixture "v4-size-past-63-bits.cfb"
    ]
;;

let () =
  run
    "media_format_compound"
    [ ( "formats"
      , [ test_case "word" `Quick test_word
        ; test_case "excel" `Quick test_excel
        ; test_case "powerpoint" `Quick test_powerpoint
        ; test_case "hwp" `Quick test_hwp
        ; test_case "claims" `Quick test_claims
        ] )
    ; ( "reader"
      , [ test_case "faults" `Quick test_reader_faults
        ; test_case "stream slice" `Quick test_stream_slice
        ; test_case "mutations always answer" `Quick test_mutations_always_answer
        ] )
    ]
;;
