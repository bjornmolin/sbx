# sbx

A small wrapper that runs arbitrary CLI tools (Claude Code, OpenCode, `cargo`,
`npm`, …) inside a **rootless Lima/containerd sandbox** with **hostname-based
egress filtering**.

The goal: let an AI coding agent loose on a project directory without giving
it the ability to `rm -rf ~`, exfiltrate secrets, or download arbitrary
binaries from the internet.

## Threat model

Stops:

- An agent or tool deleting / overwriting files outside the mounted project.
- An agent reaching hosts that are not on the allowlist (no DNS escape — DNS
  is captive; no IP escape — the sandbox network has no route to the world).
- Most resource-exhaustion mistakes (filesystem isolated, container can be
  killed).

Does **not** stop:

- A determined attacker who controls an *allowed* host (TLS is not
  intercepted — the proxy decides on hostname only and forwards bytes).
- An agent that intentionally writes malicious code into the project. This
  is a sandbox for execution, not a code-review tool.

## Prerequisites

- **macOS:** Lima (`brew install lima`) and `jq` (`brew install jq`).
- **Linux:** rootless containerd + nerdctl (`containerd-rootless-setuptool.sh
  install`) and `jq` (`apt install jq` / equivalent).

## Model in one paragraph

**One container runtime, many projects in parallel.** On macOS a single
shared Lima VM (`sbx`) with `$HOME` mounted hosts containerd; it's created
once and never restarted when adding projects. On Linux the wrapper talks
to rootless containerd directly with no VM layer. Per project: its own
`--internal` nerdctl network, its own proxy container (with the project's
allowlist bind-mounted in), and its own `/home/dev` cache volume. All
projects share one proxy image and one sandbox image. Discovery is by
longest-prefix match of `$PWD` against registered project paths. State of
record: `~/.config/sbx/projects.json`.

## First-time setup

The very first `sbx setup` does the slow work once:

- macOS only: creates the shared Lima VM (`sbx`) and starts it.
- Builds the shared proxy + sandbox images. The sandbox image is ~3 GB
  (Rust, Go, Node, Python, Java, Ruby, plus the devbase-core CLI subset:
  ripgrep, fzf, bat, eza, delta, fd, fish, kubectl) and takes a few
  minutes on first build.
- Creates the project's internal network and starts its proxy.

```sh
cd ~/code/myproject
/path/to/sbx/bin/sbx setup
```

**Subsequent projects** skip the VM creation and the image builds; setup
is essentially instant (one nerdctl network + one proxy container).

Tip: put `sbx` on your PATH (`ln -s /path/to/sbx/bin/sbx ~/.local/bin/sbx`)
so you can run `sbx setup` from anywhere.

## Daily use

```sh
cd ~/code/myproject              # any subdir works
sbx run -- rustc --version
sbx run -- cargo build
sbx run -- npm install
sbx run -- claude                # or whatever agent CLI you have installed
sbx shell                        # interactive fish shell in the sandbox
```

Each run gets a fresh container. Your **project root is bind-mounted at
`/work`** and the container's cwd matches `$PWD` (so `cd src && sbx run --
cargo test` runs `cargo test` from `/work/src`). Writes land on the host
with your real UID/GID (501:20). A per-VM named volume `sbx-home` holds
`/home/dev`, so caches (`~/.cargo`, `~/.npm`, `~/.cache`) survive between
runs but never leak across projects.

## Multiple projects

```sh
cd ~/dev/projA && sbx setup      # registers projA, starts its proxy
cd ~/dev/projB && sbx setup      # registers projB, runs in parallel
                                 #   no new VM, no image rebuild

sbx status --all                 # list every registered project + state
sbx status                       # detail for the project owning $PWD
sbx reset                        # tear down only the project owning $PWD
sbx reset --all                  # tear down every project
                                 #   (the shared Lima VM stays — remove with
                                 #    'limactl delete sbx' if you want it gone)
sbx prune                        # drop registry entries with no proxy container
```

## Configured mount dirs (macOS only)

The Lima VM only sees host directories listed in `~/.config/sbx/config.json`
under `mount_dirs`. Default: `["~/dev"]`. This keeps `~/.ssh`, `~/.aws`,
`~/.gnupg`, browser cookies and the like out of the VM entirely — they are
not reachable even from a compromised proxy or a runc escape into the VM.
Sandbox containers themselves never see anything outside `/work` regardless.

```sh
sbx mounts                       # list configured mount dirs
sbx add-mount ~/code             # allow Lima to mount ~/code too
                                 #   (restarts the shared VM; every project's
                                 #    proxy is interrupted; prompts before doing it)
