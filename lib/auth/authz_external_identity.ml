(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

type t =
  | Google of { sub : string }
  | Github of { user_id : int }

type error =
  | Google_sub_empty
  | Google_sub_too_long
  | Google_sub_invalid_byte of { index : int }
  | Github_user_id_not_positive
  | Github_user_id_too_large

(* OpenID Connect Core 1.0, section 5.1: a [sub] is at most 255 ASCII
   characters. *)
let max_sub_length = 255

(* The largest integer that {!Authz_body.int} takes. *)
let max_github_user_id = (1 lsl 53) - 1

let error_to_string = function
  | Google_sub_empty -> "the Google sub is empty"
  | Google_sub_too_long -> Printf.sprintf "the Google sub is longer than %d bytes" max_sub_length
  | Google_sub_invalid_byte { index } ->
    Printf.sprintf "the Google sub has a byte outside ! to ~ at %d" index
  | Github_user_id_not_positive -> "the GitHub user id is not positive"
  | Github_user_id_too_large -> "the GitHub user id is above 2^53 - 1"
;;

let is_visible_ascii c = c >= '!' && c <= '~'

let first_invalid_byte s =
  let rec go i =
    if i >= String.length s then None else if is_visible_ascii s.[i] then go (i + 1) else Some i
  in
  go 0
;;

let google ~sub =
  if String.length sub = 0
  then Error Google_sub_empty
  else if String.length sub > max_sub_length
  then Error Google_sub_too_long
  else (
    match first_invalid_byte sub with
    | Some index -> Error (Google_sub_invalid_byte { index })
    | None -> Ok (Google { sub }))
;;

let github ~user_id =
  if user_id <= 0
  then Error Github_user_id_not_positive
  else if user_id > max_github_user_id
  then Error Github_user_id_too_large
  else Ok (Github { user_id })
;;

let compare a b =
  match a, b with
  | Google a, Google b -> String.compare a.sub b.sub
  | Github a, Github b -> Int.compare a.user_id b.user_id
  | Google _, Github _ -> -1
  | Github _, Google _ -> 1
;;

let equal a b = Int.equal (compare a b) 0

let to_string = function
  | Google { sub } -> "google:" ^ sub
  | Github { user_id } -> "github:" ^ string_of_int user_id
;;

let google_label = "google"
let github_label = "github"

let to_body = function
  | Google { sub } ->
    let* provider = Authz_body.string google_label in
    let* sub = Authz_body.string sub in
    Authz_body.object_ [ "provider", provider; "sub", sub ]
  | Github { user_id } ->
    let* provider = Authz_body.string github_label in
    let* user_id = Authz_body.int user_id in
    Authz_body.object_ [ "provider", provider; "user_id", user_id ]
;;

type body_error =
  | Not_an_object
  | Unknown_provider of string
  | Wrong_members
  | Invalid of error

let body_error_to_string = function
  | Not_an_object -> "an identity is an object"
  | Unknown_provider label -> Printf.sprintf "%S is not a provider of an identity" label
  | Wrong_members ->
    "a Google identity has the members provider and sub, both strings, and a GitHub identity \
     provider, a string, and user_id, a number, in this order"
  | Invalid error -> error_to_string error
;;

let of_body (body : Authz_body.t) =
  let valid = Result.map_error (fun error -> Invalid error) in
  match body with
  | Authz_body.Object (("provider", Authz_body.String provider) :: members) ->
    if String.equal provider google_label
    then (
      match members with
      | [ ("sub", sub) ] ->
        (match Authz_body.string_value sub with
         | Some sub -> valid (google ~sub)
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal provider github_label
    then (
      match members with
      | [ ("user_id", user_id) ] ->
        (match Authz_body.int_value user_id with
         | Some user_id -> valid (github ~user_id)
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_provider provider)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;

module Map = Map.Make (struct
    type nonrec t = t

    let compare = compare
  end)
