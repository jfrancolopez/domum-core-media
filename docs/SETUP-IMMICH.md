# Immich

Immich is managed as a bundle, not as four independently updated images.

## Config

```bash
IMMICH_BUNDLE_AUTO_UPDATE=1
IMMICH_BUNDLE_DELAY_DAYS=21
IMMICH_BUNDLE_ROLLBACK_ENABLED=1
IMMICH_SERVER_IMAGE=ghcr.io/immich-app/immich-server:release
IMMICH_MACHINE_LEARNING_IMAGE=ghcr.io/immich-app/immich-machine-learning:release
IMMICH_REDIS_IMAGE=docker.io/redis:6.2-alpine
IMMICH_POSTGRES_IMAGE=tensorchord/pgvecto-rs:pg14-v0.2.0
```

The four image refs are managed by the bundle workflow. Do not hand-edit them
during normal operation.

## Bootstrap

`domum-media configure` creates:

- `/etc/domum-core-media/secrets/immich_db_password`
- `/etc/domum-core-media/secrets/immich_jwt_secret`

`domum-media apply` validates the rendered compose env and records the original
database-password fingerprint after the first healthy boot.

## Update flow

```bash
sudo domum-media immich check-bundle
sudo domum-media immich apply-bundle
sudo domum-media immich rollback
```

The workflow:

1. fetch latest release metadata
2. extract image refs from the upstream compose file
3. store the candidate bundle
4. wait out `IMMICH_BUNDLE_DELAY_DAYS`
5. verify backup freshness
6. snapshot Immich data
7. deploy the new bundle
8. restore on failed health validation

## Resetting the database

```bash
sudo domum-media immich reset-db
sudo domum-media immich reset-db --wipe-uploads
```

Use this only when you intentionally want to discard the existing Immich
database and re-bootstrap against a new DB password.
