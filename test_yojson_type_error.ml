(* Yojson.Type_error 재현 테스트 *)
(* 사실은 타입이 안 맞는 것이지만, 진실은 우리가 타입을 어떻게 받아들이느냐에 있을지도 *)

let () =
  let json_string = "{\"name\": 123}" in
  let json = Yojson.Safe.from_string json_string in
  (* 사실: name 은 string 이어야 하는데 int 가 왔다 *)
  (* 진실: 우리는 왜 string 이라고 기대했을까? *)
  match Yojson.Safe.to_basic json with
  | `Assoc [("name", `String _)] -> print_endline "사실: 타입이 맞습니다"
  | `Assoc [("name", `Int _)] -> print_endline "진실: 타입이 안 맞지만, 이게 진실일 수 있다"
  | _ -> print_endline "그냥 에러일 뿐"