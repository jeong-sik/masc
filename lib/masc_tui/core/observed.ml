type 'a t =
  | Loading of { since_ns : Clock.Mono.t }
  | Value of { data : 'a; observed_at : Clock.Mono.t; stale : bool }
  | Absent
  | Unreported
  | Failed of { reason : string; retryable : bool; at : Clock.Mono.t }

let loading ~since_ns = Loading { since_ns }
let value ~observed_at ?(stale = false) data = Value { data; observed_at; stale }
let absent = Absent
let unreported = Unreported
let failed ~reason ~retryable ~at = Failed { reason; retryable; at }

let map f = function
  | Loading { since_ns } -> Loading { since_ns }
  | Value { data; observed_at; stale } ->
      Value { data = f data; observed_at; stale }
  | Absent -> Absent
  | Unreported -> Unreported
  | Failed { reason; retryable; at } -> Failed { reason; retryable; at }

let bind t f =
  match t with
  | Loading { since_ns } -> Loading { since_ns }
  | Value { data; observed_at = _; stale = _ } -> f data
  | Absent -> Absent
  | Unreported -> Unreported
  | Failed { reason; retryable; at } -> Failed { reason; retryable; at }

let to_option = function
  | Value { data; observed_at = _; stale = _ } -> Some data
  | Loading _ | Absent | Unreported | Failed _ -> None

let is_loading = function
  | Loading _ -> true
  | Value _ | Absent | Unreported | Failed _ -> false

let is_value = function
  | Value _ -> true
  | Loading _ | Absent | Unreported | Failed _ -> false

let is_stale = function
  | Value { stale; data = _; observed_at = _ } -> stale
  | Loading _ | Absent | Unreported | Failed _ -> false

let mark_stale = function
  | Value { data; observed_at; stale = _ } ->
      Value { data; observed_at; stale = true }
  | (Loading _ | Absent | Unreported | Failed _) as other -> other

let observed_at = function
  | Value { observed_at; data = _; stale = _ } -> Some observed_at
  | Loading _ | Absent | Unreported | Failed _ -> None

let equal eq a b =
  match a, b with
  | Loading l1, Loading l2 -> Clock.Mono.equal l1.since_ns l2.since_ns
  | Value v1, Value v2 ->
      eq v1.data v2.data
      && Clock.Mono.equal v1.observed_at v2.observed_at
      && Bool.equal v1.stale v2.stale
  | Absent, Absent | Unreported, Unreported -> true
  | Failed f1, Failed f2 ->
      String.equal f1.reason f2.reason
      && Bool.equal f1.retryable f2.retryable
      && Clock.Mono.equal f1.at f2.at
  | Loading _, (Value _ | Absent | Unreported | Failed _)
  | Value _, (Loading _ | Absent | Unreported | Failed _)
  | Absent, (Loading _ | Value _ | Unreported | Failed _)
  | Unreported, (Loading _ | Value _ | Absent | Failed _)
  | Failed _, (Loading _ | Value _ | Absent | Unreported) ->
      false
