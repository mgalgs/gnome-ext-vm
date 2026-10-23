# gnome-ext-vm

VM-based functional testing for GNOME Shell extensions.

gnome-ext-vm builds real GNOME desktops from distro cloud images, one per
GNOME Shell version. A test then runs these steps:

1. Restore a VM to a live snapshot, so it lands on a running desktop in
   about a second.
2. Install your extension the way a user would, from its zip.
3. Run your test steps: key presses, pointer moves and clicks, screenshots,
   and commands in the guest.
4. Check that the Shell is still healthy and the extension is running.
5. Keep a screenshot, the Shell journal and a timestamped event log.

`matrix` runs the same test across GNOME versions and writes an HTML report
you can compare against a baseline run.

The VMs, base images and SSH key are shared by every project on the
machine. Each project brings a small config file and, optionally, hook
scripts.

**No root needed.** Everything runs as your user under libvirt's
`qemu:///session`, with `passt` user-mode networking.

## Requirements

- An x86_64 Linux host with KVM. Your user needs read and write access to
  `/dev/kvm`. On Debian and Ubuntu that means joining the `kvm` group
  (`sudo usermod -aG kvm $USER`, then log in again). Arch and Fedora open
  it to local users already.
- libvirt 9.0 or newer, for the `passt` network backend.
- About 4 GB of RAM per running VM, and about 500 MB of disk per cached base
  image plus a few GB per VM. Tests run one VM at a time.
- bash, git and the usual coreutils.

Host packages:

```bash
# Arch
sudo pacman -S libvirt qemu-full virt-install passt cdrtools imagemagick rsync virt-viewer
# Fedora
sudo dnf install libvirt qemu-kvm virt-install passt genisoimage ImageMagick rsync virt-viewer
# Debian / Ubuntu
sudo apt install libvirt-daemon-system qemu-system-x86 virtinst passt genisoimage imagemagick rsync virt-viewer
```

`virt-viewer` is optional; `gnome-ext-vm viewer` uses it.

## Install

Clone a release and link the CLI onto your PATH:

```bash
git clone --branch v0.1.0 https://github.com/mgalgs/gnome-ext-vm.git ~/.local/share/gnome-ext-vm-src
cd ~/.local/share/gnome-ext-vm-src
./install.sh --check   # report missing host tools
./install.sh           # ~/.local/bin/gnome-ext-vm -> this checkout
gnome-ext-vm --version
```

Any directory works for the clone. `install.sh` only creates a symlink, so
the CLI always runs whatever the checkout has. To upgrade, check out a newer
tag:

```bash
git -C ~/.local/share/gnome-ext-vm-src fetch --tags
git -C ~/.local/share/gnome-ext-vm-src checkout v0.2.0
```

### Versions

Releases are git tags, `vX.Y.Z`, and `gnome-ext-vm --version` prints the
one you have. A project that depends on the tool should name a tag in its
own testing docs, as in the clone command above, so every contributor runs
the same harness. Before 1.0, a minor version can change the project config
format or the command line, and the release notes say how.

## Quick start

```bash
gnome-ext-vm list                      # the GNOME versions it can build
gnome-ext-vm create --vm fedora44      # one-time, ~10 min; the cloud image is cached
cd ~/src/my-extension                  # has a gnome-ext-vm.conf (below)
gnome-ext-vm test --vm fedora44        # restore, build, deploy, check, screenshot
gnome-ext-vm matrix --label main       # every VM in the project's MATRIX + HTML report
gnome-ext-vm viewer --vm fedora44      # look at the desktop yourself
gnome-ext-vm stop --all
```

## Project config

The project config is a bash file named `gnome-ext-vm.conf`. The tool finds
it by looking in the current directory and every parent for
`gnome-ext-vm.conf`, `testing/gnome-ext-vm.conf` or
`testing/vm/gnome-ext-vm.conf`. `--config FILE` or `$GEV_CONFIG` overrides
the search. Relative paths in it are relative to the config file's
directory.

The smallest config packs the extension straight from its source directory:

```bash
EXT_UUID="my-extension@example.com"
EXT_SRC_DIR="../my-extension@example.com"
MATRIX="fedora42 fedora43 fedora44"
```

Every setting:

