#!/bin/bash
# 01-generate-pki.sh — generate a throwaway root CA, intermediate CA, and SCEP
# RA certificate for a PIMPtune + step-ca proof-of-concept.
#
# ############################################################################
# THIS IS FOR A POC / DEMO ONLY.
#
# The root private key is generated and left on disk unencrypted-at-rest
# (protected only by filesystem permissions). For any real deployment, the
# root CA key should be generated and stored offline (see README.md), and
# only the intermediate should ever touch a networked machine.
# ############################################################################
set -euo pipefail

INFO_DIR="${INFO_DIR:-./info}"
ORG_NAME="${ORG_NAME:-PIMPtune POC}"
ROOT_CN="${ROOT_CN:-${ORG_NAME} Root CA}"
INT_CN="${INT_CN:-${ORG_NAME} Issuing CA}"
RA_CN="${RA_CN:-${ORG_NAME} SCEP RA}"
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-scep-dev.example.com}"

# step only accepts h/m/s-scale duration units (no "y"), so these are in hours.
# 8760h/year ignores leap years — close enough for cert validity, same
# approximation everyone else in this space uses.
ROOT_NOT_AFTER="${ROOT_NOT_AFTER:-131400h}"  # 15 years
INT_NOT_AFTER="${INT_NOT_AFTER:-43800h}"     # 5 years

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[.]${RESET} $*"; }
success() { echo -e "${GREEN}[+]${RESET} $*"; }
error()   { echo -e "${RED}[!] ERROR:${RESET} $*"; }

command -v step >/dev/null 2>&1 || { error "step CLI is required: https://smallstep.com/docs/step-cli/installation"; exit 1; }
command -v openssl >/dev/null 2>&1 || { error "openssl is required"; exit 1; }

if [[ -f "$INFO_DIR/root_ca.crt" ]]; then
    error "$INFO_DIR already contains PKI material. Remove it first if you want to regenerate."
    exit 1
fi

mkdir -p "$INFO_DIR"

info "Generating random passwords for intermediate CA, RA, and JWK provisioner"
CA_PASSWORD=$(openssl rand -base64 24)
RA_PASSWORD=$(openssl rand -base64 24)
JWK_PASSWORD=$(openssl rand -base64 24)

echo -n "$CA_PASSWORD"  > "$INFO_DIR/intermediate_ca.txt"
echo -n "$RA_PASSWORD"  > "$INFO_DIR/scep_ra.txt"
echo -n "$JWK_PASSWORD" > "$INFO_DIR/pimptune.jwk.txt"
chmod 600 "$INFO_DIR"/*.txt
success "Passwords written to $INFO_DIR/*.txt"
echo ""

info "Creating root CA: $ROOT_CN"
# Custom template = DefaultRootTemplate + crlDistributionPoints. --profile and
# --template are mutually exclusive, so this template supplies everything
# --profile root-ca would otherwise set (subject/issuer/keyUsage/basicConstraints).
ROOT_TPL=$(mktemp)
trap 'rm -f "$ROOT_TPL"' EXIT
cat > "$ROOT_TPL" <<EOF
{
	"subject": {{ toJson .Subject }},
	"issuer": {{ toJson .Subject }},
	"keyUsage": ["certSign", "crlSign"],
	"basicConstraints": {
		"isCA": true,
		"maxPathLen": 1
	},
	"crlDistributionPoints": ["https://${PUBLIC_HOSTNAME}/rootcrl/root_ca.crl"]
}
EOF
step certificate create "$ROOT_CN" \
    "$INFO_DIR/root_ca.crt" "$INFO_DIR/root_ca.key" \
    --template "$ROOT_TPL" --kty EC --curve P-256 \
    --not-after "$ROOT_NOT_AFTER" \
    --no-password --insecure --force
rm -f "$ROOT_TPL"
chmod 600 "$INFO_DIR/root_ca.key"
openssl x509 -in "$INFO_DIR/root_ca.crt" -outform der -out "$INFO_DIR/root_ca.cer"
success "Root CA created ($INFO_DIR/root_ca.crt, DER copy at root_ca.cer for Intune upload)"
echo ""

info "Creating intermediate CA: $INT_CN"
step certificate create "$INT_CN" \
    "$INFO_DIR/intermediate_ca.crt" "$INFO_DIR/intermediate_ca.key" \
    --profile intermediate-ca --kty EC --curve P-256 \
    --ca "$INFO_DIR/root_ca.crt" --ca-key "$INFO_DIR/root_ca.key" \
    --password-file "$INFO_DIR/intermediate_ca.txt" \
    --not-after "$INT_NOT_AFTER" \
    --force
openssl x509 -in "$INFO_DIR/intermediate_ca.crt" -outform der -out "$INFO_DIR/intermediate_ca.cer"
success "Intermediate CA created ($INFO_DIR/intermediate_ca.crt, DER copy at intermediate_ca.cer for Intune upload)"
echo ""

info "Creating SCEP RA leaf certificate: $RA_CN"
# Must be RSA — the SCEP implementation used by step-ca/PIMPtune has no ECIES support.
step certificate create "$RA_CN" \
    "$INFO_DIR/scep_ra.crt" "$INFO_DIR/scep_ra.key" \
    --profile leaf --kty RSA --size 2048 \
    --ca "$INFO_DIR/intermediate_ca.crt" --ca-key "$INFO_DIR/intermediate_ca.key" \
    --ca-password-file "$INFO_DIR/intermediate_ca.txt" \
    --password-file "$INFO_DIR/scep_ra.txt" \
    --not-after 8760h \
    --force
success "SCEP RA certificate created"
echo ""

info "Generating root CRL (see scripts/03-generate-root-crl.sh for why this exists)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_DIR="$INFO_DIR" bash "$SCRIPT_DIR/03-generate-root-crl.sh"
echo ""

echo -e "${BOLD}${GREEN}############################################${RESET}"
echo -e "${BOLD}${GREEN}#   PKI generation complete ($INFO_DIR)   #${RESET}"
echo -e "${BOLD}${GREEN}############################################${RESET}"
echo ""
info "Next: run scripts/02-bootstrap-step-ca.sh to initialize step-ca and the pimptune provisioner."
info "The root CA private key ($INFO_DIR/root_ca.key) is no longer needed after this step."
info "For anything beyond a POC, move it offline (or delete it) once you've verified the chain."
