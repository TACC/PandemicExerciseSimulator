FROM python:3.10-slim-bookworm

RUN pip install "poetry==1.8.3"

WORKDIR /PES

COPY pyproject.toml poetry.lock ./
RUN poetry config virtualenvs.create false && \
    poetry install --no-root



ADD ./data /PES/data
ADD ./src /PES/src
ADD ./test /PES/test