```

`sbx setup` refuses to register a project that isn't inside one of the
configured mount dirs. The error message points at `add-mount`.

On Linux there's no Lima layer; the file is ignored.

## Egress allowlist

Two files, concatenated at proxy-build time:

- **`<sbx-repo>/allowlist.conf`** — curated baseline (npm, pypi, crates,
  github, …). Edit only when adding something every project should be able
  to reach.
- **`<your-project>/.sbx/allowlist.local.conf`** — per-project additions.
  Lives in the project alongside the code it gates egress for, the same way
  `.git`, `.vscode`, and `.devcontainer` do. The proxy picks it up
  automatically on the next build.

Format: one hostname per line, `*.example.com` for any subdomain. Lines
starting with `#` are comments.

```sh
# in your project:
mkdir -p .sbx
echo my-internal-api.example.com >> .sbx/allowlist.local.conf
sbx build-proxy                  # rebuild + restart the proxy for this project
```

Tail decisions with:

```sh
sbx logs
```

You'll see each DNS query and each SNI verdict (`-> 1.2.3.4:443` = forwarded,
`-> NONE` = dropped).

## Architecture in 30 seconds

```
  ┌────────────────────────────┐         ┌──────────────────────────┐
  │ sandbox container          │         │ proxy container          │
  │  - user 501:20             │  TCP/443│  - sniproxy              │
  │  - /work = project root    ├────────►│    reads SNI, allowlist  │
  │  - /home/dev = named vol   │  UDP/53 │  - dnsmasq               │
  │  - DNS = proxy IP          ├────────►│    answers proxy IP for  │
  │  - on --internal network   │         │    every name            │
  └────────────────────────────┘         │  - on external network   │
                                         │    to reach real hosts   │
                                         └──────────────────────────┘
```

- Sandbox lives on a nerdctl `--internal` network — no route to the world.
- DNS for the sandbox points at the proxy. The proxy's dnsmasq returns the
  proxy's own IP for every query, so any hostname the sandbox tries to reach
  becomes a connection to the proxy.
- The proxy reads the SNI from the TLS handshake. If the hostname is on the
  allowlist, sniproxy forwards bytes to the real host (resolved via real
  DNS on the external bridge). If not, the connection is dropped.
- No TLS interception, no custom CA in the sandbox. Hostname is the only
  decision point.

On macOS the whole stack runs inside the shared Lima VM. On Linux it runs
directly on the host via rootless containerd. Either way, projects are
isolated from each other by **separate networks** (each project on its own
`--internal` bridge), **separate filesystems** (each project bind-mounts
only its own directory), **separate proxies** (each with its own allowlist),
and **separate cache volumes**. Projects do **share a kernel** — the Lima
VM's kernel on macOS, or the host kernel on Linux — so a kernel-level
container escape from one project could in principle reach the others.
Network/filesystem/allowlist boundaries hold against the threat models sbx
actually targets (agent misbehaviour, accidental egress, unintended writes).

## File map

### The sbx tool repo

```
allowlist.conf          # the curated baseline allowlist
bin/sbx                 # the wrapper CLI
lima/sandbox.yaml       # Lima VM template (Ubuntu 24.04, VZ, rootless containerd)
proxy/                  # proxy image source (alpine + sniproxy + dnsmasq)
sandbox/                # sandbox image source (ubuntu 24.04 + every toolchain)
```

### Inside one of your projects

```
.sbx/
  allowlist.local.conf  # project-specific hosts (committable, or .gitignore'd)
```

## Notes & gotchas

- **UID/GID auto-detect.** `bin/sbx` reads `id -u`/`id -g` at startup and
  passes them to `nerdctl build` (as `USER_UID`/`USER_GID` build args) and
  `nerdctl run` (as `--user`). The sandbox image handles UID/GID
  collisions (e.g. GID 20 = `dialout` on macOS hosts, UID 1000 = default
  `ubuntu` user on some cloud images).
- **First setup is slow, subsequent ones are instant.** The fat sandbox
  image is ~3 GB and only built once; new projects just add a network and
  a proxy container.
- **AAAA queries** are dropped by dnsmasq so clients fall back to IPv4
  immediately instead of waiting for a timeout.
- **Container-in-sandbox not supported.** Podman/Docker are intentionally
  not in the sandbox image. If you need them, build a separate image.
- **`sbx reset` only nukes one project.** Use `sbx reset --all` to tear
  down every project. The shared Lima VM stays — `limactl delete sbx` if
  you want it removed entirely.
- **Linux requires rootless containerd.** Set up with
  `containerd-rootless-setuptool.sh install`. `sbx` will tell you if
  `nerdctl` can't reach a containerd.
