# plan.md

# Runix

## R-native Unix system administration

Runix is a systems-administration framework for Unix-like operating systems, beginning with Ubuntu and Debian.

Its goal is to make R a serious high-level systems language by providing coherent APIs over the native operating-system interfaces already used by tools such as `apt`, `systemd`, NetworkManager, D-Bus, udev, and polkit.

The project does **not** require a new Linux distribution.

The initial target is ordinary Ubuntu.

```text
Ubuntu / Debian
      |
native system interfaces
      |
C / C++ / Rust where appropriate
      |
Runix R packages
      |
rctl CLI
      |
R administrative programs
```

Python remains installed and fully supported as a programming language.

The long-term objective is narrower:

> Remove the need for Python as an implementation dependency of first-party system administration where Runix provides a suitable replacement.

If an existing Python administrative component is eventually replaced by an R or native implementation, its Python dependency can disappear naturally.

There is no requirement to remove Python itself.

---

# Naming

## Runix

**Runix** is the overall project and systems ecosystem.

The name reflects:

```text
R + Unix
```

Runix should remain broader than any individual Linux distribution.

Long term, the same abstractions may be useful on:

* Ubuntu
* Debian
* Fedora/RHEL
* Arch
* other systemd-based Linux distributions
* potentially BSD systems where appropriate

Ubuntu/Debian is simply the first implementation target.

## rctl

`rctl` is the command-line interface.

Examples:

```bash
rctl status
rctl packages
rctl packages upgradeable
rctl services
rctl services failed
rctl network
rctl devices
rctl journal
```

Eventually:

```bash
rctl plan machine.R
rctl apply machine.R
```

The naming deliberately follows familiar Unix conventions such as:

```text
systemctl
networkctl
journalctl
kubectl
```

Note: FreeBSD ships an unrelated `rctl(8)` (resource control). No conflict on
Linux — no Ubuntu package or binary claims the name — but revisit the CLI name
if BSD support ever materializes.

---

# Goal

Build a serious R-based administration layer over existing Unix infrastructure.

Runix should:

* use R for high-level administration, orchestration, policy, inspection, and configuration;
* use C, C++, or Rust for low-level, latency-sensitive, persistent, privileged, or concurrency-heavy functionality;
* expose structured native interfaces rather than parsing command-line output wherever possible;
* integrate with existing package managers and service managers;
* use ordinary R objects and base R conventions;
* keep dependencies small;
* allow binary R packages to be delivered through normal system package infrastructure;
* make system administration available both programmatically through R and conventionally through `rctl`.

Runix is not an attempt to prove that every component can or should be written in R.

---

# Core Architectural Principle

Runix sits **above**, not underneath, the mature Unix infrastructure.

Do not replace:

* Linux kernel
* libc
* apt
* dpkg
* rpm
* systemd
* D-Bus
* udev
* NetworkManager
* polkit
* PAM
* nftables
* coreutils

Instead expose those systems coherently to R.

```text
                 Runix
                   |
       +-----------+-----------+
       |           |           |
      apt       systemd    NetworkManager
       |           |           |
     dpkg        D-Bus        D-Bus
       \           |           /
        \----------+----------/
                   |
                Linux
```

---

# Relationship to Python

Python is not the enemy and does not need to be removed.

There are three distinct uses of Python:

```text
1. Python applications
2. third-party Python tooling
3. Python used internally by system administration
```

Runix only concerns itself with the third category.

A Python application should continue to work normally:

```bash
python3 app.py
```

The migration target is instead:

```text
Current:

Python administrative program
            |
         system API

Future:

R administrative program
            |
         Runix API
            |
         system API
```

Once a replacement reaches feature parity and demonstrates sufficient reliability, the old implementation can be deprecated independently.

No coordinated "remove Python from Ubuntu" effort is necessary.

---

# Language Boundary

Runix should use each language where it makes sense.

## R

Use R for:

* orchestration
* system inspection
* configuration
* policy
* diagnostics
* administrative logic
* desired-state construction
* reporting
* planning
* interactive use
* CLI behavior where startup requirements permit

## Rust / C++

Use native code for:

