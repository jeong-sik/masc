### Internal

- The rule that the bot's own mention names the Keeper the channel is bound
  to now lives in `Connector_self_mention` (`Bot_user_id_unknown` or
  `Bound_keeper { bot_user_id; keeper_name }`, decided by id equality), so
  every connector renders that mention by the same rule. Slack's
  `Slack_user_directory.self` is that type; Slack renders mentions as before
  (#51900, #PENDING).
