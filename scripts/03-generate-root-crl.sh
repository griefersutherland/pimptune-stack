#!/bin/bash
# 03-generate-root-crl.sh — generate/renew the root CA's own CRL.
#
# ############################################################################
# NON-STANDARD: root CAs conventionally do NOT publish a CRL (checking a
# root's CRL is circular — you'd need to already trust the root to trust the
# signature on its own revocation list). This exists to test a theory that a
# published root CRL affects which certificate store an MDM-pushed root cert
# lands in on Windows; it is not required for the SCEP/step-ca chain to work
# — pimptune already serves the operationally meaningful CRL (the
# intermediate's, covering issued client certs) at /crl.
#
# This CRL is a static file: nothing auto-regenerates it. It expires
# (CRL_DAYS below) and must be re-run before then, or clients that check
# root-CRL freshness will start treating it as stale. Put this on a cron job
# if you keep this around.
# ############################################################################
set -euo pipefail

INFO_DIR="${INFO_DIR:-./info}"
OUT_DIR="${OUT_DIR:-./rootcrl}"
CRL_DAYS="${CRL_DAYS:-30}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[.]${RESET} $*"; }
success() { echo -e "${GREEN}[+]${RESET} $*"; }
error()   { echo -e "${RED}[!] ERROR:${RESET} $*"; }

command -v openssl >/dev/null 2>&1 || { error "openssl is required"; exit 1; }

for f in root_ca.crt root_ca.key; do
    if [[ ! -f "$INFO_DIR/$f" ]]; then
        error "Missing $INFO_DIR/$f — run 01-generate-pki.sh first"
        exit 1
    fi
done

mkdir -p "$OUT_DIR"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

touch "$WORKDIR/index.txt"
echo "1000" > "$WORKDIR/crlnumber"
cat > "$WORKDIR/ca.cnf" <<EOF
[ ca ]
default_ca = root_ca

[ root_ca ]
database = $WORKDIR/index.txt
crlnumber = $WORKDIR/crlnumber
default_crl_days = $CRL_DAYS
default_md = sha256
EOF

info "Generating root CRL (valid $CRL_DAYS days)"
openssl ca -gencrl \
    -config "$WORKDIR/ca.cnf" \
    -keyfile "$INFO_DIR/root_ca.key" \
    -cert "$INFO_DIR/root_ca.crt" \
    -out "$OUT_DIR/root_ca.crl"

openssl crl -in "$OUT_DIR/root_ca.crl" -CAfile "$INFO_DIR/root_ca.crt" -noout
success "Root CRL written to $OUT_DIR/root_ca.crl and verified against root_ca.crt"
openssl crl -in "$OUT_DIR/root_ca.crl" -noout -text | grep -E "Last Update|Next Update"
