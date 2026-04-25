let assoc_opt name fields = List.assoc_opt name fields

let error_field context name = Error (context ^ "." ^ name)

let string context name fields =
  match assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> error_field context name

let bool context name fields =
  match assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some _ | None -> error_field context name

let int context name fields =
  match assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some (`Intlit value) -> (
      try Ok (int_of_string value) with Failure _ -> error_field context name)
  | Some _ | None -> error_field context name

let int_opt context name fields =
  match assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some (`Intlit value) -> (
      try Ok (Some (int_of_string value)) with
      | Failure _ -> error_field context name)
  | Some _ -> error_field context name

let float context name fields =
  match assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some (`Intlit value) -> (
      try Ok (float_of_string value) with
      | Failure _ -> error_field context name)
  | Some _ | None -> error_field context name

let string_opt context name fields =
  match assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> error_field context name