```bash
# Required.
EXT_UUID="my-extension@example.com"

# How to get the zip. Either a build command, run in PROJECT_ROOT, that
# leaves a zip at EXT_ZIP (default dist/$EXT_UUID.zip)...
EXT_BUILD="make zip"
EXT_ZIP="dist/${EXT_UUID}.zip"
# ...or the extension's source dir, which the tool packs with
# `gnome-extensions pack` (every file in it is included).
EXT_SRC_DIR=""

# Guest packages the extension needs at runtime, per distro family.
# See "Guest packages" for how these are installed.
GUEST_PACKAGES_FEDORA="libgtop2-devel"
GUEST_PACKAGES_DEBIAN="gir1.2-gtop-2.0"

# Extended regex: which journal lines count as yours. A "JS ERROR" line
# matching it fails the health check; matching lines go in shell.log.
# Default: the UUID up to the @.
LOG_FILTER="my-extension"

# VMs that make up the matrix (catalog names; see `gnome-ext-vm list`).
# Default: every created VM. DEFAULT_VM defaults to the first of these.
MATRIX="fedora42 fedora43 fedora44"
DEFAULT_VM="fedora44"

# Default: the git toplevel above the config file.
PROJECT_ROOT=".."
# Default: results/ next to the config file. Add it to .gitignore.
RESULTS_DIR="results"

# Hook scripts (optional). See "Hooks".
HOOK_PRE_DEPLOY=""
HOOK_POST_DEPLOY=""
HOOK_TEST="test-steps.sh"
HOOK_VARIANTS=""
HOOK_HOTRELOAD_SETUP=""
```

`gnome-ext-vm config` prints what was resolved. [`examples/`](examples)
has a config and a test-steps hook to copy.

## Commands

`gnome-ext-vm help` lists them all. Wherever a command takes `--vm NAME`,
the VM defaults to `$GEV_VM` (set inside hooks), then the project's
`DEFAULT_VM`, then the first created VM. You can name a VM by its catalog
name (`fedora42`) or by its libvirt domain (`gev-fedora42`).

### VM management

| Command | What it does |
|---|---|
| `list` | Catalog VMs with domain, state, snapshot and SSH port |
| `create [--vm N]... [--all] [--force]` | Download the image (cached), make a CoW disk, run cloud-init, install GNOME with auto-login, take the `clean-gnome-session` live snapshot, shut down. `--all` is the project's `MATRIX` when there is a config, else the whole catalog |
| `adopt --prefix P [--ssh-key K]` | Register existing domains named `P<name>` without changing them (see "Adopting existing VMs") |
| `adopt --vm N --domain D [--ssh-key K]` | Register one domain |
| `start` / `stop [--vm N] [--all]` | Boot / graceful shutdown |
| `destroy --vm N...` / `destroy --all --yes` | Remove VMs, their disks and snapshots; cached images stay. VMs are shared, so this affects every project. `--all` is scoped like `create --all` |
| `viewer [--vm N]` | SPICE viewer on the live desktop |
| `ssh [--vm N] [--wait] [-- CMD...]` | Shell, or run a command with the user's session bus |
| `copy [--vm N] SRC... DEST` | rsync files into the VM |

### Testing

`test [--vm N] [--label L] [--no-restore] [--screenshot-only] [--logs-only] [--timeout S] [--create]`

1. Restore the project's snapshot (the base, or its package layer) and sync the guest clock to the host's
2. Wait for SSH; record the gnome-shell PID and the guest time
3. `HOOK_PRE_DEPLOY`
4. Build the zip; `gnome-extensions install --force` it; install its schemas system-wide; if the Shell has never seen the UUID, restart GDM so a new session discovers it; enable, then disable and re-enable
5. `HOOK_POST_DEPLOY`, then `HOOK_TEST`
6. Health: gnome-shell running, same PID (no crash-restart), extension `ACTIVE` (GNOME 45 says `ENABLED`), no matching `JS ERROR` since step 2
7. Screenshot and journal

Exit codes: 0 pass, 1 fail (extension or hook), 2 infrastructure. A failing
hook fails the test. Output:

```
=== VM Test Results ===
VM: fedora42 (GNOME 48)
Status: PASS
GNOME Shell: running
Crash: none detected
Extension: ACTIVE
JS Errors: none
Screenshot: .../results/runs/20261020-150102_fedora42_test/screenshot.png
Logs: .../results/runs/20261020-150102_fedora42_test/shell.log
Events: .../results/runs/20261020-150102_fedora42_test/events.jsonl
Duration: 31s
```

`matrix [--label L] [--baseline L] [--vm N]... [--create] [--no-restore] [--variants] [--variant X]...`
runs `test` on each VM, then (with `--variants`) `HOOK_VARIANTS` with the
`--variant` names as arguments, and shuts each VM down before the next. It
writes `RESULTS_DIR/<label>/report.html`, with the baseline's screenshots
beside the current ones. The label defaults to the git branch.

