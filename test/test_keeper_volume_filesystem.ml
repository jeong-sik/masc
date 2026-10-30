open Alcotest
open Masc
module V = Keeper_volume_filesystem

(* Superblocks the kernel wrote on 2026-10-22 for e-masc-the-leader's work
   volume (docs/evidence/2026-10-22-keeper-volume-fsck/): one with the error
   record, and one read after e2fsck while the next guest had the volume
   mounted. The volume has no journal, so a mounted superblock has neither
   state bit set. The expected values are what dumpe2fs 1.47.4 printed for
   the same images, a decoder independent of this one. Each fixture is the
   1024 superblock bytes as hex text, 32 bytes per line. *)
let read_fixture name =
  let hex =
    In_channel.with_open_bin ("fixtures/" ^ name) In_channel.input_all
    |> String.to_seq
    |> Seq.filter (fun c -> c <> '\n')
    |> String.of_seq
  in
  String.init (String.length hex / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (2 * i) 2)))
;;

let errors_superblock () = read_fixture "ext4-superblock-errors.hex"
let clean_superblock () = read_fixture "ext4-superblock-clean.hex"

let pp_site ppf = function
  | None -> Format.pp_print_string ppf "none"
  | Some (site : V.error_site) ->
    Format.fprintf
      ppf
      "{at=%.0f func=%s line=%d inode=%d block=%Ld code=%s}"
      site.at
      site.func
      site.line
      site.inode
      site.block
      (V.error_code_to_string site.code)
;;

let pp_result ppf = function
  | Ok V.Clean -> Format.pp_print_string ppf "Clean"
  | Ok (V.Errors_recorded { count; first; last }) ->
    Format.fprintf ppf "Errors_recorded{count=%d first=%a last=%a}" count pp_site first pp_site last
  | Error failure -> Format.fprintf ppf "Error(%s)" (V.read_failure_to_string failure)
;;

let decoded = testable pp_result ( = )

let kernel_errors =
  Ok
    (V.Errors_recorded
       { count = 31027637
       ; first =
           Some
             { V.at = 1791788800.
             ; func = "ext4_check_bdev_write_error"
             ; line = 227
             ; inode = 0
             ; block = 0L
             ; code = V.Eio
             }
       ; last =
           Some
             { V.at = 1792666771.
             ; func = "ext4_find_extent"
             ; line = 944
             ; inode = 1417672
             ; block = 0L
             ; code = V.Efscorrupted
             }
       })
;;

let with_byte superblock offset value =
  let bytes = Bytes.of_string superblock in
  Bytes.set_uint8 bytes offset value;
  Bytes.to_string bytes
;;

let test_kernel_error_record () =
  check decoded "the record dumpe2fs printed" kernel_errors (V.of_superblock (errors_superblock ()))
;;

let test_repaired_volume_is_clean () =
  check decoded "errors bit cleared by e2fsck" (Ok V.Clean) (V.of_superblock (clean_superblock ()))
;;

(* Real superblocks hold 0 or small numbers in most error fields, so a wrong
   offset there would still decode the fixtures. This one has a distinct
   value in every field, above 2^31 where a field is 32 bits and above 2^32
   where it is 64 bits, and different high time bytes for the two sites. *)
let first_func = "abcdefghijklmnopqrstuvwxyz012345"

let synthetic_superblock ~state =
  let bytes = Bytes.make V.superblock_size '\000' in
  let u32 offset value = Bytes.set_int32_le bytes offset (Int32.of_int value) in
  Bytes.set_uint16_le bytes 0x38 0xEF53;
  Bytes.set_uint16_le bytes 0x3A state;
  u32 0x194 0xFFFF_FFF0;
  u32 0x198 0x89AB_CDEF;
  u32 0x19C 0x8000_0001;
  Bytes.set_int64_le bytes 0x1A0 0x0000_0002_0000_0003L;
  Bytes.blit_string first_func 0 bytes 0x1A8 (String.length first_func);
  u32 0x1C8 0x8000_0007;
  u32 0x1CC 0x1234_5678;
  u32 0x1D0 0x9000_0002;
  u32 0x1D4 0x7000_000B;
  Bytes.set_int64_le bytes 0x1D8 0x0000_0004_0000_0005L;
  Bytes.blit_string "ext4_lookup" 0 bytes 0x1E0 (String.length "ext4_lookup");
  Bytes.set_uint8 bytes 0x278 0x01;
  Bytes.set_uint8 bytes 0x279 0x02;
  Bytes.set_uint8 bytes 0x27A 5;
  Bytes.set_uint8 bytes 0x27B 17;
  Bytes.to_string bytes
