# Quiz capture repair: CI at e716f181

- Test run [36657267038](https://github.com/jeong-sik/masc/actions/runs/36657267038) completed successfully at `e716f181773b6f61925f43771283a000c992e26a`: 4/4 selected suites passed. The Quiz package alias ran 27 Python stdio cases; native sources, composition and declaration ran 9, 7 and 6 cases respectively. Retained full suite-runner log names each result.
- Image run [36657271661](https://github.com/jeong-sik/masc/actions/runs/36657271661) completed successfully at the same commit. Its package job ran all 75 Python Add-on cases, including the loopback WebLayer case that local permission restrictions prevented. All 16 package/architecture image jobs passed; Quiz questions and grader each built for amd64 and arm64.

These are CI fixtures and image builds. They do not prove installed worker execution, live Keeper collaboration, live scoring or deployment. Native host tests use existing worker transport fixtures; they are distinct from real package Python stdio tests and container builds. The later snapshot guard regression changes only a test, preserves product source hashes, and has its own local positive/mutation evidence. It was not part of this e716 run.

Downloaded image receipts and archive checks are enumerated in `archive-verification.json`. Only those entries were independently checked against their full downloaded archive, OCI revision, architecture and manifest hash; the other builds are reported from completed CI jobs. No container was run.
