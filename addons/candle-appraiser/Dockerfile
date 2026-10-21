FROM python:3.12-slim
COPY protocol.py /protocol.py
WORKDIR /addon
CMD ["python3", "server.py", "--state", "/state"]
