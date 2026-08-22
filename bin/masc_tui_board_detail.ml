type request = {
  post_id : string;
  generation : int64;
}

type 'a status =
  | Status_absent
  | Status_loading of request
  | Status_ready of request * 'a
  | Status_failed of request * string

type 'a t = {
  latest_generation : int64;
  status : 'a status;
}

type 'a view =
  | Absent
  | Loading
  | Ready of 'a
  | Failed of string

type 'a start_result =
  | Already_loading
  | Started of 'a t * request

let initial = { latest_generation = 0L; status = Status_absent }

let request_post_id request = request.post_id

let same_request left right =
  String.equal left.post_id right.post_id
  && Int64.equal left.generation right.generation

let is_current state request =
  match state.status with
  | Status_loading current -> same_request current request
  | Status_absent | Status_ready _ | Status_failed _ -> false

let start state ~post_id =
  match state.status with
  | Status_loading request when String.equal request.post_id post_id ->
      Already_loading
  | Status_absent | Status_loading _ | Status_ready _ | Status_failed _ ->
      let generation = Int64.succ state.latest_generation in
      let request = { post_id; generation } in
      Started
        ({ latest_generation = generation; status = Status_loading request }, request)

let clear state = { state with status = Status_absent }

let complete state request result =
  if not (is_current state request) then state
  else
    let status =
      match result with
      | Ok value -> Status_ready (request, value)
      | Error error -> Status_failed (request, error)
    in
    { state with status }

let view_for state ~post_id =
  let request_matches request = String.equal request.post_id post_id in
  match state.status with
  | Status_loading request when request_matches request -> Loading
  | Status_ready (request, value) when request_matches request -> Ready value
  | Status_failed (request, error) when request_matches request -> Failed error
  | Status_absent | Status_loading _ | Status_ready _ | Status_failed _ -> Absent
