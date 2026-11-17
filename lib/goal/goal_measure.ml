(* What a Goal measures and what was measured. See the interface. *)

open Result.Syntax

type label = string
type count = int
type finite = float

type direction =
  | At_least
  | At_most

type t =
  | Count of { noun : label; total : count }
  | Quantity of { unit : label; direction : direction; target : finite }
  | Done_when of { condition : label }

type observed =
  | Counted of { done_ : int }
  | Quantified of { value : finite }
  | Decided of bool

type paired =
  | Count_pair of { noun : label; total : count; done_ : int }
  | Quantity_pair of
      { unit : label; direction : direction; target : finite; value : finite }
  | Done_pair of { condition : label; decided : bool }

type mismatch =
  | Shape_differs
  | Count_over_total of { done_ : int; total : int }

let make_label text =
  if String.trim text = "" then Error "label is blank"
  else if String.contains text '\n' || String.contains text '\r' then
    Error "label spans more than one line"
  else Ok text

let make_count total =
  if total >= 1 then Ok total
  else Error (Printf.sprintf "count %d is not one or more" total)

let make_finite value =
  match Float.classify_float value with
  | FP_nan | FP_infinite -> Error "number is not finite"
  | FP_normal | FP_subnormal | FP_zero -> Ok value

let count ~noun ~total = Count { noun; total }
let quantity ~unit ~direction ~target = Quantity { unit; direction; target }
let done_when ~condition = Done_when { condition }

let counted done_ =
  if done_ >= 0 then Ok (Counted { done_ })
  else Error (Printf.sprintf "counted %d is negative" done_)

let quantified value = Quantified { value }
let decided value = Decided value

let pair measure observed =
  match measure, observed with
  | Count { noun; total }, Counted { done_ } ->
    (* Counted already refuses a negative count; the total is known only here. *)
    if done_ > total then Error (Count_over_total { done_; total })
    else Ok (Count_pair { noun; total; done_ })
  | Quantity { unit; direction; target }, Quantified { value } ->
    Ok (Quantity_pair { unit; direction; target; value })
  | Done_when { condition }, Decided decided -> Ok (Done_pair { condition; decided })
  | Count _, (Quantified _ | Decided _)
  | Quantity _, (Counted _ | Decided _)
  | Done_when _, (Counted _ | Quantified _) -> Error Shape_differs

type reach =
  | Reached
  | Short_of

let reach = function
  | Count_pair { total; done_; _ } -> if done_ >= total then Reached else Short_of
  | Quantity_pair { direction = At_least; target; value; _ } ->
    if value >= target then Reached else Short_of
  | Quantity_pair { direction = At_most; target; value; _ } ->
    if value <= target then Reached else Short_of
  | Done_pair { decided = true; _ } -> Reached
  | Done_pair { decided = false; _ } -> Short_of

let mismatch_to_string = function
  | Shape_differs -> "the measurement is not the shape of the Goal's measure"
  | Count_over_total { done_; total } ->
    Printf.sprintf "counted %d is more than the total %d" done_ total

let direction_to_string = function
  | At_least -> "at_least"
  | At_most -> "at_most"

let direction_of_string = function
  | "at_least" -> Ok At_least
  | "at_most" -> Ok At_most
  | other -> Error (Printf.sprintf "unknown direction %S" other)

let to_yojson = function
  | Count { noun; total } ->
    `Assoc [ "kind", `String "count"; "noun", `String noun; "total", `Int total ]
  | Quantity { unit; direction; target } ->
    `Assoc
      [ "kind", `String "quantity"
      ; "unit", `String unit
      ; "direction", `String (direction_to_string direction)
      ; "target", `Float target
      ]
  | Done_when { condition } ->
    `Assoc [ "kind", `String "done_when"; "condition", `String condition ]

let observed_to_yojson = function
  | Counted { done_ } -> `Assoc [ "kind", `String "counted"; "done", `Int done_ ]
  | Quantified { value } -> `Assoc [ "kind", `String "quantified"; "value", `Float value ]
  | Decided value -> `Assoc [ "kind", `String "decided"; "value", `Bool value ]

(* Exactly these keys, each once: a missing or extra field is refused rather
   than defaulted or ignored. *)
let exact_fields ~what ~expected fields =
  let names = List.sort String.compare (List.map fst fields) in
  if names = List.sort String.compare expected then Ok ()
  else
    Error
      (Printf.sprintf "%s: expected exactly the fields %s" what
         (String.concat ", " expected))

let field what fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s: missing %s" what name)

let string_field what fields name =
  let* value = field what fields name in
  match value with
  | `String text -> Ok text
  | _ -> Error (Printf.sprintf "%s: %s is not a string" what name)

