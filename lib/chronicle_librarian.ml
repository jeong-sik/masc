(* Chronicle Librarian — implementation.

   See chronicle_librarian.mli for the interface contract. *)

type store = Chronicle_event.t list
(* Insertion order. The most-recent event is at the tail. *)

let empty : store = []

let add (s : store) ev = s @ [ ev ]

let of_list (xs : Chronicle_event.t list) : store = xs

let to_list (s : store) : Chronicle_event.t list = s

let len (s : store) = List.length s

let tokenise text =
  let buf = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      let lc = Char.lowercase_ascii c in
      if (lc >= 'a' && lc <= 'z')
         || (lc >= '0' && lc <= '9')
         || lc = '_'
      then Buffer.add_char buf lc
      else Buffer.add_char buf ' ')
    text;
  Buffer.contents buf
  |> String.split_on_char ' '
  |> List.filter (fun w -> String.length w >= 2)

let summary_tokens (ev : Chronicle_event.t) =
  let from_summary = tokenise ev.content.summary in
  let from_detail =
    match ev.content.detail with
    | None -> []
    | Some s -> tokenise s
  in
  from_summary @ from_detail

let event_keywords ev =
  ev.Chronicle_event.context.tags @ summary_tokens ev

let max_timestamp (s : store) =
  List.fold_left
    (fun acc ev -> max acc ev.Chronicle_event.timestamp)
    0 s

let to_gravity_item ~now_ms (ev : Chronicle_event.t) =
  let recency_seconds =
    let dt_ms = now_ms - ev.timestamp in
    if dt_ms < 0 then 0.0 else float_of_int dt_ms /. 1000.0
  in
  Cognitive_gravity.{
    payload = ev;
    keywords = event_keywords ev;
    recency_seconds;
    frequency_weight = 0.0;
  }

let take n xs =
  let rec aux k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | x :: rest -> aux (k - 1) (x :: acc) rest
  in
  aux n [] xs

let search (s : store) ~query ?now_ms ?limit () =
  let now =
    match now_ms with
    | Some n -> n
    | None ->
      (* Default: 1 ms after the most-recent event so that even the
         freshest event has a tiny but non-zero recency offset. *)
      let m = max_timestamp s in
      if m = 0 then 1 else m + 1
  in
  let items = List.map (to_gravity_item ~now_ms:now) s in
  let ranked = Cognitive_gravity.rank ~query items in
  let payload_pairs =
    List.map (fun (item, score) -> (item.Cognitive_gravity.payload, score)) ranked
  in
  match limit with
  | None -> payload_pairs
  | Some n -> take n payload_pairs

let filter_by_event_type (s : store) types =
  List.filter
    (fun ev -> List.mem ev.Chronicle_event.event_type types)
    s

let filter_by_session (s : store) ~session_id =
  List.filter
    (fun ev -> ev.Chronicle_event.context.session_id = session_id)
    s

let filter_by_time_range (s : store) ~from_ms ~to_ms =
  List.filter
    (fun ev ->
      ev.Chronicle_event.timestamp >= from_ms
      && ev.Chronicle_event.timestamp <= to_ms)
    s
