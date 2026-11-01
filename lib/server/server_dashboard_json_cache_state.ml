type owner = unit ref

type phase = Idle | Refreshing of owner

type t =
  { value : Yojson.Safe.t option
  ; updated_at : float
  ; last_error : string option
  ; phase : phase
  }

type view =
  | Fresh of { json : Yojson.Safe.t; age_s : float }
  | Stale of
      { json : Yojson.Safe.t
      ; age_s : float
      ; last_error : string option
      }
  | Warming of { last_error : string option }

type start_plan = Start_plan of t

type admission =
  | Reuse of view
  | Refresh of view * start_plan

let empty =
  { value = None; updated_at = 0.; last_error = None; phase = Idle }

let updated_at state = state.updated_at

let admit ~now ~ttl_s state =
  let age_s = now -. state.updated_at in
  let stale view =
    match state.phase with
    | Idle -> Refresh (view, Start_plan state)
    | Refreshing _ -> Reuse view
  in
  match state.value with
  | Some json when age_s <= ttl_s -> Reuse (Fresh { json; age_s })
  | Some json -> stale (Stale { json; age_s; last_error = state.last_error })
  | None -> stale (Warming { last_error = state.last_error })

let start (Start_plan state) =
  (* Mutable-cell identity is generative under OCaml's physical-equality
     contract. The cell is never written; all cache data remains immutable. *)
  let owner = ref () in
  { state with phase = Refreshing owner }, owner

let settle ~owner ~now result state =
  match state.phase with
  | Refreshing current when current == owner ->
    Some
      (match result with
       | Ok json ->
         { value = Some json; updated_at = now; last_error = None; phase = Idle }
       | Error message ->
         { state with last_error = Some message; phase = Idle })
  | Refreshing _ | Idle -> None

let cancel ~owner state =
  match state.phase with
  | Refreshing current when current == owner -> Some { state with phase = Idle }
  | Refreshing _ | Idle -> None
