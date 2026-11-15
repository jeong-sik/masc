### Fixed

- A Discord message that mentions the bot reaches the Keeper bound to the
  channel with that mention written as the Keeper's name, on the triggered
  and the ambient lane, instead of the bot's Discord display name. Decoding
  keeps the wire text, the structured mentions and the bot user id; mentions
  are named only after the channel binding is read, by the same
  `Connector_self_mention` rule as Slack. Other people keep their Discord
  names, and without a bot user id every mention renders by name as before
  (#51900, #PENDING).
