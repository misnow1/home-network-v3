FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postfix \
    libsasl2-modules \
    ca-certificates \
    gettext-base \
  && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 25 587

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
