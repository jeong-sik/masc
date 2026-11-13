### Fixed

- A board post or comment sent to `masc_board_post` or `masc_board_comment` in `body` now reaches the SSE notification, the activity record and the mention with its text. These three read the request's `content` by themselves, so a `body` write was announced with an empty text and its mention notified nobody; they now take the text from the stored post or comment (#50640).
