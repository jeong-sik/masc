type state = Cache_fresh | Cache_stale_refreshing | Cache_warming

let to_string = function
  | Cache_fresh -> "fresh"
  | Cache_stale_refreshing -> "stale_refreshing"
  | Cache_warming -> "warming"

let of_string = function
  | "fresh" -> Some Cache_fresh
  | "stale_refreshing" -> Some Cache_stale_refreshing
  | "warming" -> Some Cache_warming
  | _ -> None
