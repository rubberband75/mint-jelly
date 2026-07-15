# Mint Jelly

> A tool to preserve your Linux Mint setup

Mint Jelly maintains a recovery mirror of selected absolute paths and a
declarative software plan on either an SSH server or a local filesystem. Each
computer is stored beneath its hostname:

```text
<remote root>/<hostname>/<absolute source path>
```

For example, `/home/alex/.ssh` on `DESKTOP` can be stored at:

```text
/srv/backups/DESKTOP/home/alex/.ssh
```

Mint Jelly is currently tested on Linux Mint 22.3 with Cinnamon 6.6.7. The
core backup commands may work elsewhere, but other distributions and desktop
versions are not yet supported targets.

Runtime requirements are Bash 4 or newer, `rsync`, OpenSSH, `dconf`, `pgrep`,
`flock`, and standard GNU userland tools. SSH backup servers must provide `sh`,
`find`, `flock`, `head`, `mktemp`, `rsync`, and `wc`; remote add/test verifies
lock support before the remote is accepted. The installer validates local
requirements and reports missing commands; it never invokes `sudo` or installs
system packages.

## Installation

From a local source checkout, run:

```bash
./install.sh
```

This installs the application without `sudo` under:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/mint-jelly
```

It creates the `~/.local/bin/mint-jelly` command and installs lazy Bash
completion under the user's XDG data directory. It does not modify `.bashrc`,
`.profile`, the Mint Jelly configuration, or the Mint Jelly state directory.
On a standard Linux Mint account, `~/.profile` already adds `~/.local/bin` to
`PATH`. If it is not active in the current shell, the installer prints the
command needed to start a new login shell.

Once tagged release archives are published, the same installer supports:

```bash
curl -fsSL https://raw.githubusercontent.com/rubberband75/mint-jelly/v0.0.2/install.sh | bash
```

Remote installation downloads the matching `mint-jelly-v0.0.2.tar.gz` release
asset and verifies its published SHA-256 file before installing. Until those
release assets exist, use the local source installation above.

Re-running the installer safely replaces the same application version without
touching user data. Each update is activated atomically, and the immediately
previous deployment is retained as a rollback copy. To remove the application
while preserving configuration and state, run:

```bash
mint-jelly uninstall
```

To remove the application and all Mint Jelly configuration and state:

```bash
mint-jelly uninstall --purge
```

## First backup

Initialize the configuration and add the first remote:

```bash
mint-jelly config init
```

The remote wizard requires a name and root path; SSH remotes also require a
hostname. Its generic defaults are:

- Type: `ssh`
- Username: the current user
- Port: `22`

`mint-jelly backup` never creates configuration. If it or another configuration
command is run before initialization, it prints the required first-run
command and exits.

OpenSSH handles host verification and password prompts. Passwords are never
read or saved by these scripts.

The `firefox` backup plugin discovers existing profile roots for XDG/Mint,
traditional, Snap, and Flatpak Firefox installations. When Firefox is open in
an interactive terminal, it offers to skip Firefox safely, copy the live
profile with an explicit consistency warning, or pause while the user closes
Firefox and then recheck. Non-interactive backups always choose the safe skip.
When skipped, the last successful remote Firefox copy remains part of the
recovery manifest if available. If no previous copy exists, Firefox remains
omitted until a later backup copies it. Firefox caches are intentionally
excluded.

The `cinnamon-desktop` backup plugin captures the state needed to reproduce panels,
applets, and desktop icons:

- `/org/cinnamon/` and `/org/nemo/desktop/` are exported from dconf.
- Per-applet settings under `~/.config/cinnamon`.
- Installed user Cinnamon spices under `~/.local/share/cinnamon`.
- Nemo icon positions under `~/.config/nemo`.
- Cinnamon monitor topology from `~/.config/cinnamon-monitors.xml`.
- User application launchers and the XDG Desktop directory.

The portable dconf exports are stored under
`${XDG_STATE_HOME:-$HOME/.local/state}/mint-jelly` and included in the
backup. The binary dconf database is intentionally not copied.

## Commands

```bash
mint-jelly backup
mint-jelly backup --remote NAME
mint-jelly backup --dry-run

mint-jelly restore --dry-run
mint-jelly restore
mint-jelly restore --remote NAME --source-host HOSTNAME
mint-jelly restore --allow-platform-mismatch

mint-jelly software show
mint-jelly software install
mint-jelly software install --apt-only --dry-run
mint-jelly software install --installers-only
mint-jelly software install --yes --allow-weak-verification

