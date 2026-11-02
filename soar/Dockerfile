FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
USER nobody
EXPOSE 8080
# one worker + threads so the Prometheus counters are not split over processes
CMD ["gunicorn", "-w", "1", "--threads", "4", "-b", "0.0.0.0:8080", "app:app"]
