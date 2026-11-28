; Media_format: DOC, XLS, PPT, HWP and encrypted OOXML from Compound File streams

(test
 (name test_media_format_compound)
 (modules test_media_format_compound)
 (deps (glob_files fixtures/media_format/*.cfb))
 (libraries alcotest masc.media_format))
