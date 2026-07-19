#!/bin/bash
# 02-bootstrap-step-ca.sh — initialize step-ca with the PKI material from
# 01-generate-pki.sh (or your own, brought into ./info — see README.md) and
# register PIMPtune as a JWK provisioner.
#
# Adapted from PIMPtune's own bootstrap.sh (github.com/griefersutherland/pimptune),
# generalized to not assume a pre-existing offline root CA.
set -euo pipefail

### Settings — override any of these via environment variables before running.

# Internal docker network hostname for step-ca — must match the service/alias
# name in docker-compose.yaml and PIMPTUNE_STEP_API_URL.
CA_HOST="${CA_HOST:-step-ca}"
CA_PORT="${CA_PORT:-9000}"

# Public hostname clients will reach pimptune at (the Cloudflare Tunnel
# Public Hostname you configure in the Zero Trust dashboard — see README.md).
# Set this once via PUBLIC_HOSTNAME (e.g. in .env) rather than the two
# CRL_URL/CRT_URL vars individually, unless you need CRL and CRT served from
# different hosts.
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-scep-dev.example.com}"

# Public URLs for CRL / issuing cert. These get baked into the certificate
# template, so they must match the public hostname above.
CRL_URL="${CRL_URL:-https://${PUBLIC_HOSTNAME}/crl}"
CRT_URL="${CRT_URL:-https://${PUBLIC_HOSTNAME}/crt}"

# Certificate expiry info for issued client certs
MIN_TLS_DUR="${MIN_TLS_DUR:-24h}"
MAX_TLS_DUR="${MAX_TLS_DUR:-720h}"
DEF_TLS_DUR="${DEF_TLS_DUR:-$MAX_TLS_DUR}"

PROVISIONER_NAME="${PROVISIONER_NAME:-pimptune}"

INFO_SRC="${INFO_SRC:-./info}"
STEP_DIR="${STEP_DIR:-./ca}"

ALL_FILES="root_ca.crt intermediate_ca.crt intermediate_ca.key intermediate_ca.txt scep_ra.crt scep_ra.key scep_ra.txt pimptune.jwk.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[.]${RESET} $*"; }
success() { echo -e "${GREEN}[+]${RESET} $*"; }
error()   { echo -e "${RED}[!] ERROR:${RESET} $*"; }

verify_key() {
    local label="$1" cert="$2" key="$3" password="$4"

    if ! openssl pkey -in "$key" -passin "pass:${password}" -noout 2>/dev/null; then
        if ! openssl ec -in "$key" -passin "pass:${password}" -noout 2>/dev/null; then
            error "Failed to decrypt key for ${label}"
            return 1
        fi
    fi

    CERT_PUBKEY=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)
    KEY_PUBKEY=$(openssl pkey -in "$key" -passin "pass:${password}" -pubout 2>/dev/null) || \
    KEY_PUBKEY=$(openssl ec -in "$key" -passin "pass:${password}" -pubout 2>/dev/null)

    if [[ "$CERT_PUBKEY" != "$KEY_PUBKEY" ]]; then
        error "Key does not match certificate for ${label}"
        return 1
    fi
    success "Verified key/certificate: ${label}"
}

verify_signer() {
    local label="$1" cert="$2" issuer="$3"
    local root="$INFO_SRC/root_ca.crt"
    local tmpchain
    tmpchain=$(mktemp)

    if [[ "$cert" == "$root" ]]; then
        openssl verify -CAfile "$root" "$root" > /dev/null 2>&1
    else
        cat "$issuer" > "$tmpchain"
        openssl verify -CAfile "$root" -untrusted "$tmpchain" "$cert" > /dev/null 2>&1
    fi

    local rc=$?
    rm -f "$tmpchain"

    if [[ $rc -ne 0 ]]; then
        error "Signature verification failed for ${label}"
        return 1
    fi
    success "Validated signature: ${label}"
}

while getopts "f" opt; do
  case $opt in
    f) rm -rf "$STEP_DIR" ;;
    \?) error "Invalid option: -$OPTARG" ;;
  esac
done

command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { error "jq is required"; exit 1; }

info "Verifying all required files"
if [[ -d "$STEP_DIR/config" ]]; then
    error "$STEP_DIR/config already exists. Use -f to remove $STEP_DIR and re-bootstrap."
    exit 1
fi

for f in $ALL_FILES; do
    if [[ ! -f "$INFO_SRC/$f" ]]; then
        error "Missing required file: $INFO_SRC/$f (run 01-generate-pki.sh first, or bring your own)"
        exit 1
    fi
done
success "All required files exist"
echo ""

