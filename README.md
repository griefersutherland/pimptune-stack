# pimptune-stack

A self-contained proof-of-concept deployment of [PIMPtune](https://github.com/griefersutherland/pimptune) — a SCEP proxy for Microsoft Intune-managed device enrollment — fronted by [step-ca](https://smallstep.com/docs/step-ca/) and published to the internet with a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

```
Windows Device (SCEP client)
        │
        ▼
  Cloudflare Tunnel (outbound-only, no exposed ports)
        │
        ▼
    PIMPtune          ◄ ─ ► Microsoft Graph API (SCEP endpoint discovery)
        │              ◄ ─ ► Microsoft Intune API (challenge validation, notifications)
        │              ◄ ─ ► step-ca (certificate signing, internal docker network only)
        ▼
    SQLite (local certificate cache)
```

`step-ca` is never exposed to the internet directly — only `pimptune` is, via the tunnel. `step-ca` and `pimptune` talk to each other over an internal Docker network.

## What this is / isn't

This gets you a **working POC**: a real root CA, a real intermediate CA, a real SCEP RA certificate, and a `pimptune` provisioner wired up to `step-ca` — enough to actually issue certificates through the full chain. It is **not** a hardened production deployment:

- The root CA private key is generated on the same machine and left on disk. For production, generate it offline (see "Going to production" below).
- You still need a real Azure AD app registration and Intune tenant — there's no way around this, since `pimptune`'s whole job is validating enrollment against live Intune APIs. It makes a live call to Microsoft Graph at startup and will not serve requests without valid credentials.

## Prerequisites

- Docker + Docker Compose v2 (`docker compose version`)
- [`step` CLI](https://smallstep.com/docs/step-cli/installation) — on Arch, the package is `step-cli` and installs the binary as `step-cli`, not `step`; symlink it (`ln -s /usr/bin/step-cli ~/.local/bin/step`) or alias it before running the scripts.
- `jq`
- `openssl`
- A Cloudflare account with a domain onboarded, for the tunnel
- An Azure AD tenant with permission to create an App Registration

## Quickstart

```bash
git clone <this-repo>
cd pimptune-stack
./scripts/quickstart.sh
```

The **first run** just creates `.env` from `.env.example` (pre-filling `PUID`/`PGID` with your own uid/gid) and exits — go edit it, at minimum `PUBLIC_HOSTNAME` (see "Cloudflare Tunnel setup" below for what that should be). Everything in `.env` gets loaded before anything else runs, so this is the one place you set it.

**Run it again** and it does the actual bootstrap, in order:

1. **`scripts/01-generate-pki.sh`** — generates a root CA, an intermediate CA, and a SCEP RA leaf certificate into `./info/`, along with random passwords for each.
2. **`scripts/02-bootstrap-step-ca.sh`** — runs `step ca init` against that PKI to build `./ca/config/ca.json`, registers a `pimptune` JWK provisioner, and patches in CRL config and the client-cert template using `PUBLIC_HOSTNAME` from `.env` (falls back to `scep-dev.example.com` if unset), then installs everything into `./ca/`.

Neither script needs `sudo` — `docker-compose.yaml` runs both containers as `${PUID}:${PGID}` (your own user) rather than the images' baked-in UIDs, so the files these scripts create stay readable with no ownership juggling.

After that:

```bash
# edit .env — fill in TENANT_ID, CLIENT_ID, and add ./secrets/intune-client-secret.txt
mkdir -p secrets
echo -n "your-client-secret" > secrets/intune-client-secret.txt
chmod 600 secrets/intune-client-secret.txt

docker compose up -d
docker compose logs -f pimptune
```

If `pimptune` logs show it successfully querying Microsoft Graph (instead of an `invalid_tenant`/`invalid_client` error), the Azure side is wired up correctly and it'll proceed to serve SCEP requests.

## Azure AD / Intune setup

`pimptune` needs an App Registration with:

1. **Azure Portal → App registrations → New registration.** Note the **Application (client) ID** and **Directory (tenant) ID** — these go in `.env` as `CLIENT_ID` and `TENANT_ID`.
2. **API permissions → Add a permission → Microsoft Graph → Application permissions → `Application.Read.All`**, then grant admin consent.
3. **Certificates & secrets → New client secret.** Put the secret value (not the ID) in `secrets/intune-client-secret.txt`, no trailing newline.
4. In **Intune** (Microsoft Endpoint Manager admin center), assign the app the **`scep_challenge_provider`** role so it's authorized to validate SCEP challenges.

## Cloudflare Tunnel setup

1. **Cloudflare Zero Trust dashboard → Networks → Tunnels → Create a tunnel.**
2. Choose **Cloudflared** as the connector type, name it (e.g. `pimptune`), and select **Docker** on the install step — it will show you a token (a long string after `--token`). Put that in `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
3. Under **Public Hostnames**, add one:
   - **Subdomain/domain**: whatever hostname you want clients to enroll against — put this exact value in `.env` as `PUBLIC_HOSTNAME` (e.g. `scep-dev.example.com` for a dev/POC deployment, or your real domain for anything longer-lived)
   - **Service**: `HTTP` → `pimptune:8080` (the internal Docker service name/port — cloudflared reaches it over the `internal` network, nothing needs to be published to the host)
4. Set `PUBLIC_HOSTNAME` in `.env` to match *before* running `./scripts/quickstart.sh` — it's what `02-bootstrap-step-ca.sh` uses to bake the right CRL/issuing-cert URLs into every cert `pimptune` issues. If you change it after already bootstrapping, re-run `./scripts/02-bootstrap-step-ca.sh -f` to rebuild `./ca/config` with the new value.
5. `docker compose up -d cloudflared` (or just `docker compose up -d` for everything) once the token is in `.env`.

At this point `https://${PUBLIC_HOSTNAME}/scep` is your SCEP enrollment endpoint and `https://${PUBLIC_HOSTNAME}/crl` is your CRL distribution point — configure these in your Intune SCEP certificate profile.

## Intune configuration profiles

Devices need to trust the CA chain *and* know how to enroll against it. That's two things in Intune: two **Trusted certificate** profiles (root + intermediate) and one **SCEP certificate** profile. All three need to be assigned to the same device/user group, or enrollment will fail with a chain-trust error even though SCEP itself works.

### 1. Grab the CA certs for upload

Intune wants DER-encoded (`.cer`) files — `scripts/01-generate-pki.sh` already produces these, and `scripts/02-bootstrap-step-ca.sh` copies them into `./ca/certs/`:

```
./ca/certs/root_ca.cer
./ca/certs/intermediate_ca.cer
```

(If you brought your own PKI instead of generating it with these scripts, `02-bootstrap-step-ca.sh` will generate the `.cer` copies for you from whatever `.crt` files you provided.)

### 2. Trusted certificate profile — Root CA

**Intune admin center → Devices → Configuration → Create → New policy**

- Platform: `Windows 10 and later`
- Profile type: `Templates` → `Trusted certificate`
- Certificate file: upload `ca/certs/root_ca.cer`
- Destination store: `Computer certificate store – Root`
- Assign to the same device/user group you'll use for the SCEP profile below

### 3. Trusted certificate profile — Intermediate CA

Same as above, as a **separate** profile:

- Certificate file: upload `ca/certs/intermediate_ca.cer`
- Destination store: `Computer certificate store – Intermediate`

(Two separate profiles, not one — Intune's Trusted Certificate template only carries a single cert per profile, and the client needs both root and intermediate installed to build a full chain to whatever `pimptune` hands back.)

### 4. SCEP certificate profile

**Devices → Configuration → Create → New policy → Windows 10 and later → Templates → SCEP certificate**

| Setting | Value |
|---|---|
| Certificate type | `Device` |
| Subject name format | `CN={{AAD_Device_ID}}` — see note below |
| Subject alternative name | Optional; add `UPN={{UserPrincipalName}}` if you need it downstream |
| Certificate validity period | Must be ≤ the `maxTLSCertDuration` claim set on the `pimptune` provisioner (`MAX_TLS_DUR` in `scripts/02-bootstrap-step-ca.sh`, default `720h` / 30 days) |
| Key storage provider | `Enroll to both the TPM KSP and the software KSP, without key attestation` (or TPM-only if your fleet supports it) |
| Key usage | `Digital signature`, `Key encipherment` |
| Key size | `2048` |
| Hash algorithm | `SHA-2` |
| Root certificate | Select the **Root CA trusted-certificate profile** from step 2 |
| Extended key usage | `Client Authentication` (OID `1.3.6.1.5.5.7.3.2`) |
| SCEP Server URLs | `https://${PUBLIC_HOSTNAME}/scep` — the same hostname you set in `.env` and mapped in the Cloudflare Tunnel (Intune appends its own path segments; don't include `/pkiclient.exe` here) |

**Subject name note:** if you enable `pimptune`'s optional device-compliance check, it identifies the requesting device by parsing the certificate's Common Name as either an Intune device ID or an Azure AD device ID — so the Subject name format must be `CN={{DeviceId}}` (Intune device ID) or `CN={{AAD_Device_ID}}` (Azure AD device ID) accordingly. If you're not using the compliance check, any subject format works.

Assign this profile, and the two trusted-certificate profiles, to the same group. Devices will pick up all three on their next sync and should enroll without a manual "Sync" if you're patient, or trigger one from Company Portal / `Settings → Accounts → Access work or school → Info → Sync`.

### Verifying enrollment worked

- `docker compose logs -f pimptune` on the server — a successful enrollment logs the CSR validation, Intune challenge verification, and step-ca signing steps in sequence.
- On the device: `certlm.msc` → Personal → Certificates should show the issued cert, and Trusted Root/Intermediate Certification Authorities should show the imported CA chain.

## Going to production

If you're moving past the POC stage, the biggest change is where the root CA key lives. `01-generate-pki.sh` generates root, intermediate, and RA all on one networked machine — fine for a POC, not fine once this is issuing real certificates. The fix is an **offline root**: the root key is generated on a machine that never touches a network, ever, and only ever produces signatures for intermediate CSRs. The intermediate's key still lives on the server (`step-ca` needs it to sign day-to-day certs), which is the normal, acceptable tradeoff — compromising the intermediate lets an attacker mint certs, but you can revoke and rotate it without re-establishing trust on every device, because the root (which every device actually trusts) was never exposed.

Don't reuse the POC's generated root for this — it was born on a networked machine, so treat it as burned.

Two machines are involved below: an **online machine** (wherever you're running this repo / `step-ca`) and an **offline machine** (air-gapped — no network interface active, ideally never has one). Moving files between them means physical media (USB drive) — that's the whole point.

### 1. Online machine: generate the intermediate CSR

```bash
mkdir -p ./info
INT_PASSWORD=$(openssl rand -base64 24)
echo -n "$INT_PASSWORD" > ./info/intermediate_ca.txt
chmod 600 ./info/intermediate_ca.txt

step certificate create "Your Org Issuing CA" \
    ./info/intermediate_ca.csr ./info/intermediate_ca.key \
    --csr --kty EC --curve P-256 \
    --password-file ./info/intermediate_ca.txt
```

This produces `intermediate_ca.csr` (public — safe to move around) and `intermediate_ca.key` (the intermediate's key; it's supposed to live here, on the server). Copy `intermediate_ca.csr` onto a USB drive.

### 2. Offline machine, first time only: generate the root CA

```bash
ROOT_PASSWORD=$(openssl rand -base64 32)
echo -n "$ROOT_PASSWORD" > root_ca.txt
# Store this password separately from root_ca.key itself — different
# custodian, different physical location, e.g. a sealed printed copy in a safe.

step certificate create "Your Org Root CA" \
    root_ca.crt root_ca.key \
    --profile root-ca --kty EC --curve P-256 \
    --password-file root_ca.txt
```

`root_ca.key` never leaves this machine again, full stop. Lock the machine (or the drive holding the key, if removable) away physically. This step only happens once — every future intermediate renewal reuses this same root.

### 3. Offline machine: sign the intermediate CSR

Copy `intermediate_ca.csr` from the USB drive onto the offline machine, then:

```bash
step certificate sign \
    --profile intermediate-ca \
    intermediate_ca.csr root_ca.crt root_ca.key \
    --password-file root_ca.txt \
    > intermediate_ca.crt
```

Copy `intermediate_ca.crt` and `root_ca.crt` (both public certs, safe to move) back onto the USB drive. Wipe the drive after transferring back to the online machine — don't let `intermediate_ca.csr` linger on removable media indefinitely, and definitely confirm `root_ca.key`/`root_ca.txt` never made it onto that drive by mistake before it leaves the room.

### 4. Online machine: assemble and generate the RA cert

Copy `root_ca.crt` and `intermediate_ca.crt` from the drive into `./info/`, alongside the `intermediate_ca.key`/`intermediate_ca.txt` already there from step 1:

```
info/
  root_ca.crt          <- from offline machine (step 3)
  intermediate_ca.crt  <- from offline machine (step 3)
  intermediate_ca.key  <- already here (step 1)
  intermediate_ca.txt  <- already here (step 1)
```

You now have everything needed to sign the SCEP RA cert locally, since the intermediate's key is right here:

```bash
RA_PASSWORD=$(openssl rand -base64 24)
echo -n "$RA_PASSWORD" > ./info/scep_ra.txt
chmod 600 ./info/scep_ra.txt

step certificate create "Your Org SCEP RA" \
    ./info/scep_ra.crt ./info/scep_ra.key \
    --profile leaf --kty RSA --size 2048 \
    --ca ./info/intermediate_ca.crt --ca-key ./info/intermediate_ca.key \
    --ca-password-file ./info/intermediate_ca.txt \
    --password-file ./info/scep_ra.txt \
    --not-after 8760h

openssl rand -base64 24 | tr -d '\n' > ./info/pimptune.jwk.txt
chmod 600 ./info/pimptune.jwk.txt
```

### 5. Bootstrap as usual

Make sure `PUBLIC_HOSTNAME` in `.env` is set to your real domain (not the `scep-dev.example.com` POC default), then:

```bash
set -a; source .env; set +a
./scripts/02-bootstrap-step-ca.sh
```

Skip `01-generate-pki.sh` entirely here — that script generates its own throwaway root, which is exactly what this whole procedure avoids. `02-bootstrap-step-ca.sh` doesn't care how the files in `./info/` were produced, only that they're there and internally consistent (it verifies the chain and key/cert pairing before doing anything else).

### Renewing the intermediate

The intermediate cert expires eventually (`step certificate inspect ./ca/certs/intermediate_ca.crt` shows when). Renewing means repeating steps 1, 3, and 4–5 with a fresh CSR before the old one expires, then re-running `02-bootstrap-step-ca.sh -f` to rebuild `./ca/config` against the new intermediate. That's a service interruption — schedule it, don't let it happen by surprise. Put the expiry date somewhere you'll actually see it (calendar reminder, monitoring check on the cert's `notAfter`).

Other things worth doing before this is load-bearing:

- Consider an HSM or cloud KMS for the intermediate key rather than a plain file on disk — the intermediate key is now the single most valuable secret on the server.
- Review `step-ca`'s own [production hardening guidance](https://smallstep.com/docs/step-ca/certificate-authority-server-production/).

## Repo layout

```
docker-compose.yaml       step-ca + pimptune + cloudflared
.env.example               copy to .env
scripts/
  01-generate-pki.sh        creates root/intermediate/RA certs into ./info
  02-bootstrap-step-ca.sh   step ca init + pimptune provisioner + config patching into ./ca
  quickstart.sh             runs both, plus .env setup
./info/    (gitignored)     generated PKI material — root_ca.key lives here
./ca/      (gitignored)     step-ca's runtime state (config, certs, secrets, db)
./data/    (gitignored)     pimptune's SQLite certificate store
./secrets/ (gitignored)     intune-client-secret.txt
```
