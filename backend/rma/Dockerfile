# Robot de lecture du planning RMA : navigateur invisible (Chromium) qui lit les missions,
# en lecture seule. Image officielle Playwright : navigateur et dépendances déjà installés.
FROM mcr.microsoft.com/playwright/python:v1.47.0-jammy
WORKDIR /srv
RUN pip install --no-cache-dir playwright==1.47.0 httpx==0.28.1
COPY planning.py .
RUN mkdir -p /data && chown -R pwuser /data
USER pwuser
CMD ["python", "planning.py"]
