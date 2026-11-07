FROM python:3.12-slim
COPY protocol.py /protocol.py
COPY tinker-trainer/server.py /addon/server.py
WORKDIR /addon
CMD ["python3", "server.py", "--state", "/state"]