info "Verifying secret key values"
# Password files have no trailing newline, so `read -r VAR < file` would hit
# EOF and return non-zero, aborting under `set -e`. Use `cat` instead.
CA_PASSWORD="$(cat "$INFO_SRC/intermediate_ca.txt")"
[[ -n "$CA_PASSWORD" ]] || { error "intermediate_ca.txt is empty"; exit 1; }
verify_key "Intermediate CA" "$INFO_SRC/intermediate_ca.crt" "$INFO_SRC/intermediate_ca.key" "$CA_PASSWORD"

RA_PASSWORD="$(cat "$INFO_SRC/scep_ra.txt")"
[[ -n "$RA_PASSWORD" ]] || { error "scep_ra.txt is empty"; exit 1; }
verify_key "SCEP RA" "$INFO_SRC/scep_ra.crt" "$INFO_SRC/scep_ra.key" "$RA_PASSWORD"

JWK_PASSWORD="$(cat "$INFO_SRC/pimptune.jwk.txt")"
[[ -n "$JWK_PASSWORD" ]] || { error "pimptune.jwk.txt is empty"; exit 1; }
success "All secret key values verified"
echo ""

info "Verifying certificate chain"
verify_signer "Root CA (Self-Signed)" "$INFO_SRC/root_ca.crt" "$INFO_SRC/root_ca.crt"
verify_signer "Intermediate CA" "$INFO_SRC/intermediate_ca.crt" "$INFO_SRC/root_ca.crt"
verify_signer "SCEP RA" "$INFO_SRC/scep_ra.crt" "$INFO_SRC/intermediate_ca.crt"
success "All certificates verified"
echo ""

info "Creating and initializing step-ca"
mkdir -p "$STEP_DIR/certs" "$STEP_DIR/secrets" "$STEP_DIR/config" "$STEP_DIR/db" "$STEP_DIR/templates/certs"

echo -n "$CA_PASSWORD"  > "$STEP_DIR/secrets/password"
chmod 600 "$STEP_DIR/secrets/password"
echo -n "$RA_PASSWORD"  > "$STEP_DIR/secrets/scep_ra.txt"
chmod 600 "$STEP_DIR/secrets/scep_ra.txt"
echo -n "$JWK_PASSWORD" > "$STEP_DIR/secrets/pimptune.jwk.txt"
chmod 600 "$STEP_DIR/secrets/pimptune.jwk.txt"

INIT_OUTPUT=$(docker run --rm \
    -v "$(pwd)/$STEP_DIR:/home/step" \
    smallstep/step-ca \
    step ca init \
        --name "temporary" \
        --dns "$CA_HOST" \
        --address ":$CA_PORT" \
        --provisioner "$PROVISIONER_NAME" \
        --provisioner-password-file /home/step/secrets/pimptune.jwk.txt \
        --password-file /home/step/secrets/password \
    2>&1)
if [[ $? -ne 0 ]]; then
    error "step ca init failed:"
    echo "$INIT_OUTPUT"
    exit 1
fi
success "Completed step-ca initialization"
echo ""

info "Installing PKI artifacts and creating configuration"
cp "$INFO_SRC/root_ca.crt"         "$STEP_DIR/certs/root_ca.crt"
cp "$INFO_SRC/intermediate_ca.crt" "$STEP_DIR/certs/intermediate_ca.crt"
cp "$INFO_SRC/intermediate_ca.key" "$STEP_DIR/secrets/intermediate_ca_key"
cp "$INFO_SRC/scep_ra.crt"         "$STEP_DIR/certs/scep_ra.crt"
cp "$INFO_SRC/scep_ra.key"         "$STEP_DIR/secrets/scep_ra_key"
{ cat "$INFO_SRC/intermediate_ca.crt"; echo; cat "$INFO_SRC/root_ca.crt"; } | sed '/^$/d' > "$STEP_DIR/certs/full_chain.pem"
chmod 600 "$STEP_DIR/secrets/intermediate_ca_key"

# DER copies for uploading to Intune (Trusted certificate profiles want .cer).
# 01-generate-pki.sh already produces these; if you brought your own PKI
# instead, generate them here so they're not missing.
[[ -f "$INFO_SRC/root_ca.cer" ]] || openssl x509 -in "$INFO_SRC/root_ca.crt" -outform der -out "$INFO_SRC/root_ca.cer"
[[ -f "$INFO_SRC/intermediate_ca.cer" ]] || openssl x509 -in "$INFO_SRC/intermediate_ca.crt" -outform der -out "$INFO_SRC/intermediate_ca.cer"
cp "$INFO_SRC/root_ca.cer"         "$STEP_DIR/certs/root_ca.cer"
cp "$INFO_SRC/intermediate_ca.cer" "$STEP_DIR/certs/intermediate_ca.cer"
chmod 600 "$STEP_DIR/secrets/scep_ra_key"

