type kind = Observer | Agent_stream | Presence

type entry = {
  session_id : string;
  client_id : int;
  kind : kind;
  queue_depth : int;
  last_event_id : int;
  last_seen_at : float;
}

module Names = Map.Make (String)

module Hot = Set.Make (struct
  type t = entry

  let compare left right =
    let depth = Int.compare right.queue_depth left.queue_depth in
    if depth <> 0 then depth
    else
      let seen = Float.compare left.last_seen_at right.last_seen_at in
      if seen <> 0 then seen
      else
        let name = String.compare left.session_id right.session_id in
        if name <> 0 then name else Int.compare left.client_id right.client_id
end)

type t = {
  entries : entry Names.t;
  hot : Hot.t;
  count : int;
  observers : int;
  agent_streams : int;
  presences : int;
  total_queue_depth : int;
}

let empty = {
  entries = Names.empty;
  hot = Hot.empty;
  count = 0;
  observers = 0;
  agent_streams = 0;
  presences = 0;
  total_queue_depth = 0;
}

let adjust_kind t kind by =
  match kind with
  | Observer -> { t with observers = t.observers + by }
  | Agent_stream -> { t with agent_streams = t.agent_streams + by }
  | Presence -> { t with presences = t.presences + by }

let hot_add entry hot =
  if entry.queue_depth = 0 then hot else Hot.add entry hot

let hot_remove entry hot =
  if entry.queue_depth = 0 then hot else Hot.remove entry hot

let remove_entry t entry =
  let t = adjust_kind t entry.kind (-1) in
  { t with
    entries = Names.remove entry.session_id t.entries;
    hot = hot_remove entry t.hot;
    count = t.count - 1;
    total_queue_depth = t.total_queue_depth - entry.queue_depth;
  }

let register t ~session_id ~client_id ~kind ~last_event_id ~last_seen_at =
  let t = match Names.find_opt session_id t.entries with
    | None -> t
    | Some previous -> remove_entry t previous in
  let entry = { session_id; client_id; kind; queue_depth = 0; last_event_id; last_seen_at } in
  let t = adjust_kind t kind 1 in
  { t with entries = Names.add session_id entry t.entries; count = t.count + 1 }

let remove t ~session_id ~client_id =
  match Names.find_opt session_id t.entries with
  | Some entry when entry.client_id = client_id -> remove_entry t entry
  | None | Some _ -> t

let observe t ~session_id ~client_id ~queue_depth ~last_event_id ~last_seen_at =
  if queue_depth < 0 then invalid_arg "Sse_queue_inventory.observe: negative queue depth";
  match Names.find_opt session_id t.entries with
  | None -> t
  | Some previous when previous.client_id <> client_id -> t
  | Some previous ->
      let entry = { previous with queue_depth; last_event_id; last_seen_at } in
      let hot = hot_remove previous t.hot |> hot_add entry in
      { t with
        entries = Names.add session_id entry t.entries;
        hot;
        total_queue_depth = t.total_queue_depth - previous.queue_depth + queue_depth;
      }

let count t = t.count

let count_kind t = function
  | Observer -> t.observers
  | Agent_stream -> t.agent_streams
  | Presence -> t.presences

let total_queue_depth t = t.total_queue_depth

let max_queue_depth t =
  match Hot.min_elt_opt t.hot with
  | None -> 0
  | Some entry -> entry.queue_depth

let hot ~limit t =
  if limit <= 0 then []
  else Hot.to_seq t.hot |> Seq.take limit |> List.of_seq
