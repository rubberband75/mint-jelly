# Mint Jelly

Mint Jelly rebuilds a Linux Mint workstation after a clean installation. It
records software, selected application configuration, personal files, local
Git repositories, and explicit Cinnamon settings in atomic snapshot
generations on a local or SSH backup target.

The current configuration and snapshot formats are version 3. Older formats
are intentionally unsupported; Mint Jelly is pre-release software and favors
a clean design over migration code.

## Recovery model

Mint Jelly has four backup domains:

- `files`: arbitrary paths chosen by the user.
- `software`: configured APT packages, Flatpak applications, bundled
  installers, and known application configuration profiles.
- `repositories`: explicitly registered local Git repositories, including
  unpushed history and selected ignored local files.
- `system-settings`: narrow Cinnamon System Settings profiles.

`mint-jelly backup` and `mint-jelly restore` operate on all four domains.
Domain commands operate only on that domain. A scoped backup copies forward
the other domains from the current generation and atomically commits a new
generation, so a failed backup never replaces the last restorable snapshot.

A restore validates the snapshot, installs software, restores arbitrary files,
application data, and repositories, restores settings assets, and finally
applies GSettings values. Existing paths require confirmation; use `--force`
for an unattended replacement. `--yes` confirms the overall operation but does
not imply `--force`.

Hardware-bound settings restore automatically when the machine fingerprint
matches. On replacement hardware they are shown as skipped; use
`--include-hardware` after reviewing them.

## Commands

```text
mint-jelly config init
mint-jelly config remote add

mint-jelly files config
mint-jelly files add ~/Pictures/Wallpaper ~/.ssh
mint-jelly files remove ~/.ssh
mint-jelly files list
mint-jelly files list-remote
mint-jelly files backup
mint-jelly files restore [--yes] [--force]

mint-jelly repos add NAME PATH
mint-jelly repos remove NAME
mint-jelly repos include NAME RELATIVE_PATH...
mint-jelly repos exclude NAME RELATIVE_PATH...
mint-jelly repos uninclude NAME RELATIVE_PATH...
mint-jelly repos unexclude NAME RELATIVE_PATH...
mint-jelly repos list
mint-jelly repos list-remote
mint-jelly repos backup [NAME...]
mint-jelly repos restore [NAME...] [--yes] [--force]

mint-jelly software config
mint-jelly software list
mint-jelly software list-remote
mint-jelly software backup
mint-jelly software restore [--yes] [--force]
mint-jelly software install INSTALLER...
mint-jelly software update [INSTALLER...]
mint-jelly software uninstall INSTALLER... [--purge] [--yes]

mint-jelly system-settings config
mint-jelly system-settings list
mint-jelly system-settings list-remote
mint-jelly system-settings backup
mint-jelly system-settings restore [--yes] [--force]

mint-jelly backup
mint-jelly restore [--yes] [--force]
```

With no names, `software update` updates every configured bundled installer.
With names, only those configured installers are updated. `software uninstall`
removes each named installer from the recovery plan after successful removal.
Without `--purge`, its application configuration profile remains selected so
the configuration can still be backed up.

The `docker-engine` installer uses Docker's signed Ubuntu APT repository and
the Linux Mint installation's Ubuntu base codename. Docker does not officially
support Ubuntu derivatives such as Linux Mint, so this compatibility path is
verified by the installer but cannot be guaranteed by Docker. The installer
also adds the desktop user to the `docker` group so Docker can run without
`sudo`; that membership is root-equivalent and takes effect after logging out
and back in (or running `newgrp docker`).

APT and Flatpak selection retain focused management commands:

```text
mint-jelly apt install PACKAGE...
mint-jelly apt add PACKAGE...
mint-jelly apt remove PACKAGE...
mint-jelly apt config

mint-jelly flatpak install [--user|--system] REMOTE APP_ID...
mint-jelly flatpak add [--user|--system] REMOTE APP_ID...
mint-jelly flatpak remove APP_ID...
mint-jelly flatpak config
```

Their recovery plan and application data are backed up by `software backup`,
not separate APT or Flatpak snapshots.

## Git repositories

Repositories are a separate recovery domain rather than arbitrary `files`
paths. Each configured repository stores a sanitized bare mirror for reachable
Git objects and refs, a filtered copy of the current worktree, and inert
metadata describing HEAD, remotes, upstreams, and content checksums. The
original remote is never required during restore, so local branches, tags,
stashes, and unpushed commits remain recoverable.

The worktree copy contains every existing tracked file, ordinary untracked
files that Git does not ignore, and explicitly included ignored paths. It
always excludes `.git` administration data and excludes untracked
`node_modules` by default. Backup rules do not alter the repository's
`.gitignore`.

