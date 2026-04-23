FROM python:3.10-slim

WORKDIR /app

# Copy only requirements first (better caching)
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# Then copy app
COPY app.py .

EXPOSE 8080

CMD ["python", "app.py"]