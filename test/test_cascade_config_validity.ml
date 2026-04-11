(** Static validity check for config/cascade.json.

    Guards every profile's model string list against typos, unknown
    provider names, and unsupported aliases by running them through
    the same parser the server uses at runtime
    ({!Llm_provider.Cascade_config.parse_model_strings}).

    Motivation: 2026-04-11 incident adjacent — masc-mcp#6475 introduced a
    new [glm-coding:*] cascade head, and the only way to know if OAS
    actually knew that provider name was to read the pinned SHA by hand.
    A unit test that parses the live cascade.json turns "the pinned OAS
    understands every provider name in our cascade" from a manual audit
    into a build-time guarantee.

    The path to cascade.json is injected via the [MASC_CASCADE_JSON_PATH]
    env var set in the dune stanza — no hardcoded path in the test body.
    Profile keys follow cascade.json convention: each entry is named
    [<profile>_models] in the JSON. *)

open Alcotest

let cascade_path () =
  match Sys.getenv_opt "MASC_CASCADE_JSON_PATH" with
  | Some p when String.trim p <> "" -> p
  | _ ->
    failwith
      "MASC_CASCADE_JSON_PATH not set; dune stanza must inject it \
       before running the test"

(** Profile names discovered from cascade.json. Kept as a function so
    the test can always reflect the current on-disk file rather than a
    frozen list that drifts the next time someone adds a profile. *)
let discover_profiles path : string list =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
  in
  let json = Yojson.Safe.from_string content in
  match json with
  | `Assoc fields ->
    fields
    |> List.filter_map (fun (k, v) ->
           match v with
           | `List _ ->
             let suffix = "_models" in
             let k_len = String.length k in
             let s_len = String.length suffix in
             if k_len > s_len
                && String.sub k (k_len - s_len) s_len = suffix
             then Some (String.sub k 0 (k_len - s_len))
             else None
           | _ -> None)
  | _ -> []

let load_profile_strings ~path ~profile : string list =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        let buf = Bytes.create len in
        really_input ic buf 0 len;
        Bytes.to_string buf)
  in
  let json = Yojson.Safe.from_string content in
  let open Yojson.Safe.Util in
  let key = profile ^ "_models" in
  match json |> member key with
  | `List items ->
    List.filter_map
      (function `String s -> Some (String.trim s) | _ -> None)
      items
  | _ -> []

let test_profile_parses_non_empty profile () =
  let path = cascade_path () in
  let strings = load_profile_strings ~path ~profile in
  check bool
    (Printf.sprintf "%s has entries" profile)
    true
    (strings <> []);
  let parsed =
    Llm_provider.Cascade_config.parse_model_strings strings
  in
  check int
    (Printf.sprintf "%s parses all model strings" profile)
    (List.length strings)
    (List.length parsed);
  List.iter
    (fun (cfg : Llm_provider.Provider_config.t) ->
      check bool
        (Printf.sprintf "%s: %s has non-empty model_id" profile cfg.model_id)
        true
        (String.trim cfg.model_id <> ""))
    parsed

let () =
  let path = cascade_path () in
  let profiles = discover_profiles path in
  let profile_cases =
    List.map
      (fun p ->
        test_case
          (Printf.sprintf "%s parses cleanly" p)
          `Quick
          (test_profile_parses_non_empty p))
      profiles
  in
  run "Cascade config validity" [ "profiles", profile_cases ]
