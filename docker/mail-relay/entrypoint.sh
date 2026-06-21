#!/usr/bin/env bash
# Render Postfix maps from templates + .env, then run postfix in foreground.
set -euo pipefail

: "${MAIL_RELAY_HOSTNAME:?Set MAIL_RELAY_HOSTNAME in .env}"
: "${MAIL_RELAY_DOMAIN:?Set MAIL_RELAY_DOMAIN in .env}"
: "${GMAIL_USER:?Set GMAIL_USER in .env}"
: "${GMAIL_APP_PASSWORD:?Set GMAIL_APP_PASSWORD in .env}"
: "${MAIL_DEFAULT_RECIPIENT:?Set MAIL_DEFAULT_RECIPIENT in .env}"

MAIL_RELAY_MYNETWORKS="${MAIL_RELAY_MYNETWORKS:-127.0.0.0/8,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12}"
TLS_CERT_DIR="/etc/letsencrypt/live/${MAIL_RELAY_HOSTNAME}"

export MAIL_RELAY_HOSTNAME MAIL_RELAY_DOMAIN MAIL_RELAY_MYNETWORKS
export MAIL_DEFAULT_RECIPIENT TLS_CERT_DIR

template_dir="/etc/postfix/templates"

envsubst < "${template_dir}/main.cf.template" > /etc/postfix/main.cf
envsubst < "${template_dir}/master.cf.template" > /etc/postfix/master.cf
cp "${template_dir}/sender_canonical_regexp" /etc/postfix/sender_canonical_regexp
envsubst < "${template_dir}/virtual_aliases_regexp.template" > /etc/postfix/virtual_aliases_regexp

printf '[smtp.gmail.com]:587\t%s:%s\n' "${GMAIL_USER}" "${GMAIL_APP_PASSWORD}" \
  > /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd

postmap /etc/postfix/sasl_passwd
# regexp: maps are read directly — no postmap for virtual_aliases_regexp

exec postfix start-fg
