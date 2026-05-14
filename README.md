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

- macOS with Lima (`brew install lima`) and `nerdctl` available via Lima.
- Project lives anywhere on the host (each project gets its own VM that
  mounts only that directory).

## Model in one paragraph

**Each project gets its own Lima VM.** That VM mounts only the project's
directory and only that directory. `bin/sbx setup` (run from inside the
project) registers it: a VM named `sbx-<basename>-<8-hex-hash>` is created,
proxy and sandbox images are built, the proxy starts. Subsequent `bin/sbx
run`, `shell`, `status`, etc. find the right VM by matching `$PWD` against
the registered mounts (longest-prefix wins, so nested registrations work).
Multiple projects run in parallel — each has its own VM, networks, proxy,
and `/home/dev` cache.

## First-time setup (per project)

```sh
cd ~/code/myproject
/path/to/sbx/bin/sbx setup
```

This creates the project's Lima VM, builds the proxy and the fat sandbox
image (Rust, Go, Node, Python, Java, Ruby, plus the devbase-core CLI subset:
ripgrep, fzf, bat, eza, delta, fd, fish, kubectl), and starts the proxy. The
sandbox image is ~3 GB and takes a few minutes on first build; subsequent
projects reuse cached layers where possible.

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
cd ~/code/projA && sbx setup     # creates sbx-projA-<hash>
cd ~/code/projB && sbx setup     # creates sbx-projB-<hash>, runs in parallel

sbx status --all                 # list registered projects + VM names + state
sbx status                       # detail for the project owning $PWD
sbx reset                        # tear down the VM owning $PWD
sbx reset --all                  # wipe every sbx-* VM
```

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

This whole stack runs inside the project's own Lima VM. A separate project's
VM is a separate kernel, separate filesystem, separate proxy, separate
allowlist — full isolation between projects.

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

- **UID/GID 501:20** is hard-coded to macOS defaults. If your host UID is
  different (`id -u`/`id -g`), edit `sandbox/Dockerfile` and the `--user`
  flag in `bin/sbx`.
- **First setup per project is slow** — the sandbox image fetches rustup,
  node, go, etc. inside the new VM. Subsequent projects reuse buildkit
  layer cache where possible, but the cache is per-VM (one per project),
  so cold builds aren't free across projects.
- **AAAA queries** are dropped by dnsmasq so clients fall back to IPv4
  immediately instead of waiting for a timeout.
- **Container-in-sandbox not supported.** Podman/Docker are intentionally
  not in the sandbox image. If you need them, build a separate image.
- **`sbx reset` only nukes one project.** Use `sbx reset --all` to wipe
  every sbx VM if you want a complete reset.