;;

let errors_detected = 0x0002
let cleanly_unmounted = 0x0001

let synthetic_errors =
  Ok
    (V.Errors_recorded
       { count = 0xFFFF_FFF0
       ; first =
           Some
             { V.at = float_of_int ((0x01 lsl 32) lor 0x89AB_CDEF)
             ; func = first_func
             ; line = 0x8000_0007
             ; inode = 0x8000_0001
             ; block = 0x0000_0002_0000_0003L
             ; code = V.Efscorrupted
             }
       ; last =
           Some
             { V.at = float_of_int ((0x02 lsl 32) lor 0x1234_5678)
             ; func = "ext4_lookup"
             ; line = 0x7000_000B
             ; inode = 0x9000_0002
             ; block = 0x0000_0004_0000_0005L
             ; code = V.Efault
             }
       })
;;

let test_every_field_at_its_offset () =
  check
    decoded
    "each sentinel"
    synthetic_errors
    (V.of_superblock (synthetic_superblock ~state:errors_detected))
;;

(* Only the errors bit decides: a volume a guest unmounted cleanly has the
   valid bit alone, and a damaged one may have both. *)
let test_state_bits () =
  check
    decoded
    "valid bit alone"
    (Ok V.Clean)
    (V.of_superblock (synthetic_superblock ~state:cleanly_unmounted));
  check
    decoded
    "valid and errors bits"
    synthetic_errors
    (V.of_superblock (synthetic_superblock ~state:(cleanly_unmounted lor errors_detected)))
;;

let test_every_error_code () =
  let expected =
    [ "not_recorded"; "unknown"; "EIO"; "ENOMEM"; "EFSBADCRC"; "EFSCORRUPTED"; "ENOSPC"
    ; "ENOKEY"; "EROFS"; "EFBIG"; "EEXIST"; "ERANGE"; "EOVERFLOW"; "EBUSY"; "ENOTDIR"
    ; "ENOTEMPTY"; "ESHUTDOWN"; "EFAULT"; "code_18"
    ]
  in
  List.iteri
    (fun number name ->
       match
         V.of_superblock (with_byte (synthetic_superblock ~state:errors_detected) 0x27A number)
       with
       | Ok (V.Errors_recorded { first = Some first; _ }) ->
         check string (Printf.sprintf "code %d" number) name (V.error_code_to_string first.code)
       | other -> failf "expected a first error site, got %a" pp_result other)
    expected
;;

let test_function_name_bytes_are_escaped () =
  let superblock =
    List.fold_left
      (fun superblock (offset, value) -> with_byte superblock offset value)
      (synthetic_superblock ~state:errors_detected)
      [ 0x1E0, 0xFF; 0x1E1, 0xFE; 0x1E2, 0 ]
  in
  match V.of_superblock superblock with
  | Ok (V.Errors_recorded { last = Some last; _ } as state) ->
    check string "escaped" "\\255\\254" last.func;
    check
      bool
      "JSON is valid UTF-8"
      true
      (String.is_valid_utf_8 (Yojson.Safe.to_string (V.state_to_yojson state)))
  | other -> failf "expected a last error site, got %a" pp_result other
;;

