(test
 (name test_discord_wss_writer)
 (modules test_discord_wss_writer)
 (libraries
  alcotest
  masc.gate
  masc.masc_log
  websocket
  eio
  mirage-crypto-rng.unix))
