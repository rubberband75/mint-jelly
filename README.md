# Mint Jelly

> Preserve and rebuild a Linux Mint workstation.

Mint Jelly maintains local desired-state lists for files, bundled application
installers, APT packages, and Flatpak applications. Local configuration works
without a backup mirror. A local or SSH remote is required only when a command
actually reads or writes remote state.

Mint Jelly is currently tested on Linux Mint 22.3 with Cinnamon 6.6.7. File
backup and restore require Bash 4 or newer, `rsync`, OpenSSH, `flock`, `dconf`,
and standard GNU userland tools. APT, Flatpak, and bundled installer commands
require their corresponding system tools only when used.

## Installation

From a source checkout:

```bash
./install.sh
```

The application is installed without `sudo` under:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/mint-jelly
```

The installer creates `~/.local/bin/mint-jelly` and installs lazy Bash
completion under the user's XDG data directory. It does not modify shell startup
files, application configuration, or application state.

Release installation is also supported when the matching GitHub release asset
and SHA-256 file have been published:

```bash
curl -fsSL https://raw.githubusercontent.com/rubberband75/mint-jelly/v0.0.2/install.sh | bash
```

Uninstall the application while retaining configuration and state:

```bash
mint-jelly uninstall
```

Remove the application, configuration, and state:

```bash
mint-jelly uninstall --purge
```

## Local-first configuration

Initialize local configuration without defining a remote:

```bash
mint-jelly config init
```

Mutating local commands such as `software install`, `apt install`, and
`flatpak install` also initialize the configuration when it does not exist.
The configuration is stored at:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/mint-jelly/config.ini
```

Its format remains `version=1` and is parsed as inert data rather than sourced
as Bash. A complete example is:

```ini
version=1
default_remote=personal-server
history_keep=5

source=~/.ssh
backup_plugin=firefox
backup_plugin=cinnamon-desktop

installer=postman
installer=google-cloud-cli
installer_option=google-cloud-cli:kubectl

apt_package=git
apt_package=vlc

flatpak_app=user|flathub|com.makemkv.MakeMKV|stable

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

The configuration may contain no remotes, no file sources, or empty software
lists. The directory is mode `0700`; the file is written atomically with mode
`0600`. Concurrent Mint Jelly operations share a local advisory lock so a
backup cannot snapshot a half-written desired state.

## Commands

### Bundled software installers

Install a bundled application and track it only after its local verification
succeeds:

```bash
mint-jelly software install postman
mint-jelly software install postman datagrip
```

Manage and inspect the local installer list:

```bash
mint-jelly software list
mint-jelly software config
```

Back up, inspect, and restore only the bundled-installer plan:

```bash
mint-jelly software backup [--remote NAME]
mint-jelly software list-remote [--remote NAME] [--source-host HOSTNAME]
mint-jelly software restore [--remote NAME] [--source-host HOSTNAME]
    [--dry-run] [--yes] [--allow-platform-mismatch]
    [--allow-weak-verification]
```

`software install` completes all installer IDs bundled with the active Mint
Jelly release. Remote manifests can select those trusted IDs and options but
can never supply executable code.

### APT packages

Install packages using `sudo apt-get install`, then track them after APT returns
success and `dpkg-query` confirms them:

```bash
mint-jelly apt install inkscape
mint-jelly apt install --yes git vlc
```

Direct installation does not silently refresh package indexes or assume yes.
The `--yes` flag is passed only when explicitly supplied.

Manage the desired-state list without changing installed packages:

```bash
mint-jelly apt list
mint-jelly apt add git vlc
mint-jelly apt remove vlc
mint-jelly apt config
mint-jelly apt config --show-all
```

`apt remove` only stops tracking a package; it never invokes `apt-get remove`.
By default, the checkbox selector hides packages from Mint's initial
installation snapshot and shows manually selected packages. `--show-all`
includes every installed package, including dependencies and system packages.

Back up and restore the APT plan independently:

```bash
mint-jelly apt backup [--remote NAME]
mint-jelly apt list-remote [--remote NAME] [--source-host HOSTNAME]
mint-jelly apt restore [--remote NAME] [--source-host HOSTNAME]
    [--dry-run] [--yes] [--allow-platform-mismatch]
