FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir prometheus_client requests
COPY app.py /app/app.py
EXPOSE 8000
CMD ["python", "app.py"]
