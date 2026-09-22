module Decode = Masc.Tui_decode

let safe = Decode.sanitize_terminal_text

let seat_text = function
  | Decode.Fusion_panel_seat identity -> "panel/" ^ safe identity
  | Decode.Fusion_judge_seat { fs_role; fs_identity } ->
      Printf.sprintf "judge/%s/%s" (Decode.fusion_judge_role_label fs_role) (safe fs_identity)

let route_line (route : Decode.fusion_seat_route) =
  let answer =
    match route.fsr_answered_by with
    | Some runtime -> "answered by " ^ safe runtime
    | None -> "no candidate answered"
  in
  Printf.sprintf "%s \xc2\xb7 route %s \xe2\x86\x92 %s" (seat_text route.fsr_seat)
    (safe route.fsr_route) answer

let attempt_line (attempt : Decode.fusion_seat_attempt) =
  Printf.sprintf "    %s: %s %s" (safe attempt.fsa_runtime) (safe attempt.fsa_code)
    (safe attempt.fsa_detail)

let lines routes =
  List.concat_map
    (fun (route : Decode.fusion_seat_route) ->
      route_line route :: List.map attempt_line route.fsr_failed_attempts)
    routes
