(* RFC-0474 L4f. A Keeper-scoped [Audit.read_recent] scanned the approval
   audit store backwards, decoding every row, until it held [n] of that
   Keeper's rows. A Keeper with no rows in the newest day files read all of
   them: on 2026-10-28 the store held 278,731 rows in 24 files (131 MB), and
   the runtime trust snapshots of 40 Keepers spent 6.7 s of their 6.9 s here,
   every time.

   This index decodes each row once. Each read first advances it over what
   changed since the previous read, so what a read returns is the store's
   content at that read. It keeps the newest [max_rows] rows of each Keeper and
   of the whole store, and where the newest row the backward scan refuses
   lies. A read is refused exactly when the backward scan would have reached
   that row, or an unreadable listing or file, before it had [n] rows. *)

module SMap = Map.Make (String)

let max_rows = 128

let malformed_row_detail ~path ~line_number ~detail =
  let location =
    match line_number with
    | Some line -> Printf.sprintf "%s:%d" path line
    | None -> path
  in
  Printf.sprintf "%s: %s" location detail
;;

(* Physical position in the store: month directory, then day file in the
   store's own order, then the row's ordinal within that file. [Whole_month]
   stands for an unreadable month listing, which lies beyond every day of
   its month. *)
type day_slot =
  | Day of string
  | Whole_month

type position =
  { month : string
  ; day : day_slot
  ; row : int
  }

(* The row ordinal of a refusal that stands for a whole file or month: newer
   than any row in it. *)
let beyond_every_row = max_int

let compare_position left right =
  match String.compare left.month right.month with
  | 0 ->
    (match left.day, right.day with
     | Day left_day, Day right_day ->
       (match Dated_jsonl.compare_day_file_names left_day right_day with
        | 0 -> Int.compare left.row right.row
        | order -> order)
     | Day _, Whole_month -> -1
     | Whole_month, Day _ -> 1
     | Whole_month, Whole_month -> Int.compare left.row right.row)
  | order -> order
;;

type refusal =
  { at : position
  ; detail : string
  }

let newer_refusal left right =
  match left, right with
  | None, refusal | refusal, None -> refusal
  | Some l, Some r -> if compare_position l.at r.at >= 0 then left else right
;;

(* Newest first, at most [max_rows]. *)
type recent_window =
  { rows : (position * Yojson.Safe.t) list
  ; length : int
  }

let empty_window = { rows = []; length = 0 }

(* One pass: walk past the newer rows, place [entry], keep what still fits. *)
let insert window ((at, _) as entry) =
  let rec place room = function
    | _ when room = 0 -> []
    | ((other, _) as newer) :: rest when compare_position other at > 0 ->
      newer :: place (room - 1) rest
    | older -> entry :: List.take (room - 1) older
  in
  { rows = place max_rows window.rows; length = min max_rows (window.length + 1) }
;;

(* What [Unix.lstat] says about a day file now, or [Unix.fstat] said when it
   was last read. An equal observation means nothing was written to it, and
   the file is not opened. *)
type observation =
  { size : int
  ; mtime : float
  ; ctime : float
  ; inode : int
  ; device : int
  }

let observation_of_stats stats =
  { size = stats.Unix.st_size
  ; mtime = stats.Unix.st_mtime
  ; ctime = stats.Unix.st_ctime
  ; inode = stats.Unix.st_ino
  ; device = stats.Unix.st_dev
  }
;;

let equal_observation left right =
  Int.equal left.size right.size
  && Float.equal left.mtime right.mtime
  && Float.equal left.ctime right.ctime
  && Int.equal left.inode right.inode
  && Int.equal left.device right.device
;;

(* A day file's rows are kept only while the bytes they were decoded from are
   still the file's first bytes. [Audit.record] appends whole rows and
   retention removes whole files, but another writer can rewrite a file in
   place, and the backward scan reads what that writer left. So a read of a
   changed file reads it from its first byte: the bytes decoded before are
   checked against their digests, block by block, and only the bytes after
   them are decoded. Both come from that one read, so the digests the index
   keeps cover exactly the bytes its rows came from, even when a writer runs
   during the read. [Digest] (MD5) only detects change here; a writer who
   can rewrite the store needs no collision to change what it says. *)
let digest_block_bytes = 1_048_576

type prefix =
  { sealed : Digest.t list  (** One per whole block, oldest first. *)
  ; open_block : Digest.t  (** The bytes after the last whole block. *)
  ; length : int
  }

let empty_prefix = { sealed = []; open_block = Digest.string ""; length = 0 }

