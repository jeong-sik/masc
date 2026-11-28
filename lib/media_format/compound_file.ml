let signature = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1"

type fault =
  | Truncated_header
  | Bad_header of string
  | Bad_sector of { sector : int }
  | Chain_cycle of { start : int }
  | Bad_directory of string
  | Short_stream of
      { name : string
      ; declared : int
      ; read : int
      }

type entry_kind =
  | Storage
  | Stream
  | Root
  | Unallocated

type entry =
  { name : string
  ; kind : entry_kind
  ; left : int
  ; right : int
  ; child : int
  ; start : int
  ; size : int
  }

type t =
  { bytes : string
  ; sector_size : int
  ; fat : int array
  ; mini_fat : int array
  ; mini_stream_sectors : int array
  ; streams : entry list
  }

let ( let* ) = Result.bind

(* [MS-CFB] §2.1 sector numbers. *)
let max_regular_sector = 0xFFFFFFFA
let end_of_chain = 0xFFFFFFFE
let no_stream = 0xFFFFFFFF
let header_bytes = 512
let directory_entry_bytes = 128
let mini_sector_bytes = 64
let header_difat_entries = 109

(* [MS-CFB] §2.2: a stream shorter than this lives in the mini stream. *)
let mini_stream_cutoff = 4096
let u16 s offset = String.get_uint16_le s offset
let u32 s offset = Int32.to_int (String.get_int32_le s offset) land 0xFFFF_FFFF

(* Sector [n] starts after the header sector: (n + 1) * sector size.
   Metadata (FAT, DIFAT, directory) must sit in whole sectors; stream data may
   end in a final partial sector, whose missing bytes make a short stream. *)
let whole_sectors ~bytes ~sector_size = (String.length bytes / sector_size) - 1

let data_sectors ~bytes ~sector_size =
  (String.length bytes + sector_size - 1) / sector_size - 1
;;

let sector_offset ~sector_size sector = (sector + 1) * sector_size

(* Follows [next] from [start] until ENDOFCHAIN, at most [limit] sectors when
   given. Each sector must index [next] and must not repeat. *)
let chain ~next ~sectors ?limit start =
  let seen = Hashtbl.create 64 in
  let rec go sector acc taken =
    match limit with
    | Some limit when taken >= limit -> Ok (List.rev acc)
    | Some _ | None ->
      if sector = end_of_chain
      then Ok (List.rev acc)
      else if sector > max_regular_sector || sector >= Array.length next || sector >= sectors
      then Error (Bad_sector { sector })
      else if Hashtbl.mem seen sector
      then Error (Chain_cycle { start })
      else (
        Hashtbl.add seen sector ();
        go next.(sector) (sector :: acc) (taken + 1))
  in
  go start [] 0
;;

(* The table never holds more entries than [limit], the number of sectors it
   can address, so a header that claims a huge FAT does not allocate one. *)
let entries_of_sectors ~bytes ~sector_size ~limit sector_ids =
  let per_sector = sector_size / 4 in
  let table = Array.make (min limit (List.length sector_ids * per_sector)) no_stream in
  List.iteri
    (fun i sector ->
       let base = sector_offset ~sector_size sector in
       for k = 0 to per_sector - 1 do
         let index = (i * per_sector) + k in
         if index < Array.length table then table.(index) <- u32 bytes (base + (4 * k))
       done)
    sector_ids;
  table
;;

let fat_sector_ids ~bytes ~sector_size ~sectors =
  let fat_count = u32 bytes 0x2C in
  let first_difat = u32 bytes 0x44 in
  let difat_count = u32 bytes 0x48 in
  if fat_count > sectors
  then Error (Bad_header (Printf.sprintf "%d FAT sectors in a file of %d sectors" fat_count sectors))
  else (
    let in_header = List.init (min fat_count header_difat_entries) (fun i -> u32 bytes (0x4C + (4 * i))) in
    let per_difat = (sector_size / 4) - 1 in
    let rec from_difat sector seen acc remaining =
      if remaining <= 0
      then Ok (List.rev acc)
      else if sector > max_regular_sector || sector >= sectors
      then Error (Bad_sector { sector })
      else if List.mem sector seen
      then Error (Chain_cycle { start = first_difat })
      else if List.length seen >= difat_count
      then Error (Bad_header "the FAT needs more DIFAT sectors than the header counts")
      else (
        let base = sector_offset ~sector_size sector in
        let take = min per_difat remaining in
        let ids = List.init take (fun i -> u32 bytes (base + (4 * i))) in
        from_difat
          (u32 bytes (base + (4 * per_difat)))
          (sector :: seen)
          (List.rev_append ids acc)
          (remaining - take))
    in
    let* rest = from_difat first_difat [] [] (fat_count - List.length in_header) in
    let ids = in_header @ rest in
    match List.find_opt (fun id -> id > max_regular_sector || id >= sectors) ids with
    | Some sector -> Error (Bad_sector { sector })
    | None -> Ok ids)
