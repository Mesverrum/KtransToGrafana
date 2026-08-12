# SNMPv3 credentials via AWS Secrets Manager

[← back to README](../README.md) · [Configuration](configuration.md)

The quickstart stores SNMP credentials in gitignored `groups/*.env` and bakes them into generated YAML. That is fine for a lab. For a host that should not keep passphrases on disk, **ktranslate can resolve SNMPv3 from AWS Secrets Manager** at runtime.

This page is a **thin optional path** for that. Azure Key Vault and GCP Secret Manager work the same way in ktranslate (`azure.kv.…` / `gcp.sm.…`); we only spell out AWS here.

Upstream reference: [Advanced Ktranslate Configuration — Cloud provider secrets](https://github.com/kentik/ktranslate/wiki/Advanced-Ktranslate-Configuration).

---

## What you get

| On disk / in git | At runtime |
|------------------|------------|
| `groups/secure-aws.env` holds `SNMP_V3_SECRET=aws.sm.<name>` (a **name**, not a passphrase) | ktranslate calls Secrets Manager, loads the JSON profile, uses it for discovery/polling |
| Generated `config/discovery-*.yaml` contains `default_v3: aws.sm.<name>` | Same |

Kentik notes that **v2c communities are not loaded from cloud secrets** (communities are plaintext on the wire anyway). Use **SNMPv3** for this path.

---

## 1. Create the secret in AWS

Store a **SecretString** JSON object with the SNMPv3 fields ktranslate expects:

```json
{
  "user_name": "snmp-ro",
  "authentication_protocol": "SHA",
  "authentication_passphrase": "replace-me",
  "privacy_protocol": "AES",
  "privacy_passphrase": "replace-me"
}
```

Example CLI (name `ktrans-snmp-v3` matches the sample group):

```bash
aws secretsmanager create-secret \
  --name ktrans-snmp-v3 \
  --secret-string file://snmp-v3.json \
  --region us-east-1
```

IAM for the collector host (or the keys you pass in) needs at least `secretsmanager:GetSecretValue` on that secret.

---

## 2. Point a credential group at the secret

```bash
cp groups/secure-aws.env.sample groups/secure-aws.env
# edit TARGETS, ports if needed; set SNMP_V3_SECRET=aws.sm.<your-secret-name>
```

`SNMP_V3_SECRET` must look like `aws.sm.SecretName`. Do **not** also set `SNMP_V3_USER` / `SNMP_V3_AUTH_PASS` / … on the same group.

Optional second profile for discovery: `SNMP_V3_SECRET_2=aws.sm.other-name` (renders as `other_v3s`).

---

## 3. Give the containers AWS access

In `.env` (see `.env.sample`):

```bash
AWS_REGION=us-east-1
```

**Prefer an EC2 instance role / ECS task role** with `GetSecretValue`. Then you do **not** need long-lived keys in `.env`.

If you must use keys (laptop lab):

```bash
AWS_ACCESS_KEY_ID=AKIA…
AWS_SECRET_ACCESS_KEY=…
# AWS_SESSION_TOKEN=…   # when using temporary creds
```

`make generate` wires these into every `ktranslate_snmp_*` and `discover_*` service. Empty values are harmless for groups that do not use `aws.sm.`.

---

## 4. Generate, start, discover

```bash
make generate
make up
make discover GROUP=secure-aws
```

Check the rendered discovery config contains the reference, not a passphrase:

```bash
grep -A2 default_v3 config/discovery-secure-aws.yaml
# expect: default_v3: aws.sm.ktrans-snmp-v3
```

---

## Caveats

- **Discovery device files** (`state/devices-*.yaml`) may still record credential material after a successful discover — treat `state/` as sensitive; it is gitignored.
- **Trap community** in the group file is still a local string (traps are usually v2c).
- **Grafana OTLP** (`GC_OTLP_KEY` in `.env`) is separate — this page only covers SNMP v3 for ktranslate.
- Multiple cloud providers in one generator “framework” is intentionally out of scope; swap the `aws.sm.` prefix (and the matching env vars) if you use Azure/GCP.

---

## Generator contract

| `groups/*.env` | Rendered discovery YAML |
|----------------|-------------------------|
| `SNMP_VERSION=v3` + `SNMP_V3_SECRET=aws.sm.NAME` | `default_v3: aws.sm.NAME` |
| `SNMP_V3_SECRET_2=aws.sm.OTHER` | `other_v3s: [aws.sm.OTHER, …]` |
| Inline `SNMP_V3_USER` / `*_PASS` (quickstart) | Unchanged block form |
