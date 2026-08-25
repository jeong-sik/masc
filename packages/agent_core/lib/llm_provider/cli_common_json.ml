let member_str key json =
  Yojson.Safe.Util.(json |> member key |> to_string_option) |> Option.value ~default:""
;;

let member_int key json =
  Yojson.Safe.Util.(json |> member key |> to_int_option) |> Option.value ~default:0
;;

let member_bool key json =
  Yojson.Safe.Util.(json |> member key |> to_bool_option) |> Option.value ~default:false
;;

let json_of_string_list lst = `List (List.map (fun s -> `String s) lst)

let string_list_of_json lst =
  List.filter_map
    (function
      | `String s -> Some s
      | _ -> None)
    lst
;;

let json_of_string_pairs pairs = `Assoc (List.map (fun (k, v) -> k, `String v) pairs)

[@@@coverage off]

let%test "member_str missing key" = member_str "nope" (`Assoc []) = ""
let%test "member_str present" = member_str "k" (`Assoc [ "k", `String "v" ]) = "v"
let%test "member_str null returns default" = member_str "k" (`Assoc [ "k", `Null ]) = ""
let%test "member_int missing key" = member_int "nope" (`Assoc []) = 0
let%test "member_int present" = member_int "n" (`Assoc [ "n", `Int 42 ]) = 42
let%test "member_bool missing key" = member_bool "nope" (`Assoc []) = false
let%test "member_bool present" = member_bool "b" (`Assoc [ "b", `Bool true ]) = true
