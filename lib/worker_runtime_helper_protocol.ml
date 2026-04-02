module Oas = Agent_sdk

type error_kind =
  | Spec_parse
  | Runtime
  | Timeout
  | Internal

type error_payload = {
  message : string;
  kind : error_kind;
}

let error_kind_to_string = function
  | Spec_parse -> "spec_parse"
  | Runtime -> "runtime"
  | Timeout -> "timeout"
  | Internal -> "internal"

let error_kind_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "spec_parse" -> Some Spec_parse
  | "runtime" -> Some Runtime
  | "timeout" -> Some Timeout
  | "internal" -> Some Internal
  | _ -> None

let hex_char value =
  if value < 10 then Char.chr (Char.code '0' + value)
  else Char.chr (Char.code 'a' + value - 10)

let hex_encode text =
  let len = String.length text in
  let bytes = Bytes.create (len * 2) in
  for idx = 0 to len - 1 do
    let code = Char.code text.[idx] in
    Bytes.set bytes (idx * 2) (hex_char ((code lsr 4) land 0xF));
    Bytes.set bytes ((idx * 2) + 1) (hex_char (code land 0xF))
  done;
  Bytes.unsafe_to_string bytes

let hex_value = function
  | '0' .. '9' as ch -> Char.code ch - Char.code '0'
  | 'a' .. 'f' as ch -> 10 + Char.code ch - Char.code 'a'
  | 'A' .. 'F' as ch -> 10 + Char.code ch - Char.code 'A'
  | ch ->
      invalid_arg
        (Printf.sprintf "invalid hex character in worker helper payload: %c" ch)

let hex_decode text =
  let len = String.length text in
  if len mod 2 <> 0 then invalid_arg "hex payload length must be even";
  let bytes = Bytes.create (len / 2) in
  let rec loop idx =
    if idx >= len then ()
    else
      let hi = hex_value text.[idx] in
      let lo = hex_value text.[idx + 1] in
      Bytes.set bytes (idx / 2) (Char.chr ((hi lsl 4) lor lo));
      loop (idx + 2)
  in
  loop 0;
  Bytes.unsafe_to_string bytes

let marshal_run_result (run_result : Worker_container_types.run_result) =
  run_result |> fun value -> Marshal.to_string value [] |> hex_encode

let unmarshal_run_result payload =
  let raw = hex_decode payload in
  Marshal.from_string raw 0

let success_json (run_result : Worker_container_types.run_result) =
  `Assoc [ ("ok_marshaled", `String (marshal_run_result run_result)) ]

let error_json (payload : error_payload) =
  `Assoc
    [
      ( "error",
        `Assoc
          [
            ("message", `String payload.message);
            ("kind", `String (error_kind_to_string payload.kind));
          ] );
    ]

let parse_stdout (stdout : string) :
    ((Worker_container_types.run_result, error_payload) result, string) result =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string stdout in
    match json |> member "ok_marshaled" with
    | `String payload ->
        Ok (Ok (unmarshal_run_result payload))
    | _ -> (
        match json |> member "error" with
        | `Assoc fields ->
            let message =
              match List.assoc_opt "message" fields with
              | Some (`String value) -> value
              | _ -> "worker helper error"
            in
            let kind =
              match List.assoc_opt "kind" fields with
              | Some (`String value) -> (
                  match error_kind_of_string value with
                  | Some kind -> kind
                  | None -> Internal)
              | _ -> Internal
            in
            Ok (Error { message; kind })
        | _ -> Error "worker helper stdout did not contain ok_marshaled or error")
  with
  | Invalid_argument msg -> Error msg
  | Failure msg -> Error msg
  | Yojson.Json_error msg -> Error ("invalid worker helper JSON: " ^ msg)
