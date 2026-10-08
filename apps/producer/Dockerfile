FROM python:3.12-slim

RUN useradd --create-home --uid 1000 appuser
USER appuser
WORKDIR /home/appuser

COPY --chown=appuser requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser app.py .

EXPOSE 8080
CMD ["python", "app.py"]
