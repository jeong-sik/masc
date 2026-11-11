; Decoded lines of append-only row stores kept between reads: only appended
; bytes are decoded, and what is kept stays within a byte budget.

(test
 (name test_keeper_decoded_rows)
 (modules test_keeper_decoded_rows)
 (libraries masc_test_deps))
