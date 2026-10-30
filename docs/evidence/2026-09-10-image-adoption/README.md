# Actual Keeper image adoption

The isolated server on port 18937 was gracefully replaced after its prior operation was terminal and native approvals were empty. Its existing base path, conversation and playground were retained. CI candidate 17b9 was downloaded from run 34410416257, artifact 10127175896; all three executable hashes matched its manifest. Health reported the same binary commit and main executable SHA256.

A Keeper message caused the new image-specific container to appear while the old general-image container remained running. Independent Docker inspect identified the requested creative image; a read-only Python probe confirmed ReportLab, CairoSVG, Nanum and Poppler availability. PyMuPDF and pypdf were absent. The operator corrected an earlier inaccurate PyMuPDF-availability instruction through a queued message.

The JSON contains selected container fields and measured artifact identity; environment variables and credentials are excluded. This proves actual image selection and available tools, not PDF quality, task completion, production deployment, or mutable-tag refresh.
