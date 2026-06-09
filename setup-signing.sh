#!/usr/bin/env bash
set -euo pipefail

# Создаёт самоподписанный сертификат для подписи кода («Hopkey Dev») и доверяет
# ему в login-keychain. После этого build.sh подписывает .app этим сертификатом,
# а не ad-hoc — и разрешение Accessibility перестаёт слетать при пересборках
# (доверие TCC привязано к стабильной идентичности сертификата, а не к cdhash).
#
# Запускать ОДИН раз. Команды затрагивают Keychain, поэтому macOS попросит
# пароль от входа в систему (GUI-диалог) — это нормально.

CERT_NAME="Hopkey Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✅ Сертификат «${CERT_NAME}» уже существует — ничего делать не нужно."
    echo "   Пересоберите: make app   (или дождитесь пересборки в make watch)"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CONF="${TMP}/openssl.cnf"
cat > "${CONF}" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = Hopkey Dev
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

echo "==> Генерация ключа и самоподписанного сертификата…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
    -days 3650 -config "${CONF}" -extensions v3

echo "==> Упаковка в PKCS#12 (legacy-формат для совместимости с Apple security)…"
# OpenSSL 3 по умолчанию делает MAC по SHA-256 и AES-шифрование, которые
# `security import` не принимает («MAC verification failed»). -legacy + -macalg sha1
# дают старый формат (3DES/RC2 + SHA1 MAC), понятный Keychain.
# Пароль НЕ пустой: при пустом пароле OpenSSL и Apple по-разному считают MAC,
# что тоже даёт «MAC verification failed». Пароль временный, нужен только для p12.
P12_PASS="hopkeydev"
openssl pkcs12 -export -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -out "${TMP}/identity.p12" -passout "pass:${P12_PASS}" -name "${CERT_NAME}" \
    -legacy -macalg sha1

echo "==> Импорт в login-keychain (разрешаем codesign использовать ключ)…"
security import "${TMP}/identity.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "==> Доверие сертификату для подписи кода (потребуется пароль входа)…"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${TMP}/cert.pem"

echo ""
echo "✅ Готово. Сертификат «${CERT_NAME}» создан и доверен."
echo "   Дальше:"
echo "   1) make app                (пересобрать с новой подписью)"
echo "   2) Системные настройки → Конфиденциальность → Универсальный доступ:"
echo "      удалите старую запись Hopkey (–) и выдайте доступ заново."
echo "   После этого Accessibility больше не будет слетать при пересборках."
