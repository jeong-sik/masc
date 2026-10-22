let ( let* ) = Result.bind
let cookies_limit = 200

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

(* The attributes that scope a cookie. [value] is not among them. *)
let kept_keys = [ "name"; "domain"; "path"; "secure"; "httpOnly"; "sameSite"; "expiry" ]

let project cookie =
  match field "name" cookie with
  | Some (`String _) ->
    (match cookie with
     | `Assoc fields -> Ok (`Assoc (List.filter (fun (key, _) -> List.mem key kept_keys) fields))
     | _ -> Error "WebDriver cookie is not an object")
  | _ -> Error "WebDriver cookie has no name"

let of_driver = function
  | `List cookies ->
    let* rows = List.fold_left (fun acc cookie ->
      let* rows = acc in
      let* row = project cookie in
      Ok (row :: rows)) (Ok []) cookies in
    let rows = List.rev rows in
    Ok (`Assoc [ "cookies", `List (List.filteri (fun index _ -> index < cookies_limit) rows)
               ; "total", `Int (List.length rows); "valuesWithheld", `Bool true ])
  | _ -> Error "WebDriver cookies are not a list"
