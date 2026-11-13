### Documentation

- The Librarian lifecycle RFC now states what the code does after a timeout: a request that timed out after it was sent moves on to the next slot, and the continuity pass reads less on the next signal only when a named input-size refusal is in the walk. The refusal table lists `Timeout`, `Invalid_request` and `Refusal_body_not_received` as waits, and `walk_shows_size` is described as a hint that does not narrow reads (#PENDING).
