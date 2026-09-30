FROM python:3.12-slim
WORKDIR /addon
COPY protocol.py /protocol.py
COPY fusion-report/server.py /addon/server.py
COPY fusion-report/lane.toml /addon/lane.toml
USER 65534:65534
CMD ["python3", "server.py"]
