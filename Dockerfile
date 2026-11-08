# Imagen del microservicio de lista negra (Entrega 3 - Fargate)
# Se usa la imagen oficial de Python publicada en Amazon ECR Public para evitar
# el limite de descargas anonimas de Docker Hub dentro de CodeBuild.
FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY application.py config.py ./
COPY app/ ./app/

EXPOSE 5000

CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT} --workers 2 --access-logfile - application:application"]
