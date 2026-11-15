### Internal

- The TUI reads the Keeper chat operation state word with
  `Keeper_chat_operation.State_name.of_wire` instead of its own literals: the
  queue peer view (the list tag and each operation), the exact operation read,
  the stream acceptance decoder and the temporal continuity measurement decoder.
  A word the server does not write, including another case of the same word, is
  still refused, and the TUI's `acceptance_state` is now the same type as
  `State_name.t` (#52273, #PENDING).
