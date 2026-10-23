type error_code =
  | Not_recorded
  | Unknown
  | Eio
  | Enomem
  | Efsbadcrc
  | Efscorrupted
  | Enospc
  | Enokey
  | Erofs
  | Efbig
  | Eexist
  | Erange
  | Eoverflow
  | Ebusy
  | Enotdir
  | Enotempty
  | Eshutdown
  | Efault
  | Unrecognized of int

type error_site =
  { at : float
  ; func : string
  ; line : int
  ; inode : int
  ; block : Int64.t
  ; code : error_code
  }

type state =
  | Clean
  | Errors_recorded of
      { count : int
      ; first : error_site option
      ; last : error_site option
      }

type read_failure =
  | Not_ext4 of { magic : int }
  | Truncated of { bytes : int }
  | Not_regular_file of { kind : Unix.file_kind }
  | Unreadable of string

type inspect_failure =
  | Not_an_array
  | Entries of { count : int }
  | Entry_without_configuration
  | Configuration_without_fields
  | Empty_source of { volume : string }
  | Not_ext4_format of
      { volume : string
      ; format : string
      }

type image =
  { volume : string
  ; source : string
  }

let superblock_offset = 1024
let superblock_size = 1024

(* Offsets inside the superblock, from the kernel's ext4 super.html table. *)
let magic_offset = 0x38
let state_offset = 0x3A
let error_count_offset = 0x194
let ext4_magic = 0xEF53
let errors_detected_bit = 0x0002
let error_func_bytes = 32
let u32_mask = 0xFFFF_FFFF

(* An error time is 40 bits: 32 low bits and an 8-bit high byte. *)
let time_hi_shift = 32

type site_layout =
  { time_lo : int
  ; time_hi : int
  ; inode_at : int
  ; block_at : int
  ; func_at : int
  ; line_at : int
  ; code_at : int
  }

let first_site =
  { time_lo = 0x198
  ; time_hi = 0x278
  ; inode_at = 0x19C
  ; block_at = 0x1A0
  ; func_at = 0x1A8
  ; line_at = 0x1C8
  ; code_at = 0x27A
  }
;;

let last_site =
  { time_lo = 0x1CC
  ; time_hi = 0x279
  ; inode_at = 0x1D0
  ; block_at = 0x1D8
  ; func_at = 0x1E0
  ; line_at = 0x1D4
  ; code_at = 0x27B
  }
;;

(* EXT4_ERR_* in fs/ext4/ext4.h. The field is a byte, so any other value is
   kept as read. *)
let error_code_of_int = function
  | 0 -> Not_recorded
  | 1 -> Unknown
  | 2 -> Eio
  | 3 -> Enomem
  | 4 -> Efsbadcrc
  | 5 -> Efscorrupted
  | 6 -> Enospc
  | 7 -> Enokey
  | 8 -> Erofs
  | 9 -> Efbig
  | 10 -> Eexist
  | 11 -> Erange
  | 12 -> Eoverflow
  | 13 -> Ebusy
  | 14 -> Enotdir
  | 15 -> Enotempty
  | 16 -> Eshutdown
  | 17 -> Efault
  | other -> Unrecognized other
;;

let error_code_to_string = function
  | Not_recorded -> "not_recorded"
  | Unknown -> "unknown"
  | Eio -> "EIO"
  | Enomem -> "ENOMEM"
  | Efsbadcrc -> "EFSBADCRC"
  | Efscorrupted -> "EFSCORRUPTED"
  | Enospc -> "ENOSPC"
  | Enokey -> "ENOKEY"
  | Erofs -> "EROFS"
  | Efbig -> "EFBIG"
  | Eexist -> "EEXIST"
  | Erange -> "ERANGE"
  | Eoverflow -> "EOVERFLOW"
  | Ebusy -> "EBUSY"
  | Enotdir -> "ENOTDIR"
  | Enotempty -> "ENOTEMPTY"
  | Eshutdown -> "ESHUTDOWN"
  | Efault -> "EFAULT"
  | Unrecognized code -> Printf.sprintf "code_%d" code
;;

let u32 superblock offset = Int32.to_int (String.get_int32_le superblock offset) land u32_mask

(* The kernel NUL-pads the name. A damaged superblock can hold any bytes
   here, so the name is kept OCaml-escaped: a C identifier is unchanged, and
   other bytes cannot reach JSON or a Board post as invalid UTF-8. *)
let func_name superblock offset =
  let raw = String.sub superblock offset error_func_bytes in
  String.escaped
    (match String.index_opt raw '\000' with
     | Some nul -> String.sub raw 0 nul
     | None -> raw)
;;

let site superblock layout =
  let time =
    u32 superblock layout.time_lo
    lor (String.get_uint8 superblock layout.time_hi lsl time_hi_shift)
  in
  if time = 0
  then None
  else
    Some
      { at = float_of_int time
      ; func = func_name superblock layout.func_at
      ; line = u32 superblock layout.line_at
      ; inode = u32 superblock layout.inode_at
      ; block = String.get_int64_le superblock layout.block_at
      ; code = error_code_of_int (String.get_uint8 superblock layout.code_at)
      }
;;

let of_superblock superblock =
  let bytes = String.length superblock in
  if bytes < superblock_size
  then Error (Truncated { bytes })
  else (
    let magic = String.get_uint16_le superblock magic_offset in
    if magic <> ext4_magic
    then Error (Not_ext4 { magic })
    else if String.get_uint16_le superblock state_offset land errors_detected_bit = 0
    then Ok Clean
    else
      Ok
        (Errors_recorded
           { count = u32 superblock error_count_offset
           ; first = site superblock first_site
           ; last = site superblock last_site
           }))
;;

let rec read_into fd buffer ~filled =
  if filled = Bytes.length buffer
  then filled
  else (
    match Unix.read fd buffer filled (Bytes.length buffer - filled) with
    | 0 -> filled
    | count -> read_into fd buffer ~filled:(filled + count))
;;

let read_superblock fd =
  let stats = Unix.fstat fd in
  match stats.st_kind with
  | Unix.S_REG ->
    let available = stats.st_size - superblock_offset in
    if available < superblock_size
    then Error (Truncated { bytes = Int.max 0 available })
    else (
      let (_ : int) = Unix.lseek fd superblock_offset Unix.SEEK_SET in
      let buffer = Bytes.create superblock_size in
      match read_into fd buffer ~filled:0 with
      | filled when filled = superblock_size -> of_superblock (Bytes.to_string buffer)
      | filled -> Error (Truncated { bytes = filled }))
  | (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) as kind ->
    Error (Not_regular_file { kind })
;;

(* O_NONBLOCK so that opening a FIFO returns at once; the kind check then
   refuses it. The kind is read from the open descriptor, so the file that
   is checked is the file that is read. *)
let read_image ~path =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (error, _, _) -> Error (Unreadable (Unix.error_message error))
  | fd ->
    let result =
      match read_superblock fd with
      | result -> result
      | exception Unix.Unix_error (error, _, _) -> Error (Unreadable (Unix.error_message error))
    in
    (* The descriptor was only read, so a failed close loses nothing. *)
    (try Unix.close fd with
     | Unix.Unix_error _ -> ());
    result
;;

let image_of_inspect = function
  | `List [ `Assoc fields ] ->
    (match List.assoc_opt "configuration" fields with
     | Some (`Assoc configuration) ->
       (match
          ( List.assoc_opt "name" configuration
          , List.assoc_opt "format" configuration
          , List.assoc_opt "source" configuration )
        with
        | Some (`String volume), Some (`String "ext4"), Some (`String source)
          when source <> "" -> Ok { volume; source }
        | Some (`String volume), Some (`String "ext4"), Some (`String _) ->
          Error (Empty_source { volume })
        | Some (`String volume), Some (`String format), Some (`String _) ->
          Error (Not_ext4_format { volume; format })
        | _ -> Error Configuration_without_fields)
     | Some _ | None -> Error Entry_without_configuration)
  | `List [ _ ] -> Error Entry_without_configuration
  | `List entries -> Error (Entries { count = List.length entries })
  | _ -> Error Not_an_array