* daemons
* privileged helpers
* low-level system interfaces
* event loops
* hot paths
* high-frequency event processing
* binary protocols
* startup-sensitive code
* memory-sensitive services
* concurrency-heavy components
* APIs poorly exposed through existing stable interfaces

R should provide the public control-plane interface.

The implementation underneath can be whatever is technically appropriate.

---

# Design Principles

## 1. Base R interfaces

Runix APIs should use normal R data structures and syntax.

Prefer:

```r
units <- systemd_units()

failed <- units$active_state == "failed"

units[failed, c("unit", "description", "sub_state")]
```

Avoid requiring:

* tidyverse
* dplyr
* pipe-oriented workflows
* large dependency stacks for simple system operations

Data frames are particularly suitable for:

* processes
* packages
* services
* devices
* mounts
* users
* groups
* interfaces
* routes
* journal entries

## 2. Native APIs before CLI parsing

Avoid APIs built primarily around:

```r
system2("systemctl", ...)
system2("apt", ...)
system2("nmcli", ...)
```

Shell execution can be useful as an early bridge, but the intended architecture is:

```text
R
 |
native binding / D-Bus / socket / stable protocol
 |
system component
```

Examples:

```r
systemd_restart("NetworkManager.service")
apt_install("curl")
network_connection_up("home")
```

### Bridge discipline (decided 2026-08-07)

Phase 1/2 implementations may use a temporary CLI bridge (`system2()` over
`systemctl`, `apt`, etc.). The bridge is not equivalent to the native API, and
every bridge carries the obligation to be swappable. A bridge is permitted only
when all of these hold:

* the command interface is stable enough to parse;
* `LC_ALL=C` and a fixed minimal environment are enforced;
* parsing is fail-closed — absent tool yields an honest empty result;
  present-but-unparseable output refuses rather than guesses;
* postconditions are verified after mutations
  (request, then observe, then settle — never request-and-assume);
* runners are injectable so tests use fakes;
* the returned R API is shaped for the eventual native implementation,
  so the transport swaps without breaking callers.

These rules are already proven in internal cornball tooling; lift them
rather than reinvent them.

## 3. Small dependency graph

System administration should not require a sprawling R environment.

Prefer:

* R
* small purpose-built packages
* native OS libraries
* binary installation

Every dependency added to a system package should have a clear reason.

## 4. Structured results

Operations should return useful R objects.

Avoid APIs that only print human-readable output.

For example:

```r
result <- apt_install("curl")

result$changed
result$installed
result$previous_version
result$new_version
```

## 5. Idempotence

Administrative operations should be idempotent where practical.

```r
apt_install("curl")
```

should not reinstall `curl` unnecessarily.

Likewise:

```r
systemd_enable("ssh.service")
```

should describe intent rather than forcing repeated changes.

---

# Existing Work

## rapt

`rapt` already provides an important vertical slice of the Runix architecture.

It demonstrates:

* R-facing package-management operations;
* separation between high-level R logic and privileged operations;
* integration with the native apt ecosystem.

Runix should build on this rather than introduce a competing apt implementation.

Concretely, rapt's mechanism is: a ~330-line root C daemon (`raptd`) behind an
AF_UNIX socket with systemd socket activation; a generic C socket client inside
the R package (`unix_socket.c` — reusable for any line-protocol daemon); strict
object allowlisting instead of caller identity; and a deliberate rejection of
the PackageKit/polkit/D-Bus stack. That rejection was right for rapt's two-verb,
regex-constrained noun space. It does not generalize to systemd or
NetworkManager control, whose noun spaces are unbounded and need caller
authorization (see Privilege Model).

## RcppAPT

Dirk Eddelbuettel's RcppAPT exposes apt package information through `libapt-pkg`.

It is useful prior art for the read/query side of apt integration.

Potential architecture:

```text
             apt support
                 |
        +--------+--------+
        |                 |
    RcppAPT              rapt
   query/read        mutations/control
        \                 /
         \---------------/
                 |
              Runix
```

A future cleanup can determine whether:

* the projects remain complementary;
* they share a lower-level native package;
* one absorbs functionality from the other;
* or Runix simply presents a unified interface above both.

Do not rewrite working apt integrations for architectural neatness.

## corteza and internal prior art