For example:

```bash
mint-jelly repos add solle-docker ~/Development/Solle/docker
mint-jelly repos include solle-docker .env .vscode
mint-jelly repos backup solle-docker
```

Include and exclude paths are literal repository-relative paths. An include
must exist during backup, which prevents a typo from silently omitting a secret
or other irreplaceable local file. Tracked files cannot be excluded. Dirty file
contents are preserved, but restored changes are deliberately unstaged.

Mint Jelly builds and validates repository mirrors locally and copies them to
the snapshot as inert data; it never executes Git on the backup host. Restore
downloads and verifies the artifact in a private temporary directory, builds a
complete replacement beside the destination, and only then moves it into
place. `--force` replaces an existing repository after successful staging; it
does not merge backup data into an existing checkout.

Repository backup currently refuses states it cannot promise to recover
completely, including active merge/rebase operations, shallow or partial
clones, sparse/linked worktrees, initialized submodules, and repositories with
uncaptured Git LFS data.

Ignored `.env` files commonly contain credentials. Snapshot permissions and
SSH protect access and transport, but snapshots are not encrypted at rest;
the backup destination must be treated as secret-bearing storage.

## Application data

Application configuration is declarative and separate from arbitrary files,
but is part of the software domain. Profiles associated with configured
software are selected automatically. The bundled catalog currently includes:

- DataGrip
- Discord
- Docker Engine CLI
- Firefox
- Google Cloud CLI
- Heroic Games Launcher
- MakeMKV
- Minecraft Launcher
- NVM/npm user configuration
- Postman
- Slack Desktop
- Visual Studio Code

Only configuration and durable state are captured. Caches and installed
application payloads are excluded. Firefox is an application profile; there is
no Firefox backup plugin. Docker's `~/.docker` CLI state is included, which can
contain registry credentials, so snapshot storage must be treated as sensitive.
Docker images, containers, volumes, `/var/lib/docker`, and `/var/lib/containerd`
are runtime data and are deliberately excluded.

The `vscode` installer follows Microsoft's desktop flow: it downloads the
current stable `.deb`, verifies Microsoft's published SHA-256 digest and Debian
metadata, pre-authorizes the package's signed APT repository setup, and installs
the package. Later `software update vscode` operations use that APT repository.
The application profile captures VS Code's `User` data and `argv.json`.
Installed extensions are deliberately excluded as application payloads; VS Code
Settings Sync remains the correct mechanism for reinstalling them.

## Cinnamon settings

`system-settings config` presents supported panels using the same concepts as
Cinnamon System Settings. Profiles own explicit schemas, keys, and assets.
For example, `desktop` records the `org.nemo.desktop` icon/layout values and
never includes `~/Desktop` or `~/.local/share/applications`. `themes` records
theme identities, dark-mode preference, and user theme/icon assets without
capturing unrelated interface settings.

Portable profiles include themes, backgrounds, effects, fonts, accessibility,
actions, applets, desklets, desktop, extensions, general, gestures, hot
corners, date/time presentation, keyboard, languages, night light,
notifications, preferred applications, privacy, screensaver, startup
applications, windows, and workspaces. Display, panel monitor placement,
mouse/touchpad, and power profiles are treated as hardware-bound.

Administrative panels such as Driver Manager, Disks, Firewall, Login Window,
Software Sources, System Administration, and Users and Groups are not portable
desktop preferences and are deliberately not presented as restorable profiles.

## Configuration

The configuration lives at
`${XDG_CONFIG_HOME:-~/.config}/mint-jelly/config.ini` and is parsed as inert
data, never sourced.

```ini
version=3
default_remote=nas
history_keep=5
file=~/.ssh
application=firefox
system_setting=themes
system_setting=desktop
apt_package=firefox
installer=postman
flatpak_app=user|flathub|com.discordapp.Discord|stable

[repository solle-docker]
path=~/Development/Solle/docker
include=.env
include=.vscode
exclude=node_modules

[remote nas]
type=ssh
host=backup.example.test
username=chandler
port=22
root_path=/srv/backups/mint-jelly
```

Snapshot data is stored below
`REMOTE_ROOT/HOSTNAME/.mint-jelly/snapshots/GENERATION`. The `current` file is
an atomic pointer to the committed generation. Remote content is data only;
Mint Jelly never executes code from a backup.

## Installation

From a source checkout:

```bash
./install.sh
```

The installer creates a versioned user installation and a `mint-jelly`
launcher under `~/.local/bin` by default. Run the test suite with:

```bash
bash tests/run.sh
```
