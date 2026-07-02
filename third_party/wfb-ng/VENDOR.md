# Vendored: wfb-ng

This directory is a **vendored local copy** of wfb-ng (Wifibroadcast NG) — the
long-range packet-injection video/telemetry link this project is built on. It
is included so the project can be rebuilt on a fresh SD card independently of
upstream availability.

## Provenance

- **Upstream:** https://github.com/svpcom/wfb-ng
- **Copied:** 2026-06-04 from upstream `master` (exact upstream commit was not
  recorded at copy time; `Changelog.md` head reads "23.08 upcoming").
- **Upstream `.git` removed** (tracked as plain files in this repo).
- Originally copied to the repo root; moved here 2026-07-02 to separate our
  project files from vendored code.

## Local changes vs upstream

- **Removed** (unused by this project; restore from upstream if ever needed):
  - `docker/` — only used by the `deb_docker`/`rpm_docker` cross-build targets
    in the `Makefile` (which therefore no longer work; we build natively on the
    Pis with plain `make deb`).
  - `openwrt/` — OpenWrt packaging.
  - `.github/` — upstream CI workflows and issue templates.
- No source-code modifications.

## How this project builds it

Natively on each Pi (see `INSTALL.md` §2.2 / §3.3 at the repo root):

```bash
cd third_party/wfb-ng
make deb
sudo apt install -y ./deb_dist/wfb-ng_*_arm64.deb
```

## License

GPL-3.0 — same as this repository; the full text is `LICENSE.txt` at the repo
root (moved from this directory's original copy).