Internal cornball tooling has already proven the disciplined systemd-surface
patterns Phase 1 needs: idempotent unit operations with verified
postconditions, declarative unit specs as plain data, fail-closed host-facts
collection, and injectable runners for testing. Phase 1 lifts these patterns
rather than reinventing them.

corteza (public repo) contributes the daemon loop split (`*_init` / `*_step` /
`*_run`), JSON structured logging, CRAN-compliant XDG path discipline,
signal-file IPC for poking daemons without shared state, processx-based
subprocess management, and CLI entry-point patterns.

## PackageKit and Ubuntu's own D-Bus backends

PackageKit (C, D-Bus, polkit, its own libapt backend) is the cross-distro
privileged package service; Discover and GNOME Software drive apt through it on
Ubuntu today. rapt rejected this stack deliberately — treat that as a considered
per-subsystem decision to revisit, not a blanket rule.

Ubuntu itself ships four root **Python** D-Bus backends today: `aptd`,
`software-properties-dbus`, `ls-dbus-backend`, and `usb-creator-helper`. They
are simultaneously the privilege-model prior art and Phase 4/5 replacement
targets. See `docs/ubuntu-python-admin-inventory.md`.

## KDE as an inspection point

KDE Plasma already solves many of the same integration problems over native
interfaces:

* **KAuth / polkit** — narrowly scoped privileged helpers
* **Solid** — hardware abstraction over udev, UDisks2, UPower
* **NetworkManagerQt** — typed bindings over the NM D-Bus API
* **Discover** — package-management frontend over PackageKit-Qt
* **DrKonqi** — crash handling over systemd-coredump
* System Settings modules mapping user-facing administration onto system APIs

For each administrative capability, ask: how does KDE perform this operation,
and what native API or reusable component does it use underneath? (The Phase 0
inventory records carry a "KDE prior art" field for exactly this.)

KDE is architectural prior art, never a dependency. Runix stays
desktop-independent — KDE Plasma, GNOME, and headless servers equally. Where
KDE already exposes a mature native abstraction, consider binding it or
learning from it before dropping to a lower-level API unnecessarily.

---

# Package Architecture

Avoid creating one giant Runix package.

Prefer small subsystem packages with stable APIs.

Possible initial structure:

```text
runix
rapt
rdbus
rsystemd
rudev
rpolkit
rnetwork
```

Names are provisional except `rapt`.

## runix

Common Unix/Linux primitives.

Potential functionality:

```text
processes
signals
users
groups
filesystem metadata
mounts
procfs
sysfs
host information
kernel information
capabilities
namespaces
sockets
```

Examples:

```r
processes()
users()
groups()
mounts()
kernel_info()
```

## rdbus

Provide a robust R D-Bus implementation.

Requirements:

* system bus
* session bus
* introspection
* methods
* properties
* signals
* type conversion
* asynchronous/event support where necessary

D-Bus is likely foundational for much of modern Linux administration.

Backend decision (2026-08-07, for Linux/systemd targets): bind libsystemd's
**sd-bus**. It is already installed on every systemd distro, it is a small
stable C API with no GLib or libdbus dependency, and sd-journal rides in the
same library — journal access is not D-Bus at all, so rsystemd needs libsystemd
regardless. This is a backend choice, not a Runix-wide requirement: the rdbus R
API must not assume sd-bus, so a different backend (e.g. libdbus on non-systemd
Unix) can slot in behind the same interface if portability ever demands it.

## rsystemd

Expose systemd administration.

Initial API:

```r
systemd_units()
systemd_status()
systemd_start()
systemd_stop()
systemd_restart()
systemd_enable()
systemd_disable()
systemd_journal()
```

Example:

```r
units <- systemd_units()

units[units$active_state == "failed", ]
```

Use D-Bus or native systemd APIs rather than scraping `systemctl`.

## rudev

Expose device discovery.

```r
devices <- udev_devices()

usb <- devices$subsystem == "usb"
devices[usb, ]
```

Later:

```r
udev_monitor()
```

Continuous event processing can be implemented natively if required.

## rpolkit

Expose standard privilege authorization mechanisms.

Ordinary R administrative processes should not need to run as root.

## rnetwork

Initially target NetworkManager through D-Bus.

Potential API:

