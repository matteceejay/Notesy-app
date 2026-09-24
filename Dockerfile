# ---- Stage 1: build the TypeScript bundle ----
FROM node:20-alpine AS frontend
WORKDIR /build
COPY package.json ./
RUN npm install
COPY tsconfig.json ./
COPY apps/notes/static_src ./apps/notes/static_src
RUN npm run typecheck && npm run build     # outputs static/js/*.js

# ---- Stage 2: Python runtime (no Node) ----
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app

RUN useradd --create-home --uid 1000 app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=app:app . .
COPY --from=frontend --chown=app:app /build/static/js ./static/js

# Collect static files into STATIC_ROOT for WhiteNoise
RUN DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput \
    && chown -R app:app /app

USER app
EXPOSE 8000
CMD ["gunicorn", "notesy.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]