;;

let read_header bytes =
  if String.length bytes < header_bytes || not (String.starts_with ~prefix:signature bytes)
  then Error Truncated_header
  else (
    let major = u16 bytes 0x1A in
    let shift = u16 bytes 0x1E in
    if u16 bytes 0x1C <> 0xFFFE
    then Error (Bad_header "byte order is not little-endian")
    else if not ((major = 3 && shift = 9) || (major = 4 && shift = 12))
    then Error (Bad_header (Printf.sprintf "version %d with sector shift %d" major shift))
    else if u16 bytes 0x20 <> 6
    then Error (Bad_header "mini sector shift is not 6")
    else if u32 bytes 0x38 <> mini_stream_cutoff
    then Error (Bad_header "mini stream cutoff is not 4096")
    else Ok (major, 1 lsl shift))
;;

let decode_name bytes ~offset ~length =
  (* [length] counts bytes including the UTF-16 terminator. *)
  let buffer = Buffer.create 32 in
  let stop = offset + length - 2 in
  let rec go i =
    if i < stop
    then (
      let decoded = String.get_utf_16le_uchar bytes i in
      Buffer.add_utf_8_uchar buffer (Uchar.utf_decode_uchar decoded);
      go (i + Uchar.utf_decode_length decoded))
  in
  go offset;
  Buffer.contents buffer
;;

