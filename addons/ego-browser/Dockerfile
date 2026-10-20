FROM python:3.12-slim
WORKDIR /addon
COPY protocol.py /protocol.py
COPY ego-browser/server.py /addon/server.py
COPY ego-browser/skills/ego-native/scripts/contract.py /addon/skills/ego-native/scripts/contract.py
USER 65534:65534
CMD ["python3", "server.py"]