```

APT package completion uses the system Bash-completion APT package function
when available and falls back to `apt-cache --no-generate pkgnames`.

### Flatpak applications

Install into the per-user Flatpak installation by default and record the
canonical scope, origin, application ID, and branch:

```bash
mint-jelly flatpak install flathub com.makemkv.MakeMKV
mint-jelly flatpak install --system flathub com.makemkv.MakeMKV
```

Manage applications without tracking runtimes or automatically installed
dependencies:

```bash
mint-jelly flatpak list
mint-jelly flatpak add flathub com.makemkv.MakeMKV
mint-jelly flatpak remove com.makemkv.MakeMKV
mint-jelly flatpak config
```

`flatpak add` resolves the remote's canonical ref but does not install it.
`flatpak remove` only stops tracking it; it never uninstalls the application.

Back up and restore the Flatpak plan independently:

```bash
mint-jelly flatpak backup [--remote NAME]
mint-jelly flatpak list-remote [--remote NAME] [--source-host HOSTNAME]
mint-jelly flatpak restore [--remote NAME] [--source-host HOSTNAME]
    [--dry-run] [--yes] [--allow-platform-mismatch]
```

### File and desktop data

Top-level backup and restore remain limited to configured files and desktop
backup plugins. Restore never installs software implicitly.

```bash
mint-jelly backup [--remote NAME] [--dry-run]
mint-jelly restore [--remote NAME] [--source-host HOSTNAME]
    [--dry-run] [--yes] [--allow-platform-mismatch]
```

Repeat `source=` for known paths. Sources must be absolute or begin with `~/`.
Use the interactive plugin selector for dynamically discovered state:

```bash
mint-jelly config backup-plugins
```

Bundled backup plugins are:

- `firefox`, which discovers traditional, XDG, Snap, and Flatpak Firefox
  profile roots and refuses an unsafe live restore.
- `cinnamon-desktop`, which captures portable Cinnamon and Nemo dconf data,
  applets, launchers, monitor layout, and desktop icon state.

The defaults used for newly initialized configuration remain in
`backup.conf.default`; the backup engine contains no built-in source list.

## Remotes

Add and manage remotes separately from local desired state:

```bash
mint-jelly config remote add
mint-jelly config remote list
mint-jelly config remote set-default NAME
mint-jelly config remote test NAME
```

Backup, restore, and `list-remote` require either `--remote NAME` or a configured
default. A local-only configuration remains valid until one of those commands
is invoked.

Each hostname has independent, protected manifests:

```text
<remote root>/<hostname>/.mint-jelly/files.manifest
<remote root>/<hostname>/.mint-jelly/software.manifest
<remote root>/<hostname>/.mint-jelly/apt.manifest
<remote root>/<hostname>/.mint-jelly/flatpak.manifest
```

Scoped manifests include the source host, creation time, platform, and only the
entries for their domain. Empty manifests are valid and intentionally clear a
remote desired-state list. They are bounded to 1 MiB, 4096-byte lines, and
conservative entry counts before parsing.

Backups hold an exclusive advisory lock on the hostname mirror. Restore and
`list-remote` hold a shared lock. SSH operations verify the live lock channel
before protected operations and fail closed if it is lost.

## Restore semantics

Every scoped restore first reads and validates the remote plan, displays it,
checks platform compatibility, and requests confirmation. `--dry-run` changes
neither the machine nor local configuration.

A real software-domain restore replaces that category in local configuration
with the remote desired state before installing missing entries. If an
installation later fails, the desired entry remains configured so rerunning the
restore can retry it. Other configuration categories are untouched.

Install software before restoring application settings on a fresh machine so
an installer cannot replace freshly restored settings with new defaults.

## Bundled installer security

Bundled installers are `datagrip`, `discord`, `google-cloud-cli`, `heroic`,
`minecraft-launcher`, `nvm`, `postman`, and `slack`. Every installer supplies a
read-only presence check, an installation action, and post-install verification.

Several vendors do not publish checksums for their download endpoints. Mint
Jelly warns when verification is limited to HTTPS plus package metadata,
source-commit pinning, or archive validation. Non-interactive execution of an
affected installer requires `--allow-weak-verification`.

DataGrip and Heroic fail closed unless release metadata contains a valid
SHA-256 digest. The Google Cloud CLI installer validates Google's signing key
and uses a `signed-by` APT source. NVM resolves a release tag to a specific Git
commit and validates the bounded upstream install script before running it.

## Backup safety

The configured remote root may resolve through an intentional symlink, but each
hostname mirror and directory beneath it must be a real directory. Mint Jelly
refuses symlinked destination components rather than allowing `mkdir`, `rsync`,
history cleanup, or manifest publication to escape the mirror.

Removed and overwritten destination files are moved beneath:

```text
<remote root>/<hostname>/.history/<UTC timestamp>/
```

`history_keep` controls retained non-empty generations and defaults to `5`.
Dry runs and failed backups never prune history.

The mirror is not encrypted by Mint Jelly. Backing up `~/.ssh` copies private
keys verbatim; remote storage must be access-controlled and encrypted at rest.
