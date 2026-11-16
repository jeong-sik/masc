### Fixed

- TUI: an image download that began before an explicit image retry no longer
  publishes its body over the retry's response when it finishes later, so a
  later view of the URL shows what the retry fetched instead of the older
  body. The same holds across TUIs sharing the image cache directory, and when
  two retries overlap the one that began last keeps the cache. The retry
  writes a new generation token beside the cached file and a download
  publishes only while the token it began with is still there; nothing waits
  on a lock, and a cancelled or killed download leaves nothing to clear. Each
  download still returns its own bytes, and a failed retry reports the same
  error as before (#47541, #PENDING).
