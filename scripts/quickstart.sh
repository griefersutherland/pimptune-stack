#!/bin/bash
# quickstart.sh — run the full POC bootstrap end to end:
#   1. create .env from .env.example (first run only — then exits so you can
#      edit it before anything gets baked into certs)
#   2. generate root/intermediate/RA PKI material
#   3. initialize step-ca and register the pimptune JWK provisioner, using
#      PUBLIC_HOSTNAME (and anything else) from .env
#
# Does NOT run 'docker compose up' for you — you still need to fill in Intune
# credentials and the Cloudflare Tunnel token, and add secrets/intune-client-secret.txt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info() { echo -e "${CYAN}[.]${RESET} $*"; }

if [[ ! -f .env ]]; then
    info "Creating .env from .env.example"
    cp .env.example .env
    sed -i "s/^PUID=.*/PUID=$(id -u)/" .env
    sed -i "s/^PGID=.*/PGID=$(id -g)/" .env
    echo ""
    echo -e "${BOLD}Created .env.${RESET} Edit it now — at minimum PUBLIC_HOSTNAME (so the right"
    echo "URLs get baked into issued certs), then re-run this script to bootstrap."
    exit 0
fi

info "Loading .env"
set -a
# shellcheck disable=SC1091
source .env
set +a

info "Step 1/2: generating PKI"
bash scripts/01-generate-pki.sh

info "Step 2/2: bootstrapping step-ca + pimptune provisioner (PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME:-unset, using script default})"
bash scripts/02-bootstrap-step-ca.sh

# Pre-create bind-mount targets as ourselves. If these don't exist yet,
# `docker compose up` has the Docker daemon (running as root) auto-create
# them — which makes them root-owned and unwritable by the `user: ${PUID}:${PGID}`
# containers, even though those containers are supposed to run as us.
mkdir -p ./data/pimptune ./secrets

echo ""
echo -e "${GREEN}${BOLD}Quickstart complete.${RESET} Next steps:"
echo "  1. Add your Intune client secret: echo -n '...' > secrets/intune-client-secret.txt && chmod 600 secrets/intune-client-secret.txt"
echo "  2. Create a Cloudflare Tunnel with a Public Hostname matching PUBLIC_HOSTNAME in .env, pointing at pimptune:8080 (see README.md)"
echo "  3. docker compose up -d"
