; Media_format: the document format comes from package structure, not a name

(test
 (name test_media_format)
 (modules test_media_format)
 (deps (glob_files fixtures/media_format/*.xml) (glob_files fixtures/media_format/*.zip))
 (libraries alcotest masc.media_format zipc))
