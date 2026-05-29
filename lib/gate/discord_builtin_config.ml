(* RFC-0203 Phase 2 — env-driven config for the in-process Discord
   gateway. See .mli for contract. *)

let builtin_enabled () =
  Env_config_core.get_bool ~default:false "MASC_DISCORD_BUILTIN"

type policy_parse_error =
  | Empty
  | Unknown_value of string
  | User_only_missing_id

let pp_policy_parse_error fmt = function
  | Empty -> Format.pp_print_string fmt "policy string is empty"
  | Unknown_value v ->
    Format.fprintf fmt
      "unknown policy %S (expected mention_only | user_only:<id> | all)"
      v
  | User_only_missing_id ->
    Format.pp_print_string fmt
      "user_only requires an id after the colon (e.g. user_only:1234567890)"

(* Discord snowflakes are decimal digit strings, but we deliberately
   don't validate the shape — accepting arbitrary non-empty payloads
   keeps the parser focused on its single job (shape into the typed
   variant) and avoids smuggling identifier policy into the parser.
   Identity policy belongs at the dispatch boundary, not here. *)
let parse_policy raw : (Discord_gateway_client.trigger_policy, policy_parse_error) result =
  let s = String.trim raw in
  if String.equal s "" then Error Empty
  else
    match s with
    | "mention_only" -> Ok Discord_gateway_client.Mention_only
    | "all" -> Ok Discord_gateway_client.All
    | other ->
      let prefix = "user_only:" in
      let plen = String.length prefix in
      if String.length other > plen
         && String.equal (String.sub other 0 plen) prefix
      then
        let id = String.trim (String.sub other plen (String.length other - plen)) in
        if String.equal id "" then Error User_only_missing_id
        else Ok (Discord_gateway_client.User_only id)
      else if String.equal other "user_only" || String.equal other "user_only:"
      then Error User_only_missing_id
      else Error (Unknown_value other)

let trigger_policy () =
  match Sys.getenv_opt "MASC_DISCORD_TRIGGER_POLICY" |> Env_config_core.trim_opt with
  | None -> Discord_gateway_client.Mention_only
  | Some raw ->
    (match parse_policy raw with
     | Ok p -> p
     | Error _ -> Discord_gateway_client.Mention_only)

let bot_token () =
  match Sys.getenv_opt "DISCORD_BOT_TOKEN" |> Env_config_core.trim_opt with
  | Some t when t <> "" -> Some t
  | _ -> None

let intents : Discord_gateway_client.intent list =
  [ Discord_gateway_client.Guilds
  ; Discord_gateway_client.Guild_messages
  ; Discord_gateway_client.Message_content
  ; Discord_gateway_client.Guild_message_reactions
  ; Discord_gateway_client.Direct_messages
  ; Discord_gateway_client.Direct_message_reactions
  ]
