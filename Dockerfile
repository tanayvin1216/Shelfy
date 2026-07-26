# Python + node in one image. The client bundle is built by vite, so a plain
# Python buildpack is not enough — that is the deploy failure this avoids.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY jac.toml ./
RUN jac install

COPY . .

# Build the client bundle now so a cold start does not pay for it.
RUN jac start main.jac --faux > /dev/null 2>&1 || true

ENV PORT=8000
EXPOSE 8000

# `jac start` exits when stdin closes — `< /dev/null` is mandatory, not cosmetic.
CMD ["sh", "-c", "jac start main.jac --port ${PORT} < /dev/null"]