let test_block_is_unsigned_in_json () =
  let superblock =
    let bytes = Bytes.of_string (synthetic_superblock ~state:errors_detected) in
    Bytes.set_int64_le bytes 0x1A0 0x8000_0000_0000_0001L;
    Bytes.to_string bytes
  in
  match V.of_superblock superblock with
  | Ok state ->
    let block = Yojson.Safe.Util.(V.state_to_yojson state |> member "first" |> member "block") in
    check string "2^63 + 1" "9223372036854775809" (Yojson.Safe.to_string block)
  | Error failure -> failf "expected a superblock, got %s" (V.read_failure_to_string failure)
;;

(* s_first_error_time_hi (0x278) holds bits 32..39 of the first error time. *)
let test_error_time_high_byte () =
  match V.of_superblock (with_byte (errors_superblock ()) 0x278 1) with
  | Ok (V.Errors_recorded { first = Some first; _ }) ->
    check (float 0.) "40-bit time" (4294967296. +. 1791788800.) first.at
  | other -> failf "expected a first error site, got %a" pp_result (other : (V.state, V.read_failure) result)
;;

(* A site whose time field is zero was never recorded. *)
let test_unrecorded_site_is_none () =
  let superblock =
    List.fold_left
      (fun superblock offset -> with_byte superblock offset 0)
      (errors_superblock ())
      [ 0x198; 0x199; 0x19A; 0x19B; 0x278 ]
  in
  match V.of_superblock superblock with
  | Ok (V.Errors_recorded { first; last = Some _; _ }) ->
    check bool "first site absent" true (Option.is_none first)
  | other -> failf "expected errors with only a last site, got %a" pp_result other
;;

let test_unrecognized_error_code_keeps_its_number () =
  match V.of_superblock (with_byte (errors_superblock ()) 0x27A 200) with
  | Ok (V.Errors_recorded { first = Some first; _ }) ->
    check string "raw code kept" "code_200" (V.error_code_to_string first.code)
  | other -> failf "expected a first error site, got %a" pp_result other
;;

let test_other_filesystem_is_not_ext4 () =
  check
    decoded
    "zero magic"
    (Error (V.Not_ext4 { magic = 0 }))
    (V.of_superblock (String.make V.superblock_size '\000'))
;;

let test_short_superblock_is_truncated () =
  check decoded "100 bytes" (Error (V.Truncated { bytes = 100 })) (V.of_superblock (String.sub (errors_superblock ()) 0 100))
;;

let with_temp_image contents f =
  let path = Filename.temp_file "keeper-volume-fs" ".img" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents);
       f path)
;;

let test_read_image_reads_the_primary_superblock () =
  with_temp_image
    (String.make V.superblock_offset '\000' ^ errors_superblock ())
    (fun path -> check decoded "image at offset 1024" kernel_errors (V.read_image ~path))
;;

let test_read_image_short_file () =
  with_temp_image (String.make (V.superblock_offset + 476) '\000') (fun path ->
    check decoded "476 bytes past the offset" (Error (V.Truncated { bytes = 476 })) (V.read_image ~path))
;;

let with_temp_dir f =
  let dir = Filename.temp_dir "keeper-volume-fs" "" in
  Fun.protect ~finally:(fun () -> Sys.rmdir dir) (fun () -> f dir)
;;

(* Opening a named pipe for reading waits for a writer unless the open does
   not block; this test would hang if it did. *)
let test_read_image_refuses_other_file_kinds () =
  with_temp_dir (fun dir ->
    let fifo = Filename.concat dir "pipe" in
    Unix.mkfifo fifo 0o600;
    Fun.protect
      ~finally:(fun () -> Sys.remove fifo)
      (fun () ->
         check
           decoded
           "named pipe"
           (Error (V.Not_regular_file { kind = Unix.S_FIFO }))
           (V.read_image ~path:fifo));
    check
      decoded
      "directory"
      (Error (V.Not_regular_file { kind = Unix.S_DIR }))
      (V.read_image ~path:dir))
;;

let test_read_image_missing_file () =
  match V.read_image ~path:(Filename.concat (Filename.get_temp_dir_name ()) "keeper-volume-fs-absent.img") with
  | Error (V.Unreadable _) -> ()
  | other -> failf "expected Unreadable, got %a" pp_result other
