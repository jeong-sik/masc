(test
 (name test_keeper_portrait)
 (modules test_keeper_portrait)
 (libraries alcotest masc_keeper_portrait))

; Writes a PNG sheet of portraits so a person can look at them:
;   dune exec test/keeper_portrait_preview.exe -- --out portraits.png NAME...
;   dune exec test/keeper_portrait_preview.exe -- --keepers-dir <base>/.masc/config/keepers
(executable
 (name keeper_portrait_preview)
 (modules keeper_portrait_preview)
 (libraries masc_keeper_portrait masc_compression))
