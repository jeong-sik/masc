### Internal

- The Keeper chat operation state word (`Queued`, `Running`, `Succeeded`,
  `Failed`, `Cancelled`) is written by `Keeper_chat_operation.State_name.to_wire`,
  whose inverse `of_wire` refuses any other text. The operation object, the
  queued operation list and the stream's `KEEPER_CHAT_OPERATION_ACCEPTED` event
  now write the word with `to_wire` instead of their own literals. The words on
  the wire do not change (#52273, #PENDING).
