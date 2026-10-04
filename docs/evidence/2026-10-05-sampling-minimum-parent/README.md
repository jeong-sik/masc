# Sampling minimum parent integration

Integrate #40960 at9c0485ac94fe542c519c2450e047e75d27026406, preserving its protected canonical-read failure and recovery tests. One additive worker-test conflict retains both child reply-minimum tests and the new parent canonical-read regression. The create API precondition comment now appears immediately before its declaration, addressing #41197 comment4178543575.

Focused OCaml5.5.1 repository-wrapper worker build passes (75789 exit0). Actual full worker executable passes31tests in7.778s (70155 exit0), including both reply-minimum boundaries and canonical corruption/budget/classification failures. Test environment matches the parent run: empty MASC_BASE_PATH/ZAI_API_KEY/TYPESAFEAI_API_KEY, sandbox preflight and Docker playground skipped. Product behavior added by this child remains unchanged; the parent supplies the read fix. No fullsuite/liveprovider/CI/release claim. Raw logs are preserved.
