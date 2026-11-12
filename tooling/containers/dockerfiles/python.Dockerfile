# Python service: dependencies installed into a venv in the build stage, copied into a clean runtime; UID 10001.
# Both stages use the same base tag: the venv links to that exact interpreter.
# CHANGE: base tag in both FROM lines
FROM python:3.14.8-slim-trixie AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY requirements.txt ./
# Add --require-hashes once requirements.txt is hash-locked (pip-compile --generate-hashes).
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.14.8-slim-trixie AS runtime
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
# CHANGE: application package
COPY app/ ./app/
USER 10001:10001
# CHANGE: listen port
EXPOSE 8000
# CHANGE: production server command (for example gunicorn or uvicorn with its bind address)
CMD ["python", "-m", "app"]
