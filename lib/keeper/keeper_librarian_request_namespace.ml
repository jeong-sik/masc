type t = Admission of string | History of string | Floor_step of string | Other
let of_request_id id = match Keeper_librarian_admission_capture.scope_of_request_id id with
  | Ok scope -> Admission scope
  | Error _ -> match Keeper_librarian_durable_request.scope_of_request_id id with
    | Ok scope -> History scope
    | Error _ -> match Keeper_librarian_floor_step_request.scope_of_request_id id with
      | Ok scope -> Floor_step scope
      | Error _ -> Other
