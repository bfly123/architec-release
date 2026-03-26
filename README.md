# architec-release

`architec-release` owns Architec release orchestration, packaging helpers, installer assets, and release automation.

The repo is designed to live beside the source and website repos:

- `../architec`
- `../architec-cloud`

Default local layout:

```text
/home/bfly/workspace/
  architec/
  architec-cloud/
  architec-release/
```

## Key paths

- release scripts: `tools/`
- release docs: `docs/`
- generated assets: `release-assets/`

## Local usage

Build release artifacts:

```bash
python3 tools/build_release.py --with-nuitka
```

Run the end-to-end release install smoke:

```bash
bash tools/release_install_smoke.sh
```

Cut a release from the sibling source repo:

```bash
bash tools/cut_release.sh
```

Environment overrides are available when the repos are not sibling directories:

- `ARCHITEC_SOURCE_DIR`
- `ARCHITEC_CLOUD_DIR`
- `ARCHITEC_HIPPOCAMPUS_SOURCE`
- `ARCHITEC_LLMGATEWAY_SOURCE`
