### Fixed

- An Antigravity turn that ends on a refused action reports the CLI's stderr
  from its first words. The refusal detail reused the 200-byte tail of the
  empty-success rejection, which began the closing sentence at "for, so it
  was auto-denied" and dropped what was refused. A refusal now carries the
  retained stderr whole when it fits 1536 bytes, and otherwise its first 512
  and last 1024 bytes around a count of the omitted bytes, masked before the
  cut (#50291, #PENDING).