let read_entry bytes ~major offset =
  let name_length = u16 bytes (offset + 0x40) in
  if name_length > 64 || name_length mod 2 <> 0
  then Error (Bad_directory (Printf.sprintf "name length %d" name_length))
  else (
    let kind =
      match Char.code bytes.[offset + 0x42] with
      | 1 -> Ok Storage
      | 2 -> Ok Stream
      | 5 -> Ok Root
      | 0 -> Ok Unallocated
      | other -> Error (Bad_directory (Printf.sprintf "object type %d" other))
    in
    let* kind = kind in
    let size_low = u32 bytes (offset + 0x78) in
    (* A version 3 file may leave garbage in the size's high 32 bits. *)
    let size_high = if major = 3 then 0 else u32 bytes (offset + 0x7C) in
    (* Stream and mini stream bytes live in this file's sectors, so a size
       past the file's length is corrupt, and so is any size with its high
       half set. *)
    let* size =
      match kind with
      | Stream | Root when size_high <> 0 || size_low > String.length bytes ->
        Error
          (Bad_directory
             (Printf.sprintf "an entry declares more bytes than the %d-byte file" (String.length bytes)))
      | Stream | Root -> Ok size_low
      (* A storage or a free entry has no bytes of its own. *)
      | Storage | Unallocated -> Ok 0
    in
    Ok
      { name = (if name_length = 0 then "" else decode_name bytes ~offset ~length:name_length)
      ; kind
      ; left = u32 bytes (offset + 0x44)
      ; right = u32 bytes (offset + 0x48)
      ; child = u32 bytes (offset + 0x4C)
      ; start = u32 bytes (offset + 0x74)
      ; size
      })
;;

(* The streams among the root's children: a sibling tree reached through the
   root's child, walked with a visited set that starts with the root, entry
   0, so a tree that points back at it is refused. *)
let root_children entries root =
  let count = Array.length entries in
  let visited = Array.make count false in
  visited.(0) <- true;
  let rec walk pending acc =
    match pending with
    | [] -> Ok acc
    | id :: rest when id = no_stream -> walk rest acc
    | id :: rest ->
      if id >= count
      then Error (Bad_directory (Printf.sprintf "sibling %d of %d entries" id count))
      else if visited.(id)
      then Error (Bad_directory (Printf.sprintf "entry %d is reached twice" id))
      else (
        visited.(id) <- true;
        let entry = entries.(id) in
        let acc =
          match entry.kind with
          | Stream -> entry :: acc
          | Storage | Root | Unallocated -> acc
        in
        walk (entry.left :: entry.right :: rest) acc)
  in
  walk [ root.child ] []
;;

let read bytes =
  let* major, sector_size = read_header bytes in
  let sectors = whole_sectors ~bytes ~sector_size in
  let data = data_sectors ~bytes ~sector_size in
  let* fat_ids = fat_sector_ids ~bytes ~sector_size ~sectors in
  let fat = entries_of_sectors ~bytes ~sector_size ~limit:data fat_ids in
  let* directory_sectors = chain ~next:fat ~sectors (u32 bytes 0x30) in
  let per_sector = sector_size / directory_entry_bytes in
  let* entries =
    List.concat_map
      (fun sector ->
         let base = sector_offset ~sector_size sector in
         List.init per_sector (fun k -> base + (k * directory_entry_bytes)))
      directory_sectors
    |> List.fold_left
         (fun acc offset ->
            let* entries = acc in
            let* entry = read_entry bytes ~major offset in
            Ok (entry :: entries))
         (Ok [])
  in
  let entries = Array.of_list (List.rev entries) in
  if Array.length entries = 0 || entries.(0).kind <> Root
  then Error (Bad_directory "entry 0 is not the root storage")
  else (
    let root = entries.(0) in
    let* streams = root_children entries root in
    let* mini_fat_sectors =
      chain ~next:fat ~sectors ~limit:(u32 bytes 0x40) (u32 bytes 0x3C)
    in
    let* mini_stream_sectors = chain ~next:fat ~sectors:data root.start in
    let mini_sectors = List.length mini_stream_sectors * sector_size / mini_sector_bytes in
    Ok
      { bytes
      ; sector_size
      ; fat
      ; mini_fat = entries_of_sectors ~bytes ~sector_size ~limit:mini_sectors mini_fat_sectors
      ; mini_stream_sectors = Array.of_list mini_stream_sectors
      ; streams
      })
;;

let root_streams t = List.map (fun entry -> entry.name) t.streams

(* Copies stream bytes [first, first + length) out of [pieces], the stream's
   sectors or mini sectors in order, each [unit] bytes long at [position
   piece] in the file. It stops at the first piece the file cuts short: the
   bytes after it would not follow on from it. *)
let gather ~bytes ~unit ~position ~first ~length pieces =
  let buffer = Buffer.create length in
  let rec go piece_start = function
    | [] -> ()
    | piece :: rest ->
      let from = max first piece_start
      and until = min (first + length) (piece_start + unit) in
      if from >= until
      then go (piece_start + unit) rest
      else (
        let offset = position piece + (from - piece_start) in
        let available = min (until - from) (String.length bytes - offset) in
        if available > 0 then Buffer.add_substring buffer bytes offset available;
        if available = until - from then go (piece_start + unit) rest)
  in
  go 0 pieces;
  Buffer.contents buffer
;;

let stream_slice t name ~offset ~max_bytes =
  let wanted = String.lowercase_ascii name in
  match
    List.find_opt (fun entry -> String.equal (String.lowercase_ascii entry.name) wanted) t.streams
  with
  | None -> Ok None
  | Some entry ->
    let first = min (max 0 offset) entry.size in
    let length = min (max 0 max_bytes) (entry.size - first) in
    let pieces_through unit = (first + length + unit - 1) / unit in
    let* data =
      if entry.size < mini_stream_cutoff
      then (
        let container = Array.length t.mini_stream_sectors * t.sector_size / mini_sector_bytes in
        let* mini_sectors =
          chain
            ~next:t.mini_fat
            ~sectors:container
            ~limit:(pieces_through mini_sector_bytes)
            entry.start
        in
        let position mini =
          let inside = mini * mini_sector_bytes in
          sector_offset ~sector_size:t.sector_size t.mini_stream_sectors.(inside / t.sector_size)
          + (inside mod t.sector_size)
        in
        Ok (gather ~bytes:t.bytes ~unit:mini_sector_bytes ~position ~first ~length mini_sectors))
      else (
        let sectors = data_sectors ~bytes:t.bytes ~sector_size:t.sector_size in
        let* regular =
          chain ~next:t.fat ~sectors ~limit:(pieces_through t.sector_size) entry.start
        in
        Ok
          (gather
             ~bytes:t.bytes
             ~unit:t.sector_size
             ~position:(sector_offset ~sector_size:t.sector_size)
             ~first
             ~length
             regular))
    in
    if String.length data < length
    then Error (Short_stream { name = entry.name; declared = entry.size; read = first + String.length data })
    else Ok (Some data)
;;
