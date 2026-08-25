(** Env_config_discord — Discord connector env accessor (RFC-0371 B8).

    Centralizes the [DISCORD_BOT_TOKEN] read at the config boundary. Before
    this module, four call sites each held their own [Sys.getenv_opt] +
    trim/blank check (the keeper stream route, the in-process tool runtime,
    the channel gate state, and the in-process gateway) — four copies of one
    credential materialization whose trim semantics could drift apart.
    Mirrors {!Env_config_slack.bot_token_opt}. *)

open Env_config_core

let bot_token_opt () = Sys.getenv_opt "DISCORD_BOT_TOKEN" |> trim_opt
