FROM python:3.12-slim
WORKDIR /addon
COPY figma-studio/ /addon/
USER 65534:65534
CMD ["python3", "server.py"]
