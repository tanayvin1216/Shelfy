# Python + node in one image. The client bundle is built by vite, so a plain
# Python buildpack is not enough — that is the deploy failure this avoids.
#
# trixie (Debian 13), NOT bookworm: bookworm ships python 3.11 and both jaclang
# and byllm require >= 3.12. A bookworm base fails at `pip install` with a
# Requires-Python error after several minutes of build time.
FROM node:22-trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Fail loudly here rather than three minutes later inside pip.
RUN python3 --version \
 && python3 -c "import sys; assert sys.version_info >= (3,12), 'need python>=3.12, got %s' % sys.version"

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY jac.toml ./
RUN jac install

COPY . .

ENV PORT=8000
EXPOSE 8000

# `jac start` exits when stdin closes — `< /dev/null` is mandatory, not cosmetic.
CMD ["sh", "-c", "jac start main.jac --port ${PORT} < /dev/null"]
