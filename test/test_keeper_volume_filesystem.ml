open Alcotest
open Masc
module V = Keeper_volume_filesystem

(* Superblocks the kernel wrote on 2026-10-22: e-masc-the-leader's work volume
   before and after e2fsck (docs/evidence/2026-10-22-keeper-volume-fsck/). The
   expected values are what dumpe2fs 1.47.4 printed for the same images, a
   decoder independent of this one. Each fixture is the 1024 superblock bytes
   as hex text, 32 bytes per line. *)
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
    (result image string)
    "ext4 source"
    (Ok { V.volume = "masc-keeper-work-sample"; source = "/var/volumes/masc-keeper-work-sample/volume.img" })
    (V.image_of_inspect (inspect ~format:"ext4"))
;;

let test_inspect_refuses_other_formats_and_shapes () =
  let refused json = Result.is_error (V.image_of_inspect json) in
  check bool "xfs" true (refused (inspect ~format:"xfs"));
  check bool "no entry" true (refused (`List []));
  check bool "not an array" true (refused (`Assoc []))
;;

let () =
  run
    "keeper_volume_filesystem"
    [ ( "superblock"
      , [ test_case "kernel error record" `Quick test_kernel_error_record
        ; test_case "repaired volume is clean" `Quick test_repaired_volume_is_clean
        ; test_case "error time high byte" `Quick test_error_time_high_byte
        ; test_case "unrecorded site is none" `Quick test_unrecorded_site_is_none
        ; test_case "unrecognized error code" `Quick test_unrecognized_error_code_keeps_its_number
        ; test_case "other filesystem" `Quick test_other_filesystem_is_not_ext4
        ; test_case "short superblock" `Quick test_short_superblock_is_truncated
        ] )
    ; ( "image"
      , [ test_case "primary superblock" `Quick test_read_image_reads_the_primary_superblock
        ; test_case "short file" `Quick test_read_image_short_file
        ; test_case "missing file" `Quick test_read_image_missing_file
        ] )
    ; ( "inspect"
      , [ test_case "ext4 image" `Quick test_inspect_names_the_ext4_image
        ; test_case "other formats and shapes" `Quick test_inspect_refuses_other_formats_and_shapes
        ] )
    ]
;;