let equal_prefix left right =
  Int.equal left.length right.length
  && List.equal Digest.equal left.sealed right.sealed
  && Digest.equal left.open_block right.open_block
;;

type digest_builder =
  { block : Bytes.t
  ; mutable filled : int
  ; mutable rev_sealed : Digest.t list
  ; mutable fed : int
  }

let start_digest () =
  { block = Bytes.create digest_block_bytes; filled = 0; rev_sealed = []; fed = 0 }
;;

(* [blit] is [Bytes.blit] or [Bytes.blit_string]. *)
let feed builder ~blit source offset length =
  let rec go offset length =
    if length > 0
    then (
      let taken = min (digest_block_bytes - builder.filled) length in
      blit source offset builder.block builder.filled taken;
      builder.filled <- builder.filled + taken;
      builder.fed <- builder.fed + taken;
      if builder.filled = digest_block_bytes
      then (
        builder.rev_sealed <- Digest.bytes builder.block :: builder.rev_sealed;
        builder.filled <- 0);
      go (offset + taken) (length - taken))
  in
  go offset length
;;

let digest_so_far builder =
  { sealed = List.rev builder.rev_sealed
  ; open_block = Digest.subbytes builder.block 0 builder.filled
  ; length = builder.fed
  }
;;

type file =
  { first_row : position  (** Where the file's rows begin in the store. *)
  ; observed : observation
  ; prefix : prefix  (** The bytes up to the file's last newline. *)
  ; rows_read : int
  ; trailing : (position * Dated_jsonl.recent_entry) option
        (** Bytes after the last newline, decoded. Not folded into the index:
            the row may still be growing. A read counts it, as the backward
            scan does. *)
  }

type t =
  { files : file SMap.t
  ; by_keeper : recent_window SMap.t
  ; all_rows : recent_window
  ; malformed : refusal option  (** The newest row that is not JSON. *)
  ; unowned : refusal option
        (** The newest JSON row that does not name exactly one string Keeper.
            Only a Keeper-scoped read refuses it. *)
  }

let empty =
  { files = SMap.empty
  ; by_keeper = SMap.empty
  ; all_rows = empty_window
  ; malformed = None
  ; unowned = None
  }
;;

let unowned_row_detail = "audit row must contain exactly one string keeper"

let keeper_of_row = function
  | `Assoc fields ->
    (match List.filter (fun (key, _) -> String.equal key "keeper") fields with
     | [ (_, `String keeper) ] -> Some keeper
     | _ -> None)
  | _ -> None
;;

let add_entry index at = function
  | Dated_jsonl.Malformed_json { path; line_number; detail } ->
    let detail = malformed_row_detail ~path ~line_number ~detail in
    { index with malformed = newer_refusal index.malformed (Some { at; detail }) }
  | Dated_jsonl.Parsed row ->
    let index = { index with all_rows = insert index.all_rows (at, row) } in
    (match keeper_of_row row with
     | Some keeper ->
       let window =
         Option.value ~default:empty_window (SMap.find_opt keeper index.by_keeper)
       in
       { index with by_keeper = SMap.add keeper (insert window (at, row)) index.by_keeper }
     | None ->
       { index with
         unowned = newer_refusal index.unowned (Some { at; detail = unowned_row_detail })
       })
;;

type day_file =
  { file_path : string
  ; file_month : string
  ; file_day : string
  }

(* Day files newest first, as the backward scan visits them, and the
   unreadable month listing that would stop that scan, if any. *)
let list_store store =
  match Dated_jsonl.month_dir_paths_newest_first_result store with
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
  | Ok months ->
    let rec walk acc = function
      | [] -> Ok (List.rev acc, None)
      | month_path :: rest ->
        let month = Filename.basename month_path in
        (match Dated_jsonl.day_file_paths_newest_first_result month_path with
         | Error error ->
           Ok
             ( List.rev acc
             , Some
                 { at = { month; day = Whole_month; row = beyond_every_row }
                 ; detail = Dated_jsonl.read_error_to_string error
                 } )
         | Ok paths ->
           let days =
             List.map
               (fun file_path ->
                  { file_path; file_month = month; file_day = Filename.basename file_path })
               paths
           in
           walk (List.rev_append days acc) rest)
    in
    walk [] months
;;

let unix_detail path error = Printf.sprintf "%s: %s" path (Unix.error_message error)
let not_regular_detail path = path ^ ": not a regular file"

