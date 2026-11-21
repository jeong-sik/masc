let ( let* ) = Result.bind

type range =
  { before : Librarian_unread.span list
  ; head : Librarian_unread.span
  ; after : Librarian_unread.span list
  }

type units_error =
  | No_head of Librarian_unread.stop
  | Turn_log_fault of Librarian_unit.input_fault
  | Turn_log_unread of { detail : string }

let rec head_of before = function
  | [] -> None
  | span :: rest ->
    if Librarian_unread.has_items span
    then Some { before = List.rev before; head = span; after = rest }
    else head_of (span :: before) rest
;;

let units ~turns_path ~(width : Librarian_width.width) tail =
  let until : Librarian_unread.until =
    match width with
    | All -> To_end
    | Units count -> First_with_items (count :> int)
    | Items (_ : Librarian_width.count) -> First_with_items 1
  in
  match Librarian_unread.read ~turns_path ~until tail with
  | Error (Fault fault) -> Error (Turn_log_fault fault)
  | Error (Unread { detail }) -> Error (Turn_log_unread { detail })
  | Ok { spans; stop; bytes = (_ : int) } ->
    (match head_of [] spans with
     | Some range -> Ok range
     | None -> Error (No_head stop))
;;

type contents =
  { units : Librarian_read_unit.t list
  ; reach : Librarian_read_result.reach
  ; trace : string
  ; offered : Librarian_width.offered
  }

type contents_error =
  | Content_unreadable of { span : Librarian_unread.span }
  | Content_unread of { detail : string }

(* The content reader reads one span, so the line it names is [span]'s. *)
let read_content stores (span : Librarian_unread.span) ~take =
  match Librarian_unit_content.read stores span ~take with
  | Ok content -> Ok (span, content)
  | Error (Unreadable { line = (_ : int) }) -> Error (Content_unreadable { span })
  | Error (Unread { detail }) -> Error (Content_unread { detail })
;;

let rec read_whole stores reads = function
  | [] -> Ok (List.rev reads)
  | span :: rest ->
    let* read = read_content stores span ~take:Rest_of_unit in
    read_whole stores (read :: reads) rest
;;

let item_count ({ kind; _ } : Librarian_read_unit.t) =
  match kind with
  | Turn { unattributed; own; _ } -> List.length unattributed + List.length own
  | Reset { items; _ } -> List.length items
;;

let contents stores ~(width : Librarian_width.width) { before; head; after } =
  let head_take : Librarian_unit_content.take =
    match width with
    | Items count -> First_items count
    | All | Units (_ : Librarian_width.count) -> Rest_of_unit
  in
  let* before = read_whole stores [] before in
  let* head_read = read_content stores head ~take:head_take in
  let* after = read_whole stores [] after in
  let (last : Librarian_unread.span), (ended : Librarian_unit_content.read) =
    match List.rev after with
    | last :: (_ : (Librarian_unread.span * Librarian_unit_content.read) list) -> last
    | [] -> head_read
  in
  let with_items =
    List.filter
      (fun ((span : Librarian_unread.span), (_ : Librarian_unit_content.read)) ->
         Librarian_unread.has_items span)
      after
  in
  let offered : Librarian_width.offered =
    { units = 1 + List.length with_items; head_items = item_count (snd head_read).unit }
  in
  let reads = before @ (head_read :: after) in
  Ok
    { units =
        List.map
          (fun ((_ : Librarian_unread.span), (read : Librarian_unit_content.read)) -> read.unit)
          reads
    ; reach = Librarian_unread.reach last ended.ends
    ; trace = last.through.trace
    ; offered
    }
;;
