# Setup QGIS OSGeo4W

Installs [QGIS](https://qgis.org) on GitHub-hosted Windows runners from the official OSGeo4W MSI
installers at <https://download.osgeo.org/qgis/windows/>, the day they are published:

- resolves a version prefix (`3.44`) to the newest build, or takes an exact build or file name;
- verifies the MSI against its SHA-256 (published, or pinned by you) and its Authenticode signature
  (The Open Source Geospatial Foundation);
- installs it silently and checks it with `qgis_process --version`;
- caches the **installed tree**, so later runs skip both the download and `msiexec`.

## Usage

```yaml
jobs:
  test:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - id: qgis
        uses: ivanlonel/setup-qgis-osgeo4w@v1
        with:
          version: "3.44" # newest 3.44.x build
      - env:
          QGIS_PROCESS: ${{ steps.qgis.outputs.qgis-process }}
        run: '& $env:QGIS_PROCESS --version'
```

A matrix over QGIS lines, cancelling superseded runs when a pull request is updated:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: windows-latest
    strategy:
      matrix:
        qgis: ["3.40", "3.44", "latest"]
    steps:
      - id: qgis
        uses: ivanlonel/setup-qgis-osgeo4w@v1
        with:
          version: ${{ matrix.qgis }}
```

`concurrency` is a workflow/job setting that actions cannot declare, so put it in your workflow.
The action is safe to cancel: the download is only renamed into place after verification, and the
cache is saved only after a successful install and check.

An exact, pinned build (fails if the file on the server is ever replaced):

```yaml
      - uses: ivanlonel/setup-qgis-osgeo4w@v1
        with:
          version: 3.44.16-1
          sha256: 6d1dc453ab537b2bba53194e6d240d9aa56e04d4a08b6194aebc2c0176562621
```

The Grids variant (bundled datum-shift grids), or any installer by file name:

```yaml
        with:
          version: "4.4"
          flavor: grids
# or
        with:
          installer: QGISQT6-OSGeo4W-3.44.6-1 # .msi optional
```

## Inputs

| Input                      | Default                         | Description                                                                                                                                                    |
| -------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`                  | latest                          | `4`, `4.2`, `4.2.3` or an exact build `4.2.3-2`. Empty or `latest` = the newest build.                                                                         |
| `flavor`                   | `standard`                      | `standard` (`QGIS-OSGeo4W-*`) or `grids` (`QGIS-Grids-OSGeo4W-*`).                                                                                             |
| `installer`                |                                 | Exact file name, e.g. `QGIS-Grids-OSGeo4W-4.2.3-2`. Excludes `version` and `flavor`.                                                                           |
| `sha256`                   |                                 | Expected SHA-256 of the MSI. Needs an exact build (`version: x.y.z-r` or `installer`).                                                                         |
| `install-dir`              | `C:\Program Files\QGIS <x.y.z>` | Absolute install directory (the MSI's own default when empty). Not a drive root; no wildcards (`* ? [ ]`), quotes or cmd metacharacters (`% & ^ ! < >`, pipe). |
| `cache`                    | `true`                          | Cache the installed tree.                                                                                                                                      |
| `verify-signature`         | `true`                          | Require a valid Authenticode signature by The Open Source Geospatial Foundation.                                                                               |
| `add-to-path`              | `false`                         | Prepend `<root>\bin` (the OSGeo4W tools: `gdalinfo`, `ogr2ogr`, …) to `PATH`.                                                                                  |
| `download-timeout-minutes` | `30`                            | Budget for the listing, `.sha256sum` and MSI downloads, retries included. `0` = none.                                                                          |
| `install-timeout-minutes`  | `20`                            | Budget for `msiexec` plus the `qgis_process` check. `0` = none.                                                                                                |

### How `version` is resolved

- A prefix matches whole components: `3.4` matches `3.4.x` only, never `3.40` or `3.44`.
- Builds compare numerically on major, minor, patch and installer revision (`4.2.3-2` > `4.2.3-1`).
- Only builds whose `.sha256sum` is already published count, so a run during an upload picks the
  previous build instead of a half-uploaded file.
- Weekly development builds are not supported.

## Outputs

| Output         | Example                                                                 |
| -------------- | ----------------------------------------------------------------------- |
| `version`      | `4.4.0-1`                                                               |
| `installer`    | `QGIS-OSGeo4W-4.4.0-1.msi`                                              |
| `sha256`       | SHA-256 the MSI was verified against                                    |
| `cache-hit`    | `true` when the installed tree came from the cache                      |
| `root`         | `C:\Program Files\QGIS 4.4.0` (`OSGEO4W_ROOT`)                          |
| `prefix`       | `C:\Program Files\QGIS 4.4.0\apps\qgis` (`apps\qgis-ltr` on LTR builds) |
| `qgis-process` | `C:\Program Files\QGIS 4.4.0\bin\qgis_process-qgis.bat`                 |
| `python`       | `C:\Program Files\QGIS 4.4.0\apps\Python312\python.exe`                 |

## Caching

The installed tree is saved with `actions/cache/save` right after a fresh install, before your own
steps run, so it is saved even if your tests fail. The key covers the installer, its SHA-256, the
install directory, the runner image and whether the signature was checked, and on a hit the action
restores the tree to the same path and only runs the `qgis_process` check.

- Each tree is roughly 1 GB (Grids more), and a repository gets 10 GB of cache by default. Entries
  unused for 7 days are evicted.
- Caches created by a pull request are visible only to that pull request. Caches created on the
  default branch are visible to every pull request, so a push to `main` warms them for everyone.
- If a cached tree ever fails its check, the action reinstalls from the MSI and warns with the
  `gh cache delete <key>` command to drop the bad entry (a key that keeps getting hit never expires).
- `cache: false` turns it off.

## Security

- Pin this action by commit SHA (`ivanlonel/setup-qgis-osgeo4w@<sha> # v1.0.0`) and let
  Renovate or Dependabot update it. Releases are immutable; `v1` is a moving tag.
- Without a `sha256` pin, the MSI is checked against the `.sha256sum` next to it on the server,
  which catches corruption but not a compromised server. The Authenticode check covers that.
  A pin additionally fails the run if the published file ever changes.
- Those checks run on the MSI, so they protect fresh installs only. A **cache hit is not
  re-verified**: the restored tree is trusted because of its key, and the key is computable from
  public data. Anything that can write your repository's Actions cache can plant a tree under it:
  any step of a workflow running on the default branch, including `pull_request_target`,
  `workflow_run` or `issue_comment` jobs that build untrusted code, or a compromised action in
  one of them. If that is a risk for a job that holds secrets or a write token, set
  `cache: false` there.

## Limitations

- GitHub-hosted Windows x64 runners (`windows-2022`, `windows-2025`). Other OSes fail fast; ARM64
  and self-hosted runners are not tested.
- The standard and Grids installers of one version share the same default directory; give one of
  them its own `install-dir` if you need both in a job.
- Only `.msi` installers are supported (not the older `.exe` ones).

## License

[MIT](LICENSE)
