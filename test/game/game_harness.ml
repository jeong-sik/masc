open Yojson.Safe.Util

let fail msg =
  prerr_endline ("[game_harness] FAIL: " ^ msg);
  exit 1

let contains_substring haystack needle =
  let hs = String.lowercase_ascii haystack in
  let nd = String.lowercase_ascii needle in
  let hs_len = String.length hs in
  let nd_len = String.length nd in
  if nd_len = 0 then true
  else if nd_len > hs_len then false
  else
    let rec starts_at i j =
      if j = nd_len then true
      else if hs.[i + j] <> nd.[j] then false
      else starts_at i (j + 1)
    in
    let rec loop i =
      if i > hs_len - nd_len then false
      else if starts_at i 0 then true
      else loop (i + 1)
    in
    loop 0

let expect_ok label = function
  | (true, body) -> body
  | (false, msg) -> fail (Printf.sprintf "%s -> %s" label msg)

let expect_err_contains label expected_sub = function
  | (false, msg) ->
      if contains_substring msg expected_sub then ()
      else fail (Printf.sprintf "%s -> unexpected error: %s" label msg)
  | (true, body) ->
      fail (Printf.sprintf "%s -> expected error but got success: %s" label body)

let call ctx name args =
  match Masc_mcp.Tool_game.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> (false, Printf.sprintf "dispatch returned None for %s" name)

let parse_json label body =
  try Yojson.Safe.from_string body
  with _ -> fail (Printf.sprintf "%s -> invalid json: %s" label body)

let ensure_dir path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755

let make_temp_dir () =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "masc-game-harness-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  ensure_dir dir;
  dir

let expect_field_eq_string label json key expected =
  let actual = json |> member key |> to_string_option |> Option.value ~default:"" in
  if actual <> expected then
    fail
      (Printf.sprintf "%s -> field %s expected=%s actual=%s" label key expected
         actual)

let () =
  let masc_dir = make_temp_dir () in
  let gm_ctx : Masc_mcp.Tool_game.context =
    { masc_dir; agent_name = "gm-alpha" }
  in
  let player_ctx : Masc_mcp.Tool_game.context =
    { masc_dir; agent_name = "player-1" }
  in

  let _ =
    call gm_ctx "masc_game_policy_set"
      (`Assoc
        [
          ("gm_agents", `List [ `String "gm-alpha" ]);
          ("strict_actor_match", `Bool true);
        ])
    |> expect_ok "policy_set"
    |> parse_json "policy_set"
  in

  call gm_ctx "masc_game_object_set"
    (`Assoc [ ("object_id", `String "jail_door"); ("status", `String "broken") ])
  |> expect_ok "object_set";

  call player_ctx "masc_game_declare_intent"
    (`Assoc
      [
        ("agent_id", `String "player-1");
        ("intent", `String "I will break jail_door again.");
      ])
  |> expect_ok "declare_intent_blocked_case";

  call gm_ctx "masc_game_resolve_judgment"
    (`Assoc
      [
        ("caller_id", `String "gm-alpha");
        ("target_agent_id", `String "player-1");
        ("ability", `String "STR");
        ("proposed_narrative", `String "GM judgment");
        ("difficulty_score", `Int 12);
      ])
  |> expect_err_contains "resolve_blocked_by_anchor" "reality anchor";

  call player_ctx "masc_game_declare_intent"
    (`Assoc
      [
        ("agent_id", `String "player-1");
        ("intent", `String "I inspect the corridor.");
      ])
  |> expect_ok "declare_intent_allowed_case";

  let judgment_json =
    call gm_ctx "masc_game_resolve_judgment"
      (`Assoc
        [
          ("caller_id", `String "gm-alpha");
          ("target_agent_id", `String "player-1");
          ("ability", `String "WIS");
          ("proposed_narrative", `String "Perception check");
          ("difficulty_score", `Int 10);
        ])
    |> expect_ok "resolve_judgment"
    |> parse_json "resolve_judgment"
  in
  expect_field_eq_string "resolve_judgment" judgment_json "caller_id" "gm-alpha";

  let _ =
    call player_ctx "masc_game_status_update"
      (`Assoc
        [
          ("agent_id", `String "player-1");
          ("frustration", `Float 23.0);
          ("sanity", `Float 77.5);
        ])
    |> expect_ok "status_update"
    |> parse_json "status_update"
  in

  let state_json =
    call gm_ctx "masc_game_state_get" (`Assoc [])
    |> expect_ok "state_get"
    |> parse_json "state_get"
  in
  let revision = state_json |> member "revision" |> to_int_option |> Option.value ~default:0 in
  if revision < 4 then
    fail
      (Printf.sprintf "state_get -> revision too low, expected >= 4, got %d"
         revision);

  print_endline "[game_harness] OK: policy + consistency + reality-anchor flow verified."
