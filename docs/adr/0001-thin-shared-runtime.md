# ADR 0001: Thin shared-runtime model with per-project containerd objects

- **Status:** Accepted
- **Date:** 2026-05-14
- **Supersedes:** an earlier in-development model in which each project had
  its own Lima VM (one VM per registered project on macOS).

## Context

sbx wraps a rootless container runtime to give CLI tools (AI coding agents,
build tools, package managers) a sandbox with hostname-based egress
filtering. The questions the design has to answer:

1. **Where does the Linux kernel for the containers come from?**
   macOS can't run Linux containers natively, so a Linux VM is needed.
   Linux can run rootless containerd directly with no VM.
2. **How are projects isolated from each other?**
   The threat model is "an AI agent loose in project A shouldn't be able
   to delete/exfiltrate project B's files, reach project B's allowed
   hosts, or pollute project B's tool caches".
3. **What's the cost per new project?**
   Setup time and resource use should not scale badly with project count.

The previous design answered (1) and (2) at the same time by giving every
project its own Lima VM. Isolation was free (separate kernel per project)
but the resource cost was high: ~8 GB RAM allocation and a ~3 GB sandbox
image build per VM, and ~4 minutes to set up each new project from cold.
On Linux the same shape would either require a hypervisor (much more
moving parts) or be reduced to single-runtime anyway, breaking parity.

## Decision

Decouple "runtime host" from "project boundary":

- **One container runtime per host.** On macOS, a single shared Lima VM
  named `sbx` with `$HOME` mounted (created once, never restarted when
  adding projects). On Linux, no VM at all — `nerdctl` talks to the host's
  rootless containerd directly.
- **Per-project isolation lives one layer down, inside containerd.** Each
  registered project gets:
  - its own `--internal` nerdctl network (`sbx-int-<id>`),
  - its own proxy container (`sbx-proxy-<id>`) with its own allowlist
    bind-mounted in,
  - its own `/home/dev` cache volume (`sbx-home-<id>`),
  - a bind mount of only its own directory at `/work` in the sandbox.
- **Shared:** one proxy image (`sbx-proxy:latest`, project-agnostic),
  one sandbox image (`sbx-sandbox:latest`, built once with host UID/GID
  baked in via build args), one external bridge (`sbx-external`).
- **Project registry of record:** `~/.config/sbx/projects.json` —
  a flat map `{ "<project-id>": "<absolute path>" }`. Lima's per-instance
  yaml is no longer consulted for project metadata.
- **Discovery:** `bin/sbx` finds the project for any command by
  longest-prefix match of `$PWD` against registered paths, so nested
  registrations and `cd` into subdirectories work naturally.
- **Cross-platform code path:** the wrapper has exactly two
  platform-branched functions — `nerdctl()` (dispatches through
  `limactl shell` on macOS, calls `nerdctl` directly on Linux) and
  `ensure_runtime()` (creates/starts the Lima VM on macOS, asserts
  rootless containerd reachability on Linux). Everything else is
  identical.

## Consequences

### Positive

- **New-project setup goes from ~4 min to seconds.** No VM creation, no
  image rebuild — just `nerdctl network create` + `nerdctl run proxy`.
- **Resource use stops scaling with project count.** One VM, one fat
  sandbox image, one set of shared dependencies for any number of
  projects.
- **One codebase, both platforms.** The Linux port is the same wrapper
  with the Lima branch skipped. No separate Linux implementation to
  maintain.
- **Allowlist edits no longer require an image rebuild.** Allowlist files
  are bind-mounted into the proxy at run time, so `sbx build-proxy` is a
  proxy-restart, not a multi-minute image rebuild.
- **Project registry is portable and tool-readable.** A small JSON file
  with `jq`-friendly shape; `sbx prune` reconciles it against actual
  containerd state.

### Negative

- **Kernel boundary between projects is gone.** With per-project VMs,
  a kernel-level container escape from project A could not reach
  project B. In the thin model A and B share a kernel (the Lima VM's on
  macOS, the host's on Linux). For sbx's stated threat model — agent
  misbehaviour, accidental egress, unintended file writes — network,
  filesystem, allowlist and UID isolation are still in force and
  sufficient. Threat models that need kernel-level isolation between
  projects should not use this model.
- **Lima sees a broader mount (`$HOME`) than any single container
  does.** The Lima VM is a privileged-by-default boundary that now spans
  all of `$HOME`. Mitigated by the fact that the wrapper only runs
  user-controlled commands inside the per-project sandbox containers,
  never directly against the Lima mount.
- **One bash loop pitfall to remember.** `limactl shell` reads stdin,
  which can swallow the remaining lines of a `done < <(...)` process
  substitution and silently cut a loop short. The wrapper sidesteps this
  by materialising registry pairs into a bash array before iterating
  (see `cmd_status`, `cmd_reset`, `cmd_prune`, `cmd_build_proxy`).

### Neutral

- **`sbx reset` semantics changed.** It now tears down a project's
  containerd objects (network, proxy, cache volume) and removes the
  registry entry; it does not touch the shared Lima VM. `sbx reset --all`
  does the same for every project but still leaves the VM. Removing the
  VM is an explicit `limactl delete sbx`, documented in the wrapper's
  output.
- **The `~/.lima/<vm>/lima.yaml` no longer carries project state.** This
  was a previous source of subtle bugs (the file is rewritten by Lima on
  upgrade in ways the wrapper used to depend on). The registry is now
  the single source of truth.

## Alternatives considered

1. **One Lima VM per project (the previous shape).**
   Strong isolation; high resource cost; no good Linux analogue without
   adding a hypervisor. Rejected for setup latency and lack of platform
   symmetry, given the threat model does not require kernel boundaries.

2. **One Lima VM, per-project Lima mounts.**
   Each registered project adds a `mounts:` entry to the Lima yaml.
   Mounts are not hot-pluggable in Lima, so adding a project would
   restart the VM and interrupt every other project. Rejected because
   "registering a new project" should never disrupt unrelated work.

3. **One Lima VM, single broad mount, single shared proxy with a unioned
   allowlist.** Simplest implementation but allowlists leak across
   projects: any host any project trusts becomes reachable from every
   other project. Rejected on isolation grounds.

4. **A small Go binary instead of bash.**
   More portable across edge cases; eliminates the `limactl shell`
   stdin pitfall structurally. The current code is ~330 lines of bash
   and reads well as a sequence of small functions; rewriting in Go is
   future work, not blocker work.

## Implementation pointers

- Wrapper: [`bin/sbx`](../../bin/sbx)
- Lima template (macOS): [`lima/sandbox.yaml`](../../lima/sandbox.yaml)
- Proxy image: [`proxy/`](../../proxy/) (sniproxy + dnsmasq, allowlists
  bind-mounted at run time)
- Sandbox image: [`sandbox/Dockerfile`](../../sandbox/Dockerfile) (Rust,
  Go, Node, Python, Java, Ruby, devbase-core CLI subset; UID/GID via
  build args)
- Registry: `~/.config/sbx/projects.json`
- Threat-model details: [`../../README.md`](../../README.md)