let label_field what fields name =
  let* text = string_field what fields name in
  Result.map_error (fun reason -> Printf.sprintf "%s: %s %s" what name reason)
    (make_label text)

let int_field what fields name =
  let* value = field what fields name in
  match value with
  | `Int number -> Ok number
  | _ -> Error (Printf.sprintf "%s: %s is not an integer" what name)

(* JSON writes 100 and 100.0 alike for a number; both are the same finite
   value. Integer literals beyond an OCaml int stay refused. *)
let finite_field what fields name =
  let* value = field what fields name in
  let* number =
    match value with
    | `Int number -> Ok (float_of_int number)
    | `Float number -> Ok number
    | _ -> Error (Printf.sprintf "%s: %s is not a number" what name)
  in
  Result.map_error (fun reason -> Printf.sprintf "%s: %s %s" what name reason)
    (make_finite number)

let kind_of what = function
  | `Assoc fields ->
    let* kind = string_field what fields "kind" in
    Ok (kind, fields)
  | _ -> Error (Printf.sprintf "%s: expected an object" what)

let of_yojson json =
  let what = "measure" in
  let* kind, fields = kind_of what json in
  match kind with
  | "count" ->
    let* () = exact_fields ~what ~expected:[ "kind"; "noun"; "total" ] fields in
    let* noun = label_field what fields "noun" in
    let* total = int_field what fields "total" in
    let* total =
      Result.map_error (fun reason -> what ^ ": total " ^ reason) (make_count total)
    in
    Ok (count ~noun ~total)
  | "quantity" ->
    let* () =
      exact_fields ~what ~expected:[ "kind"; "unit"; "direction"; "target" ] fields
    in
    let* unit = label_field what fields "unit" in
    let* direction_text = string_field what fields "direction" in
    let* direction =
      Result.map_error (fun reason -> what ^ ": " ^ reason)
        (direction_of_string direction_text)
    in
    let* target = finite_field what fields "target" in
    Ok (quantity ~unit ~direction ~target)
  | "done_when" ->
    let* () = exact_fields ~what ~expected:[ "kind"; "condition" ] fields in
    let* condition = label_field what fields "condition" in
    Ok (done_when ~condition)
  | other -> Error (Printf.sprintf "%s: unknown kind %S" what other)

let observed_of_yojson json =
  let what = "observed" in
  let* kind, fields = kind_of what json in
  match kind with
  | "counted" ->
    let* () = exact_fields ~what ~expected:[ "kind"; "done" ] fields in
    let* done_ = int_field what fields "done" in
    Result.map_error (fun reason -> what ^ ": " ^ reason) (counted done_)
  | "quantified" ->
    let* () = exact_fields ~what ~expected:[ "kind"; "value" ] fields in
    let* value = finite_field what fields "value" in
    Ok (quantified value)
  | "decided" ->
    let* () = exact_fields ~what ~expected:[ "kind"; "value" ] fields in
    let* value = field what fields "value" in
    (match value with
     | `Bool value -> Ok (decided value)
     | _ -> Error (what ^ ": value is not a boolean"))
  | other -> Error (Printf.sprintf "%s: unknown kind %S" what other)

let direction_equal left right =
  match left, right with
  | At_least, At_least | At_most, At_most -> true
  | At_least, At_most | At_most, At_least -> false

let equal left right =
  match left, right with
  | Count l, Count r -> String.equal l.noun r.noun && Int.equal l.total r.total
  | Quantity l, Quantity r ->
    String.equal l.unit r.unit
    && direction_equal l.direction r.direction
    && Float.equal l.target r.target
  | Done_when l, Done_when r -> String.equal l.condition r.condition
  | Count _, (Quantity _ | Done_when _)
  | Quantity _, (Count _ | Done_when _)
  | Done_when _, (Count _ | Quantity _) -> false

let observed_equal left right =
  match left, right with
  | Counted l, Counted r -> Int.equal l.done_ r.done_
  | Quantified l, Quantified r -> Float.equal l.value r.value
  | Decided l, Decided r -> Bool.equal l r
  | Counted _, (Quantified _ | Decided _)
  | Quantified _, (Counted _ | Decided _)
  | Decided _, (Counted _ | Quantified _) -> false