mint-jelly config init
mint-jelly config remote add
mint-jelly config remote list
mint-jelly config remote set-default NAME
mint-jelly config remote test NAME
mint-jelly config backup-plugins
mint-jelly config apt list
mint-jelly config apt add git vlc
mint-jelly config apt remove vlc
mint-jelly config apt select
mint-jelly config apt select --show-all
mint-jelly config installers

mint-jelly version
```

Backup `--dry-run` prevents `rsync` from transferring or deleting files.
Connection validation and destination directory creation still occur.

Restore `--dry-run` connects to the selected remote and shows the files that
would be restored without changing files or applying desktop settings. A real
restore asks for confirmation; use `--yes` only when explicit non-interactive
confirmation is required. Restore requires the recorded Linux Mint release,
Ubuntu base, and architecture to match the current machine. The explicit
`--allow-platform-mismatch` override is available for an intentional
cross-platform recovery, but settings and desktop data may be incompatible.

## Configuration

The configuration is stored at:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/mint-jelly/backup.conf
```

It is parsed as data, not executed as Bash. An example with SSH and local
remotes is:

```ini
version=1
default_remote=personal-server
history_keep=5
source=~/.ssh
backup_plugin=firefox
backup_plugin=cinnamon-desktop
apt_package=git
apt_package=vlc
installer=postman
installer=google-cloud-cli
installer_option=google-cloud-cli:kubectl

[remote personal-server]
type=ssh
host=backup.example.com
username=alex
port=22
root_path=/srv/backups

[remote external-drive]
type=local
root_path=/mnt/external/Backups
```

The configuration directory is mode `0700`, and the configuration file is
mode `0600`.

Repeat `source=` for paths that are known in advance. Sources can use an
absolute path or a leading `~/`, which is expanded without executing the
configuration as shell code. Repeat `backup_plugin=` for sources that require
runtime discovery or restore hooks. Repeat `apt_package=` and `installer=` for
software that should be present after recovery. Installer-specific selections
use `installer_option=INSTALLER:OPTION`; these are written by the installer
picker and must belong to a selected bundled installer.

Use `mint-jelly config backup-plugins`, `mint-jelly config apt select`, and
`mint-jelly config installers` to edit selections with an interactive checkbox
picker. Existing selections are checked when a picker opens; cancelling leaves
the configuration unchanged. APT packages can also be managed explicitly with
`config apt add`, `remove`, and `list`.

By default, `config apt select` shows packages marked as manual after Linux
Mint's initial installation snapshot. This removes the distribution's original
package set from the selector while retaining configured packages that are not
currently installed. `config apt select --show-all` includes every installed
APT package, including automatically installed dependencies and system
packages. If the installation snapshot is unavailable, Mint Jelly warns and
falls back to all manually marked packages because APT does not retain exact
human-install provenance.

These commands change only the local configuration. APT-package and installer
selection changes reach a remote recovery manifest only after the next
successful `mint-jelly backup`; run a new backup before relying on the updated
software plan during recovery.

Bundled backup plugins are:

- `firefox`: discovers Firefox profile roots, or safely skips them when the
  browser is running.
- `cinnamon-desktop`: exports dconf and discovers Cinnamon, Nemo, applet,
  launcher, monitor, and Desktop state.

The backup defaults live in `backup.conf.default`; the backup engine contains
no built-in source or backup-plugin list.

## Software recovery

Mint Jelly stores package names and installer IDs, not downloaded packages or
remote executable code. A successful backup commits them with the source list
and platform identity in:

```text
<remote root>/<hostname>/.mint-jelly/recovery.manifest
```

Inspect the saved plan before changing the system:

```bash
mint-jelly software show --remote NAME --source-host HOSTNAME
```

Install missing software explicitly:

```bash
mint-jelly software install --remote NAME --source-host HOSTNAME
```

Software installation is deliberately separate from file restore because it
uses the network and may invoke narrowly scoped `sudo` commands. On a fresh
machine, install software first and restore files second so application
installers cannot replace restored settings with new defaults.

Ordinary packages from already configured repositories are installed in one
noninteractive APT transaction that preserves existing configuration files;
Mint Jelly never supplies affirmative answers to license prompts, so a package
that requires an interactive license decision may fail. Special installers are
bundled trusted modules under `installers/`; the remote manifest may select
their IDs but can never supply code. Every installer performs a local read-only
check, skips applications that are already present, installs sequentially, and
verifies its result.
Independent failures are logged and summarized without hiding a nonzero final
status. `--dry-run` performs no package download, `sudo`, or installation.

