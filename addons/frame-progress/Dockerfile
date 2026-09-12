FROM python:3.12-slim
WORKDIR /addon
COPY protocol.py /protocol.py
COPY frame-progress/server.py /addon/server.py
USER 65534:65534
CMD ["python3", "server.py"]
