module Unit = Librarian_unit
module Read_unit = Librarian_read_unit
module Unread = Librarian_unread
module Scan = Private_jsonl_scan
module Objects = Agent_core.Checkpoint_objects

type stores =
  { session_dir : session:string -> string
  ; base_path : string
  ; keeper_name : string
  }

type read_error =
  | Fault of Unit.input_fault
  | Unread of { detail : string }

type take =
  | Rest_of_unit
  | First_items of Librarian_width.count

type read =
  { unit : Read_unit.t
  ; ends : Librarian_log.within
  }

let ( let* ) = Result.bind

(* One item or one part that is not there, in the unit's order. *)
type entry =
  | Item of Unit.item_name * Read_unit.body
  | Lacking of Unit.missing_part

(* How many more items the read takes. A read of the first k items looks for
   one more, to know whether the unit goes on after them. *)
type budget =
  | Every
  | Taking of int

let spent = function
  | Every -> false
  | Taking left -> left <= 0
;;

let counted budget = function
  | Item _ -> (
    match budget with
    | Every -> Every
    | Taking left -> Taking (left - 1))
  | Lacking (_ : Unit.missing_part) -> budget
;;

(* Where a read starts in one store of one segment. *)
type start =
  | Passed (** Every item of it was read before. *)
  | After of int (** The item at this coordinate was read; the read goes on after it. *)
  | From_first

(* What one store gave: its entries in order, and the budget after them. *)
type part =
  { entries : entry list
  ; budget : budget
  }

let nothing budget = { entries = []; budget }
let is_empty ({ from; until } : Unit.range) = until <= from

(* A store is read as many rows per locked read as the turn log is. *)
let rows_per_read = Keeper_turn_log_store.scan_window_rows

let unread error = Error (Unread { detail = Scan.error_to_string error })

type scan =
  { found : entry list (** Newest first. *)
  ; left : budget
  ; reached : int (** Just past the last row seen. *)
  ; skipping : bool (** The first row is the one read before. *)
  }

(* The rows of [path] that start inside [range], each as [entry] makes it,
   and the part of the range the file does not hold. After an item, the scan
   starts at that item's row and finds where the next row starts by its line
   break; that row is not decoded. A range that does not start a row of the
   file is not held at all. A read whose budget is spent says nothing about
   the rows after: the next read reads them. *)
let byte_rows path (range : Unit.range) start ~budget ~entry ~lacking =
  let first =
    match start with
    | Passed -> None
    | From_first -> Some (range.from, false)
    | After at ->
      if at < range.from then Some (range.from, false)
      else if at < range.until then Some (at, true)
      else None
  in
  match first with
  | None -> Ok (nothing budget)
  | Some (from, (_ : bool)) when is_empty { range with from } -> Ok (nothing budget)
  | Some (from, skipping) ->
    let ended { found; left; reached; skipping = (_ : bool) } =
      let lacking =
        if spent left || reached >= range.until then [] else [ Lacking (lacking { range with from = reached }) ]
      in
      Ok { entries = List.rev found @ lacking; budget = left }
    in
    (match
       Scan.fold_from path ~from ~rows_per_read ~init:{ found = []; left = budget; reached = from; skipping }
         ~f:(fun scan ~at row ->
           if at >= range.until then Scan.Stop scan
           else (
             let reached = at + String.length row + 1 in
             if scan.skipping then Scan.Continue { scan with reached; skipping = false }
             else (
               let one = entry ~at row in
               let scan = { found = one :: scan.found; left = counted scan.left one; reached; skipping = false } in
               if spent scan.left then Scan.Stop scan else Scan.Continue scan)))
     with
     | Ok (Stopped scan | Reached_end scan) -> ended scan
     | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
       Ok { entries = [ Lacking (lacking { range with from }) ]; budget }
     | Error (Scan_failed error) -> unread error)
;;

let official_rows path file store range start ~budget =
  let entry ~at row =
    match Keeper_turn_fragments.decode_line row with
    | Ok line -> Item ({ store; at }, Read_unit.Fragment { file; line })
    | Error (_ : Keeper_turn_fragments.read_error) -> (
      match (file : Keeper_turn_fragments.file) with
      | Main -> Lacking (Undecodable_history_line { offset = at })
      | Internal -> Lacking (Undecodable_internal_line { offset = at }))
  in
  let lacking range : Unit.missing_part =
    match file with
    | Main -> History_bytes range
    | Internal -> Internal_bytes range
  in
  byte_rows path range start ~budget ~entry ~lacking
;;

let chat_rows path range start ~budget =
  byte_rows path range start ~budget
    ~entry:(fun ~at row ->
      Item ({ store = Chat; at }, Read_unit.Chat_row (Keeper_chat_store_line_decode.parse_line_decoded ~file_path:path row)))
    ~lacking:(fun range -> Unit.Chat_bytes range)
;;

let external_entry ~row text =
  let decoded =
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error (_ : string) -> None
    | json -> (
      match Keeper_external_attention.event_of_json json with
      | Ok (Recorded item) -> Some item
      | Error (_ : string) -> None)
  in
  match decoded with
  | Some item -> Item ({ store = External; at = row }, Read_unit.External_row item)
  | None -> Lacking (Unit.Undecodable_external_row { row })
;;

(* The external store is counted in rows from its first, so its rows are
   found by counting from there. *)
let external_rows path (range : Unit.range) start ~budget =
  let range =
    match start with
    | Passed -> { range with from = range.until }
    | After row -> { range with from = Int.max range.from (row + 1) }
    | From_first -> range
  in
  if is_empty range then Ok (nothing budget)
  else (
    match
      Scan.fold_from path ~from:0 ~rows_per_read ~init:(0, [], budget)
        ~f:(fun (count, found, left) ~at:(_ : int) text ->
          if count >= range.until then Scan.Stop (count, found, left)
          else if count < range.from then Scan.Continue (count + 1, found, left)
          else (
            let one = external_entry ~row:count text in
            let left = counted left one in
            let scanned = count + 1, one :: found, left in
            if spent left then Scan.Stop scanned else Scan.Continue scanned))
    with
    | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
      Ok { entries = [ Lacking (External_rows range) ]; budget }
    | Error (Scan_failed error) -> unread error
    | Ok (Stopped (count, found, left) | Reached_end (count, found, left)) ->
      let lacking =
        if spent left || count >= range.until then []
        else [ Lacking (External_rows { from = Int.max range.from count; until = range.until }) ]
      in
      Ok { entries = List.rev found @ lacking; budget = left })
;;

(* The slices take the unit's messages in order, so a message's number is
   [first] and how many messages the slices before it take. A bundle that is
   not stored is the part of its slice the read had not passed. *)
let messages ~line ~session_dir ~first (slices : Keeper_turn_log.slice list) start ~budget =
  let read_object = Keeper_checkpoint_object_store.read ~session_dir in
  let unreadable = Error (Fault (Content_unreadable { line })) in
  let after =
    match start with
    | Passed | From_first -> None
    | After number -> Some number
  in
  let rec walk number found left = function
    | [] -> Ok { entries = List.rev found; budget = left }
    | (_ : Keeper_turn_log.slice list) when spent left -> Ok { entries = List.rev found; budget = left }
    | ({ bundle; skip; take } : Keeper_turn_log.slice) :: rest ->
      let past = number + take in
      let low =
        match after with
        | None -> number
        | Some read -> Int.max number (read + 1)
      in
      if low >= past then walk past found left rest
      else (
        let slice : Keeper_turn_log.slice = { bundle; skip = skip + low - number; take = past - low } in
        match Objects.load_bundle ~read_object bundle with
        | Error (Object_missing (_ : Objects.digest)) -> walk past (Lacking (Bundle slice) :: found) left rest
        | Error
            ( Head_invalid _ | Checkpoint_invalid _ | Object_unreadable _ | Object_digest_mismatch _
            | Bundle_invalid _ | Turn_mismatch _ | Message_invalid _ | Segment_invalid _
            | Header_object_invalid _ ) -> unreadable
        | Ok held ->
          if List.length held < slice.skip + slice.take then unreadable
          else (
            let window =
              List.filteri
                (fun index (_ : Agent_core.Types.message) -> index >= slice.skip && index < slice.skip + slice.take)
                held
            in
            let found, left, (_ : int) =
              List.fold_left
                (fun (found, left, at) message ->
                   if spent left then found, left, at
                   else (
                     let one = Item ({ store = Agent_core; at }, Read_unit.Message message) in
                     one :: found, counted left one, at + 1))
                (found, left, low) window
            in
            walk past found left rest))
  in
  match start with
  | Passed -> Ok (nothing budget)
  | After (_ : int) | From_first -> walk first [] budget slices
;;

(* One segment's stores in the order {!Librarian_unit} gives, each from where
   [starts] says, until the budget is spent. *)
(* The stores a segment's record reads (§5.3): the checkpoint's slices when
   it reads the checkpoint, the main file's range when it reads that file,
   and the internal file's range, which every record reads. *)
let checkpoint_slices : Unread.record -> Keeper_turn_log.slice list option = function
  | Checkpoint { slices; internal = _ } | Every_record { slices; history = _; internal = _ } -> Some slices
  | Official_files { history = _; internal = _ } -> None
;;

let history_range : Unread.record -> Unit.range option = function
  | Official_files { history; internal = _ } | Every_record { slices = _; history; internal = _ } -> Some history
  | Checkpoint { slices = _; internal = _ } -> None
;;

let internal_range : Unread.record -> Unit.range = function
  | Checkpoint { slices = _; internal }
  | Official_files { history = _; internal }
  | Every_record { slices = _; history = _; internal } -> internal
;;

let segment stores ~line ~(through : Keeper_turn_log.mark) ~first (segment : Unread.segment) starts budget =
  let official = stores.session_dir ~session:through.session in
  let read_store (store : Unit.store) start budget =
    match store with
    | Chat ->
      chat_rows (Keeper_chat_store.chat_path ~base_dir:stores.base_path ~keeper_name:stores.keeper_name)
        segment.chat start ~budget
    | External ->
      external_rows
        (Keeper_external_attention.attention_path ~base_path:stores.base_path ~keeper_name:stores.keeper_name)
        segment.external_rows start ~budget
    | Agent_core ->
      (match checkpoint_slices segment.record with
       | Some slices ->
         messages ~line ~session_dir:(stores.session_dir ~session:through.trace) ~first slices start ~budget
       | None -> Ok (nothing budget))
    | History ->
      (match history_range segment.record with
       | Some range ->
         official_rows (Keeper_turn_fragments.path ~session_dir:official Main) Main History range start ~budget
       | None -> Ok (nothing budget))
    | Internal ->
      official_rows (Keeper_turn_fragments.path ~session_dir:official Internal) Internal Internal
        (internal_range segment.record) start ~budget
  in
  List.fold_left
    (fun read (store, start) ->
       let* { entries; budget } = read in
       if spent budget then read
       else (
         let* part = read_store store start budget in
         Ok { entries = entries @ part.entries; budget = part.budget }))
    (Ok (nothing budget)) starts
;;

let from_first = List.map (fun store -> store, From_first) Unit.stores

(* The stores before the resumed item's store were read, its own goes on
   after the item, the ones after it start at their first row. *)
let resumed (name : Unit.item_name) =
  let rec starts = function
    | [] -> []
    | store :: rest ->
      if Unit.equal_store store name.store
      then (store, After name.at) :: List.map (fun store -> store, From_first) rest
      else (store, Passed) :: starts rest
  in
  starts Unit.stores
;;

let messages_in (slices : Keeper_turn_log.slice list) =
  List.fold_left (fun count ({ take; _ } : Keeper_turn_log.slice) -> count + take) 0 slices
;;

(* A record that does not read the checkpoint is one whose slices take no
   message (§5.3), so it numbers none. *)
let messages_of (record : Unread.record) =
  match checkpoint_slices record with
  | Some slices -> messages_in slices
  | None -> 0
;;

(* Each store's [own] range starts where its [unattributed] range ends, and
   the own messages are numbered after the unattributed ones. *)
let in_own (own : Unread.segment) ~own_first ({ store; at } : Unit.item_name) =
  match store with
  | Chat -> at >= own.chat.from
  | External -> at >= own.external_rows.from
  | Agent_core ->
    (match checkpoint_slices own.record with
     | Some (_ : Keeper_turn_log.slice list) -> at >= own_first
     | None -> false)
  | History ->
    (match history_range own.record with
     | Some range -> at >= range.from
     | None -> false)
  | Internal -> at >= (internal_range own.record).from
;;

let rec through_item count kept = function
  | [] -> None
  | (Lacking (_ : Unit.missing_part) as entry) :: rest -> through_item count (entry :: kept) rest
  | (Item (name, (_ : Read_unit.body)) as entry) :: rest ->
    if Int.equal count 1 then Some (List.rev (entry :: kept), name, rest)
    else through_item (count - 1) (entry :: kept) rest
;;

let is_item = function
  | Item _ -> true
  | Lacking (_ : Unit.missing_part) -> false
;;

(* How many entries the read keeps, and where it ends. The first [k] items
   end the read only when an item follows them: what lies between them and
   that item, missing parts included, is left for the next read. *)
let ending take entries =
  match take with
  | Rest_of_unit -> List.length entries, Librarian_log.Whole
  | First_items count -> (
    match through_item (count :> int) [] entries with
    | Some (kept, name, rest) when List.exists is_item rest -> List.length kept, Librarian_log.Item name
    | Some (_ : entry list * Unit.item_name * entry list) | None -> List.length entries, Librarian_log.Whole)
;;

let first_entries count entries = List.filteri (fun index (_ : entry) -> index < count) entries

let items ~first entries =
  List.filter_map
    (function
      | Item (name, body) -> Some (name, body)
      | Lacking (_ : Unit.missing_part) -> None)
    entries
  |> List.mapi (fun place (name, body) : Read_unit.item -> { index = first + place; name; body })
;;

let missing entries =
  List.filter_map
    (function
      | Lacking part -> Some part
      | Item _ -> None)
    entries
;;

let read stores (span : Unread.span) ~take =
  let budget =
    match take with
    | Rest_of_unit -> Every
    | First_items count -> Taking ((count :> int) + 1)
  in
  let first = span.from.closed_messages in
  let segment = segment stores ~line:span.line ~through:span.through in
  match span.source with
  | Turn { turn; outcome; opened; unattributed; own } ->
    let own_first = first + messages_of unattributed.record in
    let before_starts, own_starts =
      match span.resume with
      | None -> from_first, from_first
      | Some name -> if in_own own ~own_first name then [], resumed name else resumed name, from_first
    in
    let* before = segment ~first unattributed before_starts budget in
    let* after = segment ~first:own_first own own_starts before.budget in
    let kept, ends = ending take (before.entries @ after.entries) in
    let before = first_entries kept before.entries in
    let after = first_entries (kept - List.length before) after.entries in
    let unattributed = items ~first:0 before in
    Ok
      { unit =
          { line = span.line
          ; at = span.at
          ; kind =
              Turn
                { turn; outcome; opened; unattributed; own = items ~first:(List.length unattributed) after }
          ; missing = missing before @ missing after
          }
      ; ends
      }
  | Announced_reset { cause; segment = held } ->
    let starts =
      match span.resume with
      | None -> from_first
      | Some name -> resumed name
    in
    let* part = segment ~first held starts budget in
    let kept, ends = ending take part.entries in
    let entries = first_entries kept part.entries in
    Ok
      { unit = { line = span.line; at = span.at; kind = Reset { cause; items = items ~first:0 entries }; missing = missing entries }
      ; ends
      }
;;
