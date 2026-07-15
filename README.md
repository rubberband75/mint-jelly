# Mint Jelly

Mint Jelly rebuilds a Linux Mint workstation after a clean installation. It
records software, selected application configuration, personal files, and
explicit Cinnamon settings in atomic snapshot generations on a local or SSH
backup target.

The current configuration and snapshot formats are version 2. Version 1 data
is intentionally unsupported; Mint Jelly is pre-release software and favors a
clean design over migration code.

## Recovery model

Mint Jelly has three backup domains:

- `files`: arbitrary paths chosen by the user.
- `software`: configured APT packages, Flatpak applications, bundled
  installers, and known application configuration profiles.
- `system-settings`: narrow Cinnamon System Settings profiles.

`mint-jelly backup` and `mint-jelly restore` operate on all three domains.
Domain commands operate only on that domain. A scoped backup copies forward
the other domains from the current generation and atomically commits a new
generation, so a failed backup never replaces the last restorable snapshot.

A restore validates the snapshot, installs software, restores arbitrary files
and application data, restores settings assets, and finally applies GSettings
values. Existing file or application configuration paths require confirmation;
use `--force` for an unattended overwrite. `--yes` confirms the overall
operation but does not imply `--force`.

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

Only configuration and durable state are captured. Caches and installed
application payloads are excluded. Firefox is an application profile; there is
no Firefox backup plugin. Docker's `~/.docker` CLI state is included, which can
contain registry credentials, so snapshot storage must be treated as sensitive.
Docker images, containers, volumes, `/var/lib/docker`, and `/var/lib/containerd`
are runtime data and are deliberately excluded.

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
version=2
default_remote=nas
history_keep=5
file=~/.ssh
application=firefox
system_setting=themes
system_setting=desktop
apt_package=firefox
installer=postman
flatpak_app=user|flathub|com.discordapp.Discord|stable

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