`hotreload [--vm N] [--cycles N]` deploys, reboots for a cold JS load, runs
`HOOK_HOTRELOAD_SETUP`, then disables and re-enables the extension N times
(default 10). It fails if the Shell crashed or restarted, the extension is
not `ACTIVE`, or the journal shows `already disposed` or a matching `JS ERROR`.

`prepare [--vm N]... [--force]` builds the project's package layers ahead of
time; `test` builds a missing one on its own.

### Helpers for hooks

| Command | What it does |
|---|---|
| `screenshot [--name NAME]` | `virsh screenshot` → PNG. In a run it lands at `$GEV_RUN_DIR/shots/NAME.png`; otherwise in `RESULTS_DIR` (or `~/.local/share/gnome-ext-vm/results` with no project config). Prints the path |
| `send-key [--hold MS] CHORD...` | Press key chords via `virsh send-key`, e.g. `Shift+Print`, `Ctrl+Alt+T`, `Super`, `Escape`, `a`. `KEY_*` names pass through |
| `pointer move X Y` | Move the pointer to screen pixel X,Y (as in a screenshot) via the VM's USB tablet, to hover. Screenshots don't show the cursor, but hover effects do appear |
| `pointer click [X Y] [--button B]` | Click `left` (default), `right` or `middle`, after moving to X,Y if given |
| `wait-session [--timeout S]` | Wait for SSH and gnome-shell |
| `event NAME [KEY=VALUE]...` | Append a custom event to the run's `events.jsonl` |
| `ssh -- CMD`, `copy SRC DEST` | As above |

## Hooks

A hook is a bash script, run from `PROJECT_ROOT` with these in its
environment, and with `gnome-ext-vm` on PATH:

| Variable | Value |
|---|---|
| `GEV_VM` | VM name, so helpers need no `--vm` |
| `GEV_DOMAIN`, `GEV_SSH_PORT` | libvirt domain and forwarded SSH port |
| `GEV_UUID` | `EXT_UUID` |
| `GEV_RUN_DIR` | This run's output directory |
| `GEV_LABEL` | The run's label |
| `GEV_PROJECT_ROOT`, `GEV_CONFIG`, `GEV_RESULTS_DIR` | Resolved paths |

A non-zero exit fails the test. Hook start and end go in the event log.

