# Context: page + WHOOP backend + per-user training, in one small Python server.
FROM python:3.14-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOST=0.0.0.0 PORT=8000
WORKDIR /app

COPY ml/requirements.txt ml/requirements.txt
RUN pip install --no-cache-dir -r ml/requirements.txt

COPY serve.py ./
COPY ml/train.py ml/
COPY web web

RUN useradd --create-home app
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz')"
CMD ["python", "serve.py"]
