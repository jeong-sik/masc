type t = { id : string; line : Yojson.Safe.t; line_bytes : int }

let utc_day seconds =
  match Ptime.of_float_s seconds with
  | None -> None
  | Some time ->
    let year, month, day = Ptime.to_date time in
    Some (Printf.sprintf "%04d-%02d-%02d" year month day)

let day_json seconds =
  match utc_day seconds with
  | Some day -> `String day
  | None -> `Null

let of_fact (fact : Keeper_memory_os_types.fact) =
  let id = Keeper_memory_os_types.memory_id fact in
  let line = `Assoc
    ["question_id", `String id;
     "category", `String (Keeper_memory_os_types.category_to_string fact.category);
     "claim", `String fact.claim;
     "first_seen", day_json fact.first_seen;
     "last_seen", day_json fact.last_seen;
     "origin", `String (Keeper_memory_os_types.origin_kind_to_string fact.origin.kind)] in
  { id; line; line_bytes = String.length (Yojson.Safe.to_string line) }

let id { id; line = _; line_bytes = _ } = id
let line { id = _; line; line_bytes = _ } = line
let line_bytes { id = _; line = _; line_bytes } = line_bytes

let state_bytes_per_piece = 80_000

type piece = { first : t; rest : t list; bytes : int }

let piece_candidates { first; rest; bytes = _ } = first :: rest
let piece_line_bytes { first = _; rest = _; bytes } = bytes

type open_piece = { head : t; tail_rev : t list; size : int }

let open_with candidate =
  { head = candidate; tail_rev = []; size = candidate.line_bytes }

let close { head; tail_rev; size } = { first = head; rest = List.rev tail_rev; bytes = size }

let split ~piece_bytes candidates =
  let add (closed_rev, current) candidate =
    match current with
    | None -> closed_rev, Some (open_with candidate)
    | Some open_piece when open_piece.size + candidate.line_bytes > piece_bytes ->
      close open_piece :: closed_rev, Some (open_with candidate)
    | Some open_piece ->
      closed_rev,
      Some { open_piece with
             tail_rev = candidate :: open_piece.tail_rev;
             size = open_piece.size + candidate.line_bytes } in
  let closed_rev, last = List.fold_left add ([], None) candidates in
  List.rev (match last with
    | None -> closed_rev
    | Some open_piece -> close open_piece :: closed_rev)