```r
network_interfaces()
network_connections()
wifi_networks()
network_connection_up()
network_connection_down()
```

Do not attempt to invent a new network-management daemon.

---

# Privilege Model

Runix should avoid:

```bash
sudo R
```

as the normal administration model.

Instead:

```text
R process
    |
restricted API
    |
polkit / D-Bus / Unix socket
    |
small privileged native component
    |
system
```

Rules:

1. R runs as the normal user by default.
2. Privileged operations are narrowly scoped.
3. Native helpers validate all input.
4. Privileged components remain small and auditable.
5. Arbitrary R code must never be evaluated as root merely because an operation requires privilege.
6. Mutations should be logged.
7. Authorization should use existing Linux mechanisms where possible.

The privilege separation already explored in `rapt` should inform this design.

Authorization strategy: **reuse service-level authorization where provided.**
systemd, NetworkManager, and logind check polkit themselves when called over
D-Bus, so calling their native APIs inherits their authorization — no
Runix-side privileged helper is needed for those subsystems. This is not
automatic everywhere: whether a given method is gated, and how, depends on the
service, the method, the polkit action, and the session context (active local
session vs SSH). Each subsystem integration must therefore document which
operations need explicit policy handling — a polkit rules file, or a
terminal auth agent for headless use. rpolkit is deferred until something needs
explicit `CheckAuthorization`. rapt's socket daemon remains the pattern for apt
mutations, where no suitable service-level authorization layer is in use.

---

# Phase 0: Inventory

Before replacing anything, establish what actually exists.

Create an inventory of Ubuntu's administrative tools that materially depend on Python.

The question is not:

> Which installed packages contain Python?

The useful question is:

> Which first-party administrative capabilities depend on Python?

Classify by:

```text
package management
updates
repositories
drivers
hardware
networking
service management
users
installer
crash reporting
cloud provisioning
desktop administration
diagnostics
security
```

Record:

```text
program
Ubuntu package
implementation language
Python dependencies
native APIs underneath
privilege model
daemon vs command
boot-critical?
performance-sensitive?
candidate Runix APIs
replacement difficulty
replacement value
```

Deliverable:

```text
docs/ubuntu-python-admin-inventory.md
```

Also identify equivalent implementations in:

* Debian
* Fedora/RHEL
* NixOS
* Arch
* other major Linux projects

The purpose is to find existing native implementations before writing replacements.

**Status: delivered 2026-08-07** (survey of Ubuntu 24.04.4; see
`docs/ubuntu-python-admin-inventory.md`). Headline findings:

* The Python footprint concentrates in the apt/update ecosystem. Service
  management, users/groups, and udev are already native (C or Perl) — Runix
  Phase 2 covers the Python-heavy half and the native half in one stroke.
* Ubuntu ships four root Python D-Bus backends that model the privilege
  pattern (aptd, software-properties-dbus, ls-dbus-backend, usb-creator-helper).
