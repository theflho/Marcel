FROM python:3.13-slim
WORKDIR /srv
# git: Marcel's own copy of his repository, where his code tools work (app/code_tools.py).
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY deploy/hermes-skills ./hermes-skills
RUN mkdir -p /data/files && chown -R nobody /data
USER nobody
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