(* What a read sees of one day file before opening it. *)
type change =
  | Unchanged
  | Unobservable of string
  | Changed of
      { prior : file option  (** The file as last read, if it was. *)
      ; seen : observation  (** What [lstat] said just now. *)
      }

let classify index (file : day_file) =
  match Unix.lstat file.file_path with
  | exception Unix.Unix_error (error, _, _) ->
    Unobservable (unix_detail file.file_path error)
  | stats when stats.Unix.st_kind <> Unix.S_REG ->
    Unobservable (not_regular_detail file.file_path)
  | stats ->
    let seen = observation_of_stats stats in
    let prior = SMap.find_opt file.file_path index.files in
    (match prior with
     | Some prior when equal_observation prior.observed seen -> Unchanged
     | Some _ | None -> Changed { prior; seen })
;;

type read =
  | Read of t
  | Read_refused of string
  | Rewritten

let read_chunk_bytes = 65_536

(* Read [file] from its first byte to the size its open handle has. The bytes
   [prior] decoded are only checked against its digests; the complete lines
   after them are decoded into [index] and digested as they are. The open
   follows a symbolic link, so a handle that is not the file [lstat] saw as
   [seen] is refused for this read, as the backward scan refuses a link. *)
let read_changed index (file : day_file) ~prior ~seen =
  let path = file.file_path in
  let at row = { month = file.file_month; day = Day file.file_day; row } in
  let expected, first_row =
    match prior with
    | Some prior -> prior.prefix, prior.rows_read
    | None -> empty_prefix, 0
  in
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (error, _, _) -> Read_refused (unix_detail path error)
  | descriptor ->
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with
        | Unix.Unix_error _ -> ())
      (fun () ->
         match Unix.fstat descriptor with
         | exception Unix.Unix_error (error, _, _) -> Read_refused (unix_detail path error)
         | stats when stats.Unix.st_kind <> Unix.S_REG -> Read_refused (not_regular_detail path)
         | stats
           when stats.Unix.st_ino <> seen.inode || stats.Unix.st_dev <> seen.device ->
           Read_refused (path ^ ": replaced while it was opened")
         | stats when stats.Unix.st_size < expected.length -> Rewritten
         | stats ->
           let size = stats.Unix.st_size in
           let digest = start_digest () in
           let chunk = Bytes.create read_chunk_bytes in
           let fragment = Buffer.create 256 in
           let index = ref index in
           let rows = ref first_row in
           let decode line =
             match Dated_jsonl.entry_of_physical_line ~path line with
             | None -> ()
             | Some entry ->
               index := add_entry !index (at !rows) entry;
               rows := !rows + 1
           in
           (* The complete lines in [chunk] from [start] to [stop], the line
              [fragment] holds the start of first. *)
           let rec decode_lines start stop =
             match Bytes.index_from_opt chunk start '\n' with
             | Some newline when newline < stop ->
               let pending = Buffer.contents fragment in
               Buffer.clear fragment;
               feed digest ~blit:Bytes.blit_string pending 0 (String.length pending);
               feed digest ~blit:Bytes.blit chunk start (newline + 1 - start);
               decode (pending ^ Bytes.sub_string chunk start (newline - start));
               decode_lines (newline + 1) stop
             | Some _ | None -> Buffer.add_subbytes fragment chunk start (stop - start)
           in
           (* [None] once [size] bytes are read; a refusal or [Rewritten]
              stops the read. *)
           let rec read_from position =
             if position >= size
             then None
             else (
               match
                 Unix.read descriptor chunk 0 (min read_chunk_bytes (size - position))
               with
               | exception Unix.Unix_error (error, _, _) ->
                 Some (Read_refused (unix_detail path error))
               | 0 -> Some Rewritten
               | got ->
                 let checked = max 0 (min got (expected.length - position)) in
                 feed digest ~blit:Bytes.blit chunk 0 checked;
                 if checked > 0
                    && position + checked = expected.length
                    && not (equal_prefix (digest_so_far digest) expected)
                 then Some Rewritten
                 else (
                   decode_lines checked got;
                   read_from (position + got)))
           in
           (match read_from 0 with
            | Some stopped -> stopped
            | None ->
              let trailing =
                Dated_jsonl.entry_of_physical_line ~path (Buffer.contents fragment)
                |> Option.map (fun entry -> at !rows, entry)
              in
              let read =
                { first_row = at 0
                ; observed = observation_of_stats stats
                ; prefix = digest_so_far digest
                ; rows_read = !rows
                ; trailing
                }
              in
              let index = !index in
              Read { index with files = SMap.add path read index.files }))