Bundled installers are `datagrip`, `discord`, `google-cloud-cli`, `heroic`,
`minecraft-launcher`, `postman`, and `slack`. Several vendors do not publish
checksums for their download endpoints; Mint Jelly displays an explicit warning
when verification is limited to HTTPS plus package metadata or archive-layout
validation.
Interactive confirmation acknowledges that warning. An unattended `--yes` run
must also include `--allow-weak-verification` before any affected installer can
run. DataGrip and Heroic fail closed unless their release metadata contains a
valid SHA-256 digest. DataGrip is installed from JetBrains' official standalone
Linux bundle under `/opt`, with a stable `datagrip` command and Cinnamon menu
entry. DataGrip handles license or trial activation on first launch.

The Google Cloud CLI installer follows Google's Debian/Ubuntu repository
procedure from the [official installation guide](https://docs.cloud.google.com/sdk/docs/install-sdk#deb):
it downloads and validates the current Artifact Registry signing
key, installs it at `/usr/share/keyrings/cloud.google.gpg`, creates a single
APT source restricted with `signed-by`, and installs `google-cloud-cli` plus
the optional packages selected on the second installer-configuration screen.
The first time this installer is selected, optional packages already installed
locally are checked automatically; later visits preserve the explicit saved
selection.

## Restore behavior

`mint-jelly restore` restores the current mirror for a source hostname to its original
absolute paths. The source hostname defaults to the current hostname and can
be selected with `--source-host`. This supports restoring a backup after a
reinstallation as well as retrieving another named computer's mirror when
that is intentional.

Each backup invalidates the previous recovery manifest before transferring
data and writes a new protected manifest only after every source succeeds.
Restore therefore refuses interrupted or partially updated mirrors. It uses
the remote snapshot— including its backup-plugin IDs—rather than the new
machine's local selections, validates every absolute path, and verifies that
every listed source still exists before copying anything. This also prevents
synthetic mirror-directory permissions from being applied to system parent
directories. Backups created before the unified recovery manifest must be run
again before they can be restored or provisioned with this version.

Backups hold an exclusive advisory `flock` on the selected hostname mirror.
Restore and software-plan reads hold a shared lock, so cooperating Mint Jelly
clients cannot read a mirror while it is being updated or interleave two
backups. Locks are kernel-managed file locks and are released automatically if
a process or SSH session exits; no stale lock directory needs manual cleanup.
SSH operations verify the live lock holder with a bounded round-trip before
every protected operation and again before reporting success. Lock acquisition
or a lost lock channel fails closed rather than operating without one.
Recovery manifests are also bounded to 1 MiB, 4096-byte lines, and conservative
per-entry counts before parsing.

The complete set of sources from the newest successful backup is restored,
even if the local source selection has changed since then. Historical version
selection is not implemented yet. Restore does not delete local files that
are absent from a backed directory, but existing files at matching paths can
be overwritten.

The backup plugins recorded in the recovery manifest provide restore safety
and post-processing:

- `firefox` requires Firefox to be completely closed before a real restore.
- `cinnamon-desktop` verifies that the selected backup contains its portable
  dconf exports, then loads the restored Cinnamon and Nemo settings after the
  files have been copied.

The configuration must exist locally before restore so Mint Jelly knows how
to reach the remote. Run restore as the user whose files are being recovered.
Paths that user cannot write will cause the restore to fail rather than being
silently skipped.

## Backup safety

The configured remote root may itself resolve through an intentional symlink,
but each hostname mirror and every directory component below it must be a real
directory. Mint Jelly refuses symlinked destination components instead of
allowing `mkdir`, `rsync`, history cleanup, or manifest publication to escape
the selected mirror. A symlink that is itself the final backed source remains
valid and is copied as a symlink; it is never followed as a destination
directory.

Each source is synchronized independently. Removed and overwritten destination
files are moved beneath this run-specific directory before replacement:

```text
<remote root>/<hostname>/.history/<UTC timestamp>/
```

`history_keep` controls how many non-empty history generations are retained;
its default is `5`. After a complete successful backup, empty history
directories are removed depth-first and the oldest timestamp generations over
the limit are deleted. A value of `0` disables retention by deleting all
history generations after each successful backup. Once the mirror and manifest
are committed, a retention-cleanup error is reported as a warning and does not
misreport the completed backup as failed. Dry runs and failed backups never
prune history.

The mirror is not encrypted by these scripts. In particular, backing up
`~/.ssh` copies private keys verbatim. The destination server and its storage
must be access-controlled and encrypted at rest. Use client-side encrypted
backup storage instead if the server cannot meet that requirement.
