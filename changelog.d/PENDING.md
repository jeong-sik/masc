### Fixed

- A Slack mention of the bot itself reaches the Keeper as `@<keeper name>`
  for the Keeper the channel is bound to, on both the triggered and ambient
  lanes. It used to arrive as the bot's Slack display name, and a Keeper that
  did not know that name as its own read the message as meant for another bot
  and refused the turn. Without a bot user id from `auth.test` every mention
  renders as before (#PENDING).
