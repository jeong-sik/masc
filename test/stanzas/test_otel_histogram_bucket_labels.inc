; Histogram bucket [le] labels must name the bound the store compared against.

(test
 (name test_otel_histogram_bucket_labels)
 (modules test_otel_histogram_bucket_labels)
 (libraries alcotest masc.otel_metric_store))
