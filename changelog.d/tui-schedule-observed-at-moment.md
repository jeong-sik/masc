### Changed

- A schedule page's observation time is read once when the page is
  decoded, and a page whose `generated_at` is not an RFC 3339 time is
  refused as a read failure. The queue panel's schedule item reads `Name
  observed at 12:05` in the local zone instead of the server's ISO text,
  and Keeper Story and the chat schedule block no longer fall back to the
  server's text (RFC tui-one-screen-grammar 6.1).