* Canonical already migrates hot paths to C and leaves policy in Python
  (netplan's C core and boot generator, gpu-manager, the Pro apt hook).
  Runix replaces the policy layer; the C cores stay.
* Provisional Phase 4 shortlist: **netplan CLI** (substitution exemplar —
  swap the Python CLI, keep the C core and its 97-symbol C ABI) and
  **ubuntu-security-status** (introspection exemplar, read-only,
  unprivileged). Provisional until the Phase 4 gate.

---

# Phase 1: System Introspection

The first major Runix milestone should be read-only.

R should become very good at examining a running Linux system.

Target areas:

```text
packages
services
journal
processes
users
groups
mounts
devices
network interfaces
host/kernel
```

Possible unified interface:

```r
x <- system_status()
```

The initial `rctl` CLI:

```bash
rctl status
rctl packages
rctl services
rctl services failed
rctl journal
rctl network
rctl devices
```

This phase should require no broad privileged access.

It gives immediate practical value while avoiding mutation risks.

---

# Phase 2: apt + systemd Vertical Slice

The first complete administration stack should cover:

```text
apt
systemd
journal
```

Deliver:

1. installed package queries;
2. candidate package queries;
3. upgradeable package queries;
4. package installation/removal;
5. service listing;
6. failed-service inspection;
7. start/stop/restart;
8. enable/disable;
9. journal access;
10. CLI wrappers;
11. binary packaging.

R example:

```r
pkgs <- apt_upgradable()
print(pkgs)

units <- systemd_units()

failed <- units$active_state == "failed"
print(units[failed, ])

systemd_restart("cups.service")
```

CLI equivalent:

```bash
rctl packages upgradeable
rctl services failed
rctl service restart cups.service
```

This milestone should feel like ordinary Linux administration.

If it instead feels like R awkwardly launching existing CLI commands, redesign the lower-level interfaces before proceeding.

---

# Phase 3: Networking, Devices, and Users

Expand Runix into:

```text
NetworkManager
udev
users/groups
mounts
filesystem administration
```

At this point `rctl` becomes useful as a general local administration interface.

Examples:

```bash
rctl network
rctl network wifi
rctl devices
rctl users
rctl mounts
```

---

# Phase 4: Replace One Python Administrative Program

Only after the Runix APIs are useful should an existing Ubuntu Python utility be rewritten.

Pick one tool that is:

* clearly administrative;
* mostly Python;
* not boot-critical;
* reasonably bounded;
* backed by native APIs already exposed through Runix;
* meaningful enough to prove the architecture.

Do not begin with:

* the installer;
* cloud-init;
* a critical boot component;
* a major security boundary.

The replacement should:

* run on stock Ubuntu;
* use Runix APIs;
* ship as a normal `.deb`;
* coexist with the original implementation during testing;
* have integration tests against the original behavior where possible.

The project should demonstrate replacement by **substitution**, not by creating a new distro.

---

# Phase 5: Gradual Python Administrative Dependency Reduction

For each Python-based administrative program:

```text
Does Runix expose the necessary system capabilities?
                |
        +-------+-------+
        |               |
       no              yes
        |               |
 improve Runix       candidate
                    replacement
```

A replacement can proceed when:

* required APIs are mature;
* behavior is tested;
* privilege boundaries are understood;
* package/distribution behavior is reliable;
* performance is acceptable.

Then:

```text
Python implementation
        |
    deprecated
        |
replacement becomes default
        |
old Python dependency can disappear
```

This can happen one package at a time.

There is no "Python removal day."

---

# Phase 6: Binary Distribution Through r2u

Runix cannot depend on source compilation on production machines.

System-facing R packages should be installable as normal Debian packages.

Example:

```bash
sudo apt install r-cran-rsystemd
```

or eventually:

```bash
sudo apt install runix rctl
```

The flow:

```text
R source package
       |
      r2u
       |
binary .deb
       |
apt repository
       |
Ubuntu machine
```

The target machine should not need:

```r
install.packages()
```

to establish the administrative environment.

For Runix, r2u becomes part of the build/distribution infrastructure rather than an end-user package manager.

Caveat (provisional): r2u builds CRAN packages, so the r2u path assumes CRAN
acceptance — and Linux-only packages linking libsystemd face real CRAN friction
(macOS check machines have no systemd; RcppAPT shows the stub-configure
gymnastics required). Treat this phase as a requirement, not a committed
mechanism. The requirement is: apt-installable binary `.deb`s, no interactive
CRAN install. Candidate mechanisms to validate when Phase 6 nears:

* CRAN + r2u — the endgame, once APIs are stable enough for CRAN cadence;
* a cornball apt repository built with rapt's `mkrepo.sh` pattern — the bootstrap;
* direct `.deb` packaging as rapt already does today.

The drat repo is source-only and does not satisfy the binary requirement on its own.

---

# Phase 7: Declarative Administration

Declarative state is optional and comes later.

Do not begin by cloning NixOS.

First make imperative system APIs excellent.

Then allow:

```r
machine <- system_config(
    packages = c(
        "git",
        "tmux",
        "openssh-server"
    ),

    services = list(
        service_config(
            "ssh.service",
            enabled = TRUE,
            running = TRUE
        )
    )
)
```

Inspect:

```r
plan <- system_plan(machine)
print(plan)
```

Possible output:

```text
3 changes

+ install tmux
+ enable ssh.service
+ start ssh.service
```

Apply:

```r
system_apply(plan)
```

Applying the same configuration again should normally result in:

```text
0 changes
```

This resembles configuration management more than NixOS.

---

# Relationship to NixOS

Runix should not pretend to reproduce NixOS semantics.

NixOS provides:

* Nix derivations;
* isolated package outputs;
* the Nix store;
* multiple simultaneous package versions;
* system generations;
* atomic activation;
* strong rollback;
* reproducible dependency closures.

Runix initially provides none of these.

Runix instead retains:

* conventional filesystem layout;
* apt/dpkg;
* existing Ubuntu repositories;
* normal shared libraries;
* normal `/usr`, `/etc`, `/var`, and `/lib`;
* existing Debian packages;
* Ubuntu hardware support.

The conceptual difference:

```text
NixOS

desired state
    |
derivations
    |
Nix store
    |
system generation
```

versus:

```text
Runix on Ubuntu

desired state
    |
inspect current state
    |
calculate changes
    |
apt/systemd/etc.
    |
ordinary Ubuntu state
```

Runix can borrow useful ideas from NixOS without rebuilding Nix.

---

# Relationship to Ansible

Declarative Runix initially resembles Ansible more than NixOS.

Potential advantages:

* R rather than YAML;
* native local system APIs;
* structured state represented directly as R objects;
* normal programming constructs;
* direct system inspection;
* no SSH requirement for local use;
* strong integration with apt and systemd.

Remote orchestration is explicitly not an initial goal.

Make local machine administration excellent first.

---

# Relationship to Cockpit

Cockpit is useful architectural prior art.

Cockpit provides one coherent administrative layer over:

* systemd
* storage
* networking
* packages
* logs
* users
* other standard Linux interfaces

Runix aims for a similar consolidation at the **programming interface** level.

Conceptually:

```text
             native Linux APIs
                    |
          +---------+---------+
          |                   |
       Cockpit              Runix
       Web UI                R API
                              |
                            rctl
```

Runix should study Cockpit's use of native APIs, privilege separation, and subsystem boundaries.

Do not duplicate system services that Cockpit already demonstrates can be controlled cleanly through existing interfaces.

---

# CLI Design

`rctl` should be useful even to someone who does not care that it is implemented with R.

Examples:

```bash
rctl status

rctl packages
rctl packages upgradeable
rctl package install git

rctl services
rctl services failed
rctl service restart ssh.service

rctl journal
rctl journal --priority error

rctl network
rctl devices
rctl users
```

Support structured output:

```bash
rctl services --json
```

Potential later support:

```bash
rctl plan machine.R
rctl apply machine.R
```

The R API is primary.

The CLI exposes that API to ordinary Unix workflows.

---

# Performance Strategy

Do not optimize R away before measuring it.

Many administrative operations are dominated by:

* D-Bus calls;
* disk access;
* package-manager operations;
* network operations;
* service startup;
* system calls.

R interpreter overhead is irrelevant for many of these.

Move functionality to Rust/C++ when there is an actual reason:

* startup latency;
* memory footprint;
* long-running service;
* high event frequency;
* tight processing loop;
* concurrent event handling;
* privilege boundary.

Avoid language rewrites based only on assumptions about speed.

---

# Daemon Strategy

Avoid persistent R daemons unless there is a compelling reason.

Preferred architecture:

```text
R client
    |
D-Bus / Unix socket
    |
small native daemon
    |
system
```

Persistent components should generally be native.

R should primarily occupy the control-plane role.

---

# Packaging Strategy

A Runix subsystem should look like a normal OS package.

Eventually:

```bash
sudo apt install rctl
```

should install everything required through apt.

Dependencies can include:

```text
r-base-core
Runix R packages
native libraries
small native helpers
```

No interactive CRAN installation should be required.

The system package manager remains authoritative.

---

# Testing Strategy

## Unit tests

Test:

* R API behavior;
* data conversion;
* resource comparison;
* planning;
* error handling.

## Native tests

Test:

* bindings;
* protocol handling;
* privilege checks;
* native helpers.

## Containers

Use containers for:

* apt behavior;
* filesystem operations;
* package queries;
* non-systemd integration.

## VMs

Use disposable Ubuntu VMs for:

* systemd;
* D-Bus;
* polkit;
* NetworkManager;
* upgrades;
* user management;
* destructive administrative testing.

Primary platforms:

```text
Ubuntu LTS amd64
Ubuntu LTS arm64
```

Add other distributions only after the architecture proves portable.

---

# Repository Strategy

Runix should be an ecosystem rather than necessarily a monorepo.

Possible layout:

```text
runix
rapt
rdbus
rsystemd
rudev
rpolkit
rnetwork
rctl
```

An umbrella repository may contain:

```text
docs/
architecture/
integration-tests/
vm-tests/
examples/
```

but independently reusable packages should remain independent where appropriate.

---

# First Concrete Milestone

Build enough Runix to make this work reliably on stock Ubuntu:

```r
pkgs <- apt_upgradable()
print(pkgs)

units <- systemd_units()

bad <- units$active_state == "failed"
print(units[bad, ])

systemd_restart("cups.service")

logs <- systemd_journal(priority = "error")
print(logs)
```

And:

```bash
rctl status
rctl packages upgradeable
rctl services failed
rctl journal --priority error
```

Install the complete stack using:

```bash
apt
```

on a clean Ubuntu VM.

No manual CRAN installation.

No root R session.

No distro fork.

---

# Second Concrete Milestone

Add:

```text
NetworkManager
udev
users/groups
mounts
```

At this stage Runix should be sufficient to implement a meaningful existing Ubuntu administrative program without Python.

Select the first replacement from the Phase 0 inventory.

---

# Third Concrete Milestone

Ship one Python-to-Runix replacement.

Requirements:

* equivalent major functionality;
* integration tests;
* normal `.deb` packaging;
* safe privilege behavior;
* no new distro;
* original Python implementation can remain installed during transition.

This proves the central thesis:

> Ubuntu administrative Python dependencies can be replaced incrementally rather than through a distribution rewrite.

---

# Fourth Concrete Milestone

Introduce the smallest useful declarative layer:

```text
packages
services
```

Example:

```r
machine <- system_config(
    packages = c("git", "tmux"),
    services = list(
        service_config(
            "ssh.service",
            enabled = TRUE,
            running = TRUE
        )
    )
)

system_apply(machine)
```

Apply twice.

The second run should report no changes.

Only then consider:

```text
files
users
groups
repositories
mounts
network configuration
locks
snapshots
rollback
```

---

# Non-Goals

Runix does not initially aim to:

* create a Linux distribution;
* remove Python from Linux;
* replace Python applications;
* rewrite apt;
* rewrite dpkg;
* rewrite systemd;
* create a package format;
* create an init system;
* create a libc;
* recreate the Nix store;
* replace every shell command;
* implement remote fleet management;
* build another Kubernetes;
* require all low-level code to be written in R;
* introduce an R-specific configuration DSL.

Runix should remain useful on ordinary Linux systems.

---

# Success Criteria

Runix succeeds if:

1. R can inspect core Linux state through stable native interfaces.
2. Common administrative operations can be performed safely from R.
3. Administrative R sessions do not need unrestricted root privileges.
4. Persistent and performance-sensitive components can remain native.
5. Runix packages can be installed through the normal OS package manager.
6. `rctl` provides a coherent Unix administration CLI.
7. At least one existing Python administrative component can be replaced without modifying the underlying distribution architecture.
8. Python applications continue to work normally.
9. The underlying Ubuntu package, service, networking, and filesystem models remain intact.
10. The result feels like a native Unix administration framework rather than a collection of R wrappers around shell commands.

---

# Working Thesis

Runix is based on a narrower claim than "Linux in R":

> R can be an effective Unix systems-administration language if it is given proper access to native operating-system interfaces.

Modern Linux already provides the difficult infrastructure:

```text
apt
dpkg
systemd
D-Bus
udev
NetworkManager
polkit
kernel APIs
```

Runix supplies:

```text
coherent R interfaces
        +
small native components where appropriate
        +
safe privilege separation
        +
r2u binary distribution
        +
rctl
```

That is sufficient to build and test an R-native administration layer on stock Ubuntu.

A new distribution is unnecessary.

If Runix eventually becomes comprehensive enough that particular Python administrative components are no longer needed, those dependencies can be deprecated and removed incrementally.

That is an outcome of a successful administration layer, not a prerequisite for building one.
