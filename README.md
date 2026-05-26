<p align="center">
  <img width="424" height="281" alt="Keygen" src=".github/assets/logo.png" />
</p>

Keygen is a small Bash utility for generating application secrets, API keys, memorable passwords, UUIDs, and common framework secret formats from the command line.

It uses `/dev/urandom` for built-in character generation and delegates the framework-style shortcuts to `openssl rand` so their output matches the standard commands administrators already use.

### Features

- Random tokens from configurable character sets
- Memorable passphrases backed by a local, installed, cached, or remote wordlist
- UUID v4 generation
- Hex, base64, base64url, base32, base58, and nanoid-style tokens
- One-shot shortcuts for JWT secrets, app keys, Django secrets, and URL-safe secrets
- Version checks, self-update, and system install commands


### Installation

From the repository root:

```sh
./keygen.sh --install
```

By default this installs:

- Binary: `/usr/local/bin/keygen`
- Shared data: `/usr/local/share/keygen`
- Config: `/usr/local/share/keygen/config/keygen.conf`
- Wordlists: `/usr/local/share/keygen/wordlist`

Use `PREFIX` to install somewhere else:

```sh
PREFIX="$HOME/.local" ./keygen.sh --install
```

The installer creates the config file and bundled wordlist only when they do not already exist, so local user settings and custom wordlists are preserved across updates.

### Configuration

The installed config file is a shell-style file:

```sh
# /usr/local/share/keygen/config/keygen.conf
KEYGEN_MIN_WORD_LEN=3
KEYGEN_WORDLIST_TIMEOUT=5
```

Environment variables still work for one-off overrides:

```sh
KEYGEN_MIN_WORD_LEN=5 keygen --type memorable
```

Memorable mode resolves wordlists in this order:

1. `KEYGEN_WORDLIST_PATH`, if set
2. Installed wordlist under `/usr/local/share/keygen/wordlist`
3. Bundled repository wordlist under `wordlist/en-memorable.txt`
4. Cached wordlist under `${XDG_CACHE_HOME:-$HOME/.cache}/keygen/wordlist.txt`
5. Built-in fallback words

If no usable local wordlist is found, `keygen` attempts to download the project wordlist and cache it.

**Updates and version checks:**

```sh
keygen --version # Prints the local version and checks the upstream repository for updates.
keygen --update  # Downloads the latest stable version.
                 # This only updates the script and metadata only; it does not overwrite the installed user config or wordlists.
```

Patch versions are bumped automatically on pushes to main branch that change core runtime files only.

### Usage

```sh
keygen [options]
keygen jwt
keygen secret
keygen appkey
keygen django
keygen --safe
```

Run `keygen --help` for the full command reference.

<details>
  <summary><b>Examples</b></summary>

```sh
keygen
keygen --length 24 --allow letters,numbers,symbols
keygen --type memorable --words 4 --case capitalize --separator hyphen
keygen --type uuid --count 3
keygen --type base64url --length 32 --plain
keygen jwt
keygen --safe
```

### Special Commands

| Command | Equivalent command |
| --- | --- |
| `keygen jwt` | `openssl rand -hex 32` |
| `keygen secret` | `openssl rand -hex 32` |
| `keygen appkey` | `openssl rand -base64 32` |
| `keygen django` | `openssl rand -base64 50 \| tr -dc 'A-Za-z0-9!@#$%^&*(-_=+)'` |
| `keygen --safe` | `openssl rand -base64 32 \| tr '+/' '-_' \| tr -d '='` |
</details>

<details>
  <summary><b>FAQ</b></summary>

  1. Why `keygen -t hex -l 32` differs from `openssl rand -hex 32`? \
    - `keygen -t hex -l 32 -c lower` generates 32 hex characters. \
    - `openssl rand -hex 32` generates 32 random bytes and prints them as hex. Each byte becomes two hex characters, so the output is 64 hex characters.

  Use `keygen jwt` or `keygen secret` when you want the exact `openssl rand -hex 32` behavior.
</details>

## License

MIT. See [LICENSE](LICENSE).
