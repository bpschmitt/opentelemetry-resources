FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py telemetry.py scenarios.py ./
COPY generated ./generated
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "app.py"]
CMD ["--mode", "demo"]