;;

type advance =
  | Advanced of t * refusal option
  | Rebuild_needed

let read_files index listing_refused newest_first =
  let refuse (file : day_file) detail refused =
    newer_refusal
      refused
      (Some
         { at = { month = file.file_month; day = Day file.file_day; row = beyond_every_row }
         ; detail
         })
  in
  (* Oldest first, so each row lands at the head of its window. *)
  let rec read index refused = function
    | [] -> Advanced (index, refused)
    | file :: rest ->
      (match classify index file with
       | Unchanged -> read index refused rest
       | Unobservable detail -> read index (refuse file detail refused) rest
       | Changed { prior; seen } ->
         (match read_changed index file ~prior ~seen with
          | Read index -> read index refused rest
          | Read_refused detail -> read index (refuse file detail refused) rest
          | Rewritten -> Rebuild_needed))
  in
  read index listing_refused (List.rev newest_first)
;;

(* Retention removes the oldest day files. Every row of a removed file is
   older than every row of the files left, so the newest rows among those
   left are the kept rows without the removed files' rows: a window that
   kept any row of a removed file kept every row left of its Keeper. The same
   holds for the newest refused rows. [None] when a removed file is not older
   than every file left, and the index must start over. *)
let without_oldest_files index ~removed =
  let left = SMap.filter (fun path _ -> not (SMap.mem path removed)) index.files in
  let extreme newer files =
    SMap.fold
      (fun _ (file : file) found ->
         match found with
         | Some at when newer (compare_position at file.first_row) -> found
         | Some _ | None -> Some file.first_row)
      files
      None
  in
  match extreme (fun order -> order >= 0) removed, extreme (fun order -> order <= 0) left with
  | Some newest_removed, Some oldest_left when compare_position newest_removed oldest_left >= 0
    -> None
  | _, oldest_left ->
    let kept at =
      match oldest_left with
      | Some oldest_left -> compare_position at oldest_left >= 0
      | None -> false
    in
    let window window =
      let rows = List.filter (fun (at, _) -> kept at) window.rows in
      { rows; length = List.length rows }
    in
    let refusal = function
      | Some refusal when kept refusal.at -> Some refusal
      | Some _ | None -> None
    in
    Some
      { files = left
      ; by_keeper = SMap.map window index.by_keeper
      ; all_rows = window index.all_rows
      ; malformed = refusal index.malformed
      ; unowned = refusal index.unowned
      }
;;

let advance store index =
  match list_store store with
  | Error detail -> Error detail
  | Ok (newest_first, listing_refused) ->
    let listed path =
      List.exists (fun (file : day_file) -> String.equal file.file_path path) newest_first
    in
    (* The listing stops at an unreadable month, as the backward scan does.
       Files of that month and older ones are hidden, not removed; a file
       missing from a newer month, which was listed whole, is removed. *)
    let hidden (file : file) =
      match listing_refused with
      | Some refusal -> String.compare file.first_row.month refusal.at.month <= 0
      | None -> false
    in
    let removed =
      SMap.filter (fun path file -> not (listed path || hidden file)) index.files
    in
    if SMap.is_empty removed
    then Ok (read_files index listing_refused newest_first)
    else (
      match without_oldest_files index ~removed with
      | Some index -> Ok (read_files index listing_refused newest_first)
      | None -> Ok Rebuild_needed)
;;

let rebuild store =
  match advance store empty with
  | Error _ as error -> error
  | Ok (Advanced (index, refused)) -> Ok (index, refused)
  | Ok Rebuild_needed ->
    Error "approval audit day file shrank while it was read from its first byte"
;;

let select index ~refused ~keeper_name ~n =
  let index =
    SMap.fold
      (fun _ (file : file) index ->
         match file.trailing with
         | Some (at, entry) -> add_entry index at entry
         | None -> index)
      index.files
      index
  in
  let window, unowned =
    match keeper_name with
    | Some keeper ->
      ( Option.value ~default:empty_window (SMap.find_opt keeper index.by_keeper)
      , index.unowned )
    | None -> index.all_rows, None
  in
  let selected = List.take n window.rows in
  match newer_refusal refused (newer_refusal index.malformed unowned) with
  | None -> Ok (List.map snd selected)
  | Some { at; detail } ->
    (match List.rev selected with
     | (oldest, _) :: _ when List.length selected = n && compare_position at oldest < 0 ->
       Ok (List.map snd selected)
     | [] | _ :: _ -> Error detail)
;;