| Hook | When |
|---|---|
| `HOOK_PRE_DEPLOY` | After restore, before the extension is installed |
| `HOOK_POST_DEPLOY` | After it is installed and enabled |
| `HOOK_TEST` | After post-deploy; the project's test steps |
| `HOOK_VARIANTS` | `matrix --variants` only, after a passing test. Arguments are the `--variant` names (none means the hook's default set). Each `screenshot --name X` shows up in the report as `X` |
| `HOOK_HOTRELOAD_SETUP` | `hotreload`, before the cycles |

Example test steps: open the calendar menu with a click, then check the
journal for a line the extension logs:

```bash
#!/bin/bash
set -euo pipefail
gnome-ext-vm pointer click 640 15
sleep 1
gnome-ext-vm screenshot --name calendar-open
gnome-ext-vm send-key Escape
gnome-ext-vm event check what=journal
gnome-ext-vm ssh -- "journalctl --user -b --since '-1min' --no-pager | grep -q 'my-extension: ready'"
```

## Output

Each run gets its own directory, so paths are stable and nothing is
overwritten:

```
RESULTS_DIR/
  runs/<YYYYmmdd-HHMMSS>_<vm>_<label>/
    events.jsonl      # one JSON object per event (below)
    screenshot.png    # end-of-test screenshot
    shell.log         # Shell journal, extension state, Shell version
    result.txt        # the results block
    shots/<name>.png  # named screenshots from hooks
  <label>/            # matrix runs
    report.html
    <vm>.png  <vm>.log  <vm>.output  <vm>.events.jsonl  <vm>_<shot>.png
```

`events.jsonl` lines look like
`{"ts":"2026-10-20T22:01:02.123Z","t":1792533662.123,"event":"screenshot","vm":"fedora44","path":".../shots/after-print.png"}`.
Events: `run_start`, `restore_start`/`restore_end`, `layer_build_start`/`layer_build_end`,
`deploy_start`/`deploy_end`, `gdm_restart`, `hook_start`/`hook_end`, `send_key`, `pointer`,
`screenshot`, `health_start`/`health_end`, `logs`, `cycle`, `reboot`, `run_end`,
and whatever hooks add with `event`. Each event records when it happened
by the wall clock, so the log can line a run up against a screen recording.

## Guest packages

Extra packages are a project concern, but the VMs are shared. So they go in
a **package layer**: a second live snapshot, made by restoring the base,
installing the packages, and snapshotting again. Tests restore the layer
instead of the base.

- The layer is keyed by a hash of the package list plus the base snapshot's
  creation time. Changing either builds a new layer the next time a test
  runs; nothing has to be invalidated by hand.
- If the base already has every package, the layer *is* the base, and no
  snapshot is added.
- Projects never see each other's packages, because every test starts from a
  restore.

Why not install at test time instead? That costs a package-manager run
(tens of seconds, and network) on every test, and makes a test's result
depend on the mirror that day. A layer pays once.

Layers are recorded in `~/.local/share/gnome-ext-vm/layers/`. `prepare --force`
rebuilds them.

## Shared state

Everything lives under `~/.local/share/gnome-ext-vm/` (`$GEV_DATA_DIR`
overrides):

```
images/        cloud base images, downloaded once (~500 MB each)
disks/         CoW VM disks and cloud-init seeds
ssh/id_ed25519 key for VMs this tool creates
vms.registry   name|domain|ssh_port|ssh_key for each created or adopted VM
layers/        package-layer records
locks/         one flock per VM
results/       screenshots taken outside a project
```

New VMs get libvirt domains named `gev-<name>` and the first free SSH port
from 2230. A per-VM lock means two projects never test on the same VM at
once; the second waits.

## The VMs

Each VM is a stock distro cloud image plus GNOME, with:

- a `testuser` account that logs in to GNOME automatically, has
  passwordless sudo, and accepts the tool's SSH key. Its password,
  `testpass`, is for the SPICE console only;
- SSH forwarded from `127.0.0.1:<port>` on the host, and nothing else
  exposed;
- virtio-gpu graphics (no real GPU) and no battery.

Treat them as disposable test machines. Don't put anything in one you would
mind losing; `destroy` and `create` rebuild it.

## Snapshots and clocks

The base snapshot is live: it holds memory, so a restore lands on a running
desktop in about a second. It also restores the clock from when the snapshot
was taken, so after each restore the tool steps the guest clock to the
host's. Journal checks use the guest's clock too.

## The catalog

The catalog of buildable VMs is [`vms.conf`](vms.conf): one line per VM
with its distro, GNOME Shell version and cloud image URL. Add entries, or
override shipped ones by name, in `~/.config/gnome-ext-vm/vms.conf` (same
format). Pre-release entries such as the Fedora nightly point at composes
that the mirrors prune within days; override the URL if a download 404s.

To add a VM:

1. Find the cloud image URL for the distro and version.
2. Add a line to your override file.
3. If the distro is not Fedora- or Debian-family, it also needs a case in
   `vm_provision` in `lib/vm.sh` and in `layer_build` in `lib/snapshot.sh`.
4. `gnome-ext-vm create --vm <name>`, then `gnome-ext-vm test --vm <name>`.

## Adopting existing VMs

If you already have GNOME test VMs under `qemu:///session`, `adopt`
registers them instead of building new ones. It changes nothing in the
domain, its disks or its snapshots. An adoptable domain needs:

- a catalog name to map to: `--prefix P` adopts every domain named
  `P<catalog-name>`, e.g. `--prefix mytest-` adopts `mytest-fedora42` as
  `fedora42`;
- a `passt` port forward to guest port 22, which is where the tool reads
  the SSH port from;
- a `testuser` account that accepts the key given with `--ssh-key`, with
  passwordless sudo and GNOME auto-login;
- ideally a live snapshot named `clean-gnome-session`. Without one, tests
  run on the domain's current state.

## Limits

These are smoke tests unless your hooks do more. Out of the box they show the
extension loads and goes `ACTIVE` without crashing the Shell or logging JS
errors, and they leave a screenshot. VMs have no real GPU and no battery,
so extensions that read either see nothing.

## Troubleshooting

- **SSH timeout**: the VM may still be booting. `gnome-ext-vm list`, then
  `gnome-ext-vm ssh --vm N --wait`.
- **Extension state ERROR**: read `shell.log` for the JS error.
- **Black screenshot**: the Shell probably crashed; the health check fails.
- **"Snapshot not found"**: `virsh -c qemu:///session snapshot-list <domain>`.
  If it is gone, destroy and recreate the VM.
- **Plain virsh**: `export LIBVIRT_DEFAULT_URI=qemu:///session` first.

## License

See [LICENSE](LICENSE).