;;

(* The shape container CLI 1.3.1 printed for [volume inspect] on 2026-10-22. *)
let inspect ~format =
  Yojson.Safe.from_string
    (Printf.sprintf
       {|[{"configuration":{"creationDate":"2026-10-02T03:31:37Z","driver":"local","format":"%s","labels":{},"name":"masc-keeper-work-sample","options":{"size":"256g"},"sizeInBytes":274877906944,"source":"/var/volumes/masc-keeper-work-sample/volume.img"},"id":"masc-keeper-work-sample"}]|}
       format)
;;

let image = testable (fun ppf (image : V.image) -> Format.fprintf ppf "%s=%s" image.volume image.source) ( = )

let test_inspect_names_the_ext4_image () =
  check
    (result image (testable (fun ppf failure -> Format.pp_print_string ppf (V.inspect_failure_to_string failure)) ( = )))
    "ext4 source"
    (Ok { V.volume = "masc-keeper-work-sample"; source = "/var/volumes/masc-keeper-work-sample/volume.img" })
    (V.image_of_inspect (inspect ~format:"ext4"))
;;

let test_inspect_refuses_other_formats_and_shapes () =
  let refused name expected json =
    match V.image_of_inspect json with
    | Ok image -> failf "%s: expected a refusal, got %s" name image.source
    | Error failure ->
      check string name (V.inspect_failure_to_string expected) (V.inspect_failure_to_string failure)
  in
  refused
    "xfs"
    (V.Not_ext4_format { volume = "masc-keeper-work-sample"; format = "xfs" })
    (inspect ~format:"xfs");
  refused "no entry" (V.Entries { count = 0 }) (`List []);
  refused "two entries" (V.Entries { count = 2 }) (`List [ `Assoc []; `Assoc [] ]);
  refused "entry not an object" V.Entry_without_configuration (`List [ `Int 1 ]);
  refused
    "configuration without a source"
    V.Configuration_without_fields
    (`List [ `Assoc [ "configuration", `Assoc [ "name", `String "v"; "format", `String "ext4" ] ] ]);
  refused
    "empty source"
    (V.Empty_source { volume = "v" })
    (`List
        [ `Assoc
            [ ( "configuration"
              , `Assoc [ "name", `String "v"; "format", `String "ext4"; "source", `String "" ] )
            ]
        ]);
  refused "not an array" V.Not_an_array (`Assoc [])
;;

let () =
  run
    "keeper_volume_filesystem"
    [ ( "superblock"
      , [ test_case "kernel error record" `Quick test_kernel_error_record
        ; test_case "repaired volume is clean" `Quick test_repaired_volume_is_clean
        ; test_case "every field at its offset" `Quick test_every_field_at_its_offset
        ; test_case "state bits" `Quick test_state_bits
        ; test_case "every error code" `Quick test_every_error_code
        ; test_case "function name bytes escaped" `Quick test_function_name_bytes_are_escaped
        ; test_case "block unsigned in JSON" `Quick test_block_is_unsigned_in_json
        ; test_case "error time high byte" `Quick test_error_time_high_byte
        ; test_case "unrecorded site is none" `Quick test_unrecorded_site_is_none
        ; test_case "unrecognized error code" `Quick test_unrecognized_error_code_keeps_its_number
        ; test_case "other filesystem" `Quick test_other_filesystem_is_not_ext4
        ; test_case "short superblock" `Quick test_short_superblock_is_truncated
        ] )
    ; ( "image"
      , [ test_case "primary superblock" `Quick test_read_image_reads_the_primary_superblock
        ; test_case "short file" `Quick test_read_image_short_file
        ; test_case "other file kinds" `Quick test_read_image_refuses_other_file_kinds
        ; test_case "missing file" `Quick test_read_image_missing_file
        ] )
    ; ( "inspect"
      , [ test_case "ext4 image" `Quick test_inspect_names_the_ext4_image
        ; test_case "other formats and shapes" `Quick test_inspect_refuses_other_formats_and_shapes
        ] )
    ]
;;