;;

let site_to_yojson = function
  | None -> `Null
  | Some site ->
    `Assoc
      [ "at", `Float site.at
      ; "func", `String site.func
      ; "line", `Int site.line
      ; "inode", `Int site.inode
      ; "block", `Intlit (Printf.sprintf "%Lu" site.block)
      ; "code", `String (error_code_to_string site.code)
      ]
;;

let state_to_yojson = function
  | Clean -> `Assoc [ "state", `String "clean" ]
  | Errors_recorded { count; first; last } ->
    `Assoc
      [ "state", `String "errors_recorded"
      ; "count", `Int count
      ; "first", site_to_yojson first
      ; "last", site_to_yojson last
      ]
;;

let read_failure_to_string = function
  | Not_ext4 { magic } -> Printf.sprintf "superblock magic 0x%04X is not ext4" magic
  | Truncated { bytes } ->
    Printf.sprintf "image holds %d of the %d superblock bytes" bytes superblock_size
  | Not_regular_file { kind } ->
    Printf.sprintf
      "image is a %s, not a regular file"
      (match kind with
       | Unix.S_REG -> "regular file"
       | Unix.S_DIR -> "directory"
       | Unix.S_CHR -> "character device"
       | Unix.S_BLK -> "block device"
       | Unix.S_LNK -> "symbolic link"
       | Unix.S_FIFO -> "named pipe"
       | Unix.S_SOCK -> "socket")
  | Unreadable detail -> "image unreadable: " ^ detail
;;

let inspect_failure_to_string = function
  | Not_an_array -> "volume inspect output is not an array"
  | Entries { count } -> Printf.sprintf "volume inspect returned %d entries, expected one" count
  | Entry_without_configuration -> "volume inspect entry has no configuration object"
  | Configuration_without_fields ->
    "volume inspect configuration lacks a string name, format and source"
  | Empty_source { volume } -> Printf.sprintf "volume %s has an empty image source" volume
  | Not_ext4_format { volume; format } -> Printf.sprintf "volume %s is %s, not ext4" volume format
;;