ENCRYPTED_JWK=$(jq -r ".authority.provisioners[] | select(.name == \"${PROVISIONER_NAME}\") | .encryptedKey" "$STEP_DIR/config/ca.json")
if [[ -z "$ENCRYPTED_JWK" || "$ENCRYPTED_JWK" == "null" ]]; then
    error "Could not extract encryptedKey for $PROVISIONER_NAME provisioner from ca.json"
    exit 1
fi
echo -n "$ENCRYPTED_JWK" > "$STEP_DIR/secrets/pimptune.jwk"
chmod 600 "$STEP_DIR/secrets/pimptune.jwk"

# The auto-generated root key has no place here — we brought our own root.
rm -f "$STEP_DIR/secrets/root_ca_key"

FINGERPRINT=$(docker run --rm \
    -v "$(pwd)/$STEP_DIR:/home/step" \
    smallstep/step-ca \
    step certificate fingerprint /home/step/certs/root_ca.crt)
success "Root CA fingerprint: $FINGERPRINT"

cat > "$STEP_DIR/config/defaults.json" <<EOF
{
    "ca-url": "https://${CA_HOST}:${CA_PORT}",
    "ca-config": "/home/step/config/ca.json",
    "fingerprint": "${FINGERPRINT}",
    "root": "/home/step/certs/root_ca.crt"
}
EOF

jq --arg crlURL "$CRL_URL" '
    .crl = {
        "enabled": true,
        "generateOnRevoke": true,
        "idpURL": $crlURL,
        "cacheDuration": "24h",
        "renewPeriod": "16h"
    }
' "$STEP_DIR/config/ca.json" > "$STEP_DIR/config/ca.json.tmp" \
    && mv "$STEP_DIR/config/ca.json.tmp" "$STEP_DIR/config/ca.json" \
    || { error "Failed to patch CRL config into ca.json"; exit 1; }

jq --arg name "$PROVISIONER_NAME" \
   --arg minDur "$MIN_TLS_DUR" \
   --arg maxDur "$MAX_TLS_DUR" \
   --arg defDur "$DEF_TLS_DUR" \
   '(.authority.provisioners[] | select(.name == $name)).claims = {
        "minTLSCertDuration": $minDur,
        "maxTLSCertDuration": $maxDur,
        "defaultTLSCertDuration": $defDur,
        "disableRenewal": false,
        "allowRenewalAfterExpiry": false,
        "disableSmallstepExtensions": false
    }' "$STEP_DIR/config/ca.json" > "$STEP_DIR/config/ca.json.tmp" \
    && mv "$STEP_DIR/config/ca.json.tmp" "$STEP_DIR/config/ca.json" \
    || { error "Failed to patch provisioner claims into ca.json"; exit 1; }

jq \
    --arg tplFile "templates/certs/pimptune.tpl" \
    --arg crlURL "$CRL_URL" \
    --arg crtURL "$CRT_URL" \
    --arg name "$PROVISIONER_NAME" \
    '(.authority.provisioners[] | select(.name == $name)).options = {
        "x509": {
            "templateFile": $tplFile,
            "templateData": {
                "CRLURL": $crlURL,
                "CRTURL": $crtURL
            }
        }
    }
' "$STEP_DIR/config/ca.json" > "$STEP_DIR/config/ca.json.tmp" \
    && mv "$STEP_DIR/config/ca.json.tmp" "$STEP_DIR/config/ca.json" \
    || { error "Failed to patch provisioner template into ca.json"; exit 1; }

cat > "$STEP_DIR/templates/certs/pimptune.tpl" <<EOF
{
    "subject": {{ toJson .Insecure.CR.Subject }},
    "extensions": {{ toJson .Insecure.CR.Extensions }},
    "basicConstraints": { "isCA": false },
    "crlDistributionPoints": ["${CRL_URL}"],
    "issuingCertificateURL": ["${CRT_URL}"]
}
EOF

# No chown here: docker-compose.yaml runs both containers with
# `user: "${PUID}:${PGID}"` set to your own uid/gid (see quickstart.sh /
# .env.example), so the files stay owned by you and no root/sudo step is
# needed anywhere in this pipeline.

success "Files installed, configuration created, CRLs enabled"
echo ""

echo -e "${BOLD}${GREEN}####################################${RESET}"
echo -e "${BOLD}${GREEN}#   step-ca bootstrap complete!   #${RESET}"
echo -e "${BOLD}${GREEN}####################################${RESET}"
echo ""
info "Next: fill in .env (Intune credentials + CLOUDFLARE_TUNNEL_TOKEN) and run 'docker compose up -d'."
