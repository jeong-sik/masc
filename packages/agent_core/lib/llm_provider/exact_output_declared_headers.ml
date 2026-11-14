type t = (string * string) list

let empty = []

(* HTTP header names are case-insensitive (RFC 9110 §5.1). *)
let written_by_plan name =
  match String.lowercase_ascii (String.trim name) with
  | "content-type" | "content-length" -> true
  | _ -> false
;;

let of_binding_headers headers =
  List.filter (fun (name, _) -> not (written_by_plan name)) headers
;;

let to_list headers = headers

let request_headers ~kind ~auth_headers ~body headers =
  let headers =
    auth_headers
    @ headers
    @ [ "Content-Type", "application/json"
      ; "Content-Length", string_of_int (String.length body)
      ]
  in
  match (kind : Provider_config.provider_kind) with
  | Anthropic -> Backend_anthropic.request_headers ~body headers
  | Kimi | OpenAI_compat | Ollama | Gemini | Glm -> headers
;;

let%test "the plan's own entity headers are not carried, in any letter case" =
  of_binding_headers
    [ "Content-Type", "application/json"
    ; "x-opencode-session", "fleet"
    ; "content-length", "2"
    ; "CONTENT-TYPE", "text/plain"
    ; "HTTP-Referer", "https://example.invalid"
    ]
  |> to_list
  = [ "x-opencode-session", "fleet"; "HTTP-Referer", "https://example.invalid" ]
;;
