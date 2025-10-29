### 0.9.5 (2025-10-29)

- Update ARP entry behavior: the unikernel now responds with its MAC address for every APR request from a client. This fixes issues with some VPN clients (#221, @palainp, reviewed by @hannesm, fix confirmed by @pprudev).
- Fix HVM client handling: HVM Clients, such as Windows, have two network interfaces but only use one. This causes deadlock states because the connection protocol for one interface is not completed, leading the unikernel to wait for the client to shut down. Now, each connection uses its own thread, and the unikernel can handle Windows HVM (#219 @palainp).
- Add a GH action for code auto-formatting (#217 @hannesm).
- Update to OCaml 5.3 + Mirage ecosystem (4.9 in #215 @hannesm and 4.10 in #216 @palainp).

### 0.9.4 (2025-02-10)

- Fix an issue when qubes-mirage-firewall is used a a mullvad AppVM client. If
  our netvm does not reply to our ARP requests we can not construct the ethernet
  header. However in Linux VMs, Qubes adds a default netvm address associated to
  `fe:ff:ff:ff:ff:ff`, so if ARP fails, we fall back on that address.
  (#213, @palainp, reported in the Qubes forum #212, reviewed by @hannesm)

### 0.9.3 (2025-01-04)

- Fix an issue when qubes-mirage-firewall is used along with *BSD sys-net
  (#209, @palainp, reported in the Qubes forum #208, reviewed by @dinosaure)

### 0.9.2 (2024-10-16)

- Code refactoring and improvements (#197, @dinosaure)
- Build tooling updates: opam 2.2.1, solo5 0.9, mirage 4.8.1 (#199, #201, #202,
  #203, @hannesm)

### 0.9.1 (2024-05-10)

- Drop astring dependency, update mirage-net-xen, and OCaml 4.14.2 -- the
  latest LTS release (#193, @hannesm)
- Allow the firewall to use domains requests in rules (#193, @palainp,
  reported in the Qubes forum, fix confirmed by @neoniobium)

### 0.9.0 (2024-04-24)

- Fix an incorrect free memory estimation (fix in mirage/ocaml-solo5#135
  @palainp)
- Update to mirage 4.5.0, allowing openBSD to be used as netvm (#146 reported
  by @Szewcson), and recover from a netvm change (#156 reported by @xaki-23)
  (#178 @palainp)

### 0.8.6 (2023-11-08)

- Fix Docker build issue with newest SELinux policies (#183 @palainp, reported
  by @Szewcson)
- Update build script (change to debian repositories, update debian image, update
  opam-repository commit, set commit for opam-overlay and mirage-overlay) (#184
  @palainp, reported by @ben-grande)
- Update disk usage value during local compilation (#186 @palainp, reported by
  @ben-grande)

### 0.8.5 (2023-07-05)

- Remove memreport to Xen to avoid Qubes trying to get back some memory
  (#176 @palainp)
- Use bookworm and snapshot.notset.fr debian packages for reproducibility
  (#175 @palainp)

### 0.8.4 (2022-12-07)

- Fix remote denial of service due to excessive console output (#166 @burghardt,
  fix in solo5/solo5#538 by @palainp)
- Use Ubuntu container for build, now GitHub action, ./build-with-docker.sh and
  builds.robur.coop are synchronized (and result in the same artifact)
  (#164 @hannesm)

### 0.8.3 (2022-11-11)

- Fix "DNS issues", a firewall ruleset with a domain name lead to 100% CPU usage
  (reported by fiftyfourthparallel on
  https://forum.qubes-os.org/t/mirage-firewall-0-8-2-broken-new-users-should-install-0-8-1/14566,
  re-reported by @palainp in #158, fixed by @hannesm in mirage/mirage-nat#48
  (release 3.0.1)) - underlying issue was a wrong definition of `is_port_free`
  (since 3.0.0, used since mirage-qubes-firewall 0.8.2).
- Fix "crash on downstream vm start", after more than 64 client VMs have been
  connected and disconnected with the qubes-mirage-firewall (reported by @xaki23
  in #155, fixed by @hannesm in #161) - underlying issue was a leak of xenstore
  watchers and a hard limit in xen on the amount of watchers
- Fix "detach netvm fails" (reported by @rootnoob in #157, fixed by @palainp
  in mirage/mirage-net-xen#105 (release 2.1.2)) - underlying issue was that the
  network interface state was never set to closed, but directly removed
- Fix potential DoS in handling DNS replies (#162 @hannesm)
- Avoid potential forever loop in My_nat.free_udp_port (#159 @hannesm)
- Assorted code removals (#161 @hannesm)
- Update to dns 6.4.0 changes (#154, @hannesm)

### 0.8.2 (2022-10-12)

- Advise to use 32 MB memory, which is sufficient (#150, @palainp)
- Improve documentation (#150, @palainp)
- Remove unneeded memory management code and log messages (#150, @palainp)
- Use mirage-nat 3.0.0, remove global mutable state (#151, @hannesm)

### 0.8.1 (2022-09-14)

- support qrexec protocol version 3 (@reynir @palainp in mirage-qubes 0.9.3)
- remove special DNS rule (which used to be required for Qubes 3, issue #63, fix #142, @hannesm)
- use DNS servers from QubesDB instead of hardcoded ones for evaluation of the DNS rule (#142 @hannesm)
- remove the GUI code (not needed in Qubes 4.1 anymore, issue #62, fix #144, @palainp)
- trigger GC slightly earlier (at < 50% free space, issue #143, fix #147, @palainp)

### 0.8.0

The major change is to use PVH instead of PV. The effort was in solo5 (https://github.com/solo5/solo5) which since 0.6.6 supports Xen and PVH (developed by @mato, with some fixes (multiboot, mem size computed uniformly, not skipping first token of command line arguments) by @marmarek, @xaki23, @palainp, and @hannesm).

Another user-visible change is that the DNS resolver is read from QubesDB /qubes-primary-dns instead of using a hardcoded IP address (@palainp and @hannesm).

Also, the qrexec version negotiation has been implemented (in mirage-qubes by @reynir).

Thanks to @palainp and @winux138 keeping track of memory allocation has been improved, and also memory can be freed now.

This release uses the latest mirage release (4.2.1). It can be built with a Fedora 35 container. It uses OCaml 4.14.0.

Thanks to @talex5 for lots of code cleanups, reviews, and merges. Also thanks to @xaki23 for early and detailed feedback. Testing was done by @Tommytran732 and @Szewcson. Thanks to @burghardt for documentation improvements.

### 0.7.1

Bugfixes:

- More robust parsing of IP address in Xenstore, which may contain both IPv4 and IPv6 addresses (@linse, #103, reported by @grote)

- Avoid stack overflow with many connections in the NAT table (@linse and @hannesm, reported by @talex5 in #105, fixed by mirage-nat 2.2.2 release)

### 0.7

This version adapts qubes-mirage-firewall with
- dynamic rulesets via QubesDB (as defined in Qubes 4.0), and
- adds support for DNS hostnames in rules, using the pf-qubes library for parsing.

The DNS client is provided by DNS (>= 4.2.0) which uses a cache for name lookups. Not every packet will lead to a DNS lookup if DNS rules are in place.

A test unikernel is available in the test subdirectory.

This project was done by @linse and @yomimono in summer 2019, see PR #96.

Additional changes and bugfixes:

- Support Mirage 3.7 and mirage-nat 2.0.0 (@hannesm, #89).
  The main improvement is fragmentation and reassembly support.

- Use the smaller OCurrent images as the base for building the Docker images (@talex5, #80).
  - Before: 1 GB (ocaml/opam2:debian-10-ocaml-4.08)
  - Now: 309 MB (ocurrent/opam:alpine-3.10-ocaml-4.08)

- Removed unreachable `Lwt.catch` (@hannesm, #90).

Documentation:

- Add note that AppVM used to build from source may need a private image larger than the default 2048MB (@marmot1791, #83).

- README: create the symlink-redirected docker dir (@xaki23, #75). Otherwise, installing the docker package removes the dangling symlink.

- Note that mirage-firewall cannot be used as UpdateVM (@talex5, #68).

- Fix ln(1) call in build instructions (@jaseg, #69). The arguments were backwards.

Keeping up with upstream changes:

- Support mirage-3.7 via qubes-builder (@xaki23, #91).

- Remove unused `Clock` argument to `Uplink` (@talex5, #90).

- Rename things for newer mirage-xen versions (@xaki23, #80).

- Adjust to ipaddr-4.0.0 renaming `_bytes` to `_octets` (@xaki23, #75).

- Use OCaml 4.08.0 for qubes-builder builds (was 4.07.1) (@xaki23, #75).

- Remove netchannel pin as 1.11.0 is now released (@talex5, #72).

- Remove cmdliner pin as 1.0.4 is now released (@talex5, #71).


### 0.6

Changes to rules language:

- Allow naming hosts (@talex5, #54).
  Previously, we passed in the interface, from which it was possible (but a
  little difficult) to extract the IP address and compare with some predefined
  ones. Now, we allow the user to list IP addresses and named tags for them,
  which can be matched on easily.

- Add some types to the rules (@talex5, #54).
  Before, we inferred the types from `rules.ml` and then the compiler checked that
  it was consistent with what `firewall.ml` expected. If it wasn't then it
  reported the problem as being with `firewall.ml`, which could be confusing to
  users.

- Give exact types for `Packet.src` (@talex5, #54).
  Before, the packet passed to `rules.ml` could have any host as its `src`.
  Now, `from_client` knows that `src` must be a `Client`,
  and `from_netvm` knows that `src` is `External` or `NetVM`.

- Combine `Client_gateway` and `Firewall_uplink` (@talex5, #64).
  Before, we used `Client_gateway` for the IP address of the firewall on the client network
  and `Firewall_uplink` for its address on the uplink network.
  However, Qubes 4 uses the same IP address for both, so we can't separate these any longer,
  and there doesn't seem to be any advantage to keeping them separate anyway.

Bug fixes:

- Upgrade to latest mirage-nat to fix ICMP (@yomimono, @linse, #55).
  Now ping and traceroute should work. Reported by @xaki23.

- Respond to ARP requests for `*.*.*.1` (@talex5, #61).
  This is a work-around to get DHCP working with HVM domains.
  Reported by @cgchinicz.
  See: https://github.com/QubesOS/qubes-issues/issues/5022

- Force backend MAC to `fe:ff:ff:ff:ff:ff` to fix HVM clients (@talex5, #61).
  Xen appears to configure the same MAC address for both the frontend and
  backend in XenStore. This works if the client uses just a simple ethernet
  device, but fails if it connects via a bridge. HVM domains have an associated
  stub domain running qemu, which provides an emulated network device. The stub
  domain uses a bridge to connect qemu's interface with eth0, and this didn't
  work. Force the use of the fixed version of mirage-net-xen, which no longer
  uses XenStore to get the backend MAC, and provides a new function to get the
  frontend one.

- Wait if dom0 is slow to set the network configuration (@talex5, #60).
  Sometimes we boot before dom0 has put the network settings in QubesDB.
  If that happens, log a message, wait until the database changes, and retry.

Reproducible builds:

- Add patch to cmdliner for reproducible build (@talex5, #52).
  See https://github.com/dbuenzli/cmdliner/pull/106

- Use source date in .tar.bz2 archive (@talex5, #49).
  All files are now added using the date the `build-with-docker` script was last changed.
  Since this includes the hash of the result, it should be up-to-date.
  This ensures that rebuilding the archive doesn't change it in any way.
  Reported by Holger Levsen.

Documentation changes:

- Added example rules showing how to block access to an external service or
  allow SSH between AppVMs (@talex5, #54). Requested at
  https://groups.google.com/d/msg/qubes-users/BnL0nZGpJOE/61HOBg1rCgAJ.

- Add overview of the main components of the firewall in the README (@talex5, #54).

- Link to security advisories from README (@talex5, #58).

- Clarify how to build from source (@talex5, #51).

- Remove Qubes 3 instructions (@talex5, #48).
  See https://www.qubes-os.org/news/2019/03/28/qubes-3-2-has-reached-eol/

### 0.5

- Update to the latest mirage-net-xen, mirage-nat and tcpip libraries (@yomimono, @talex5, #45, #47).
  In iperf benchmarks between a client VM and sys-net, this more than doubled the reported bandwidth!

- Don't wait for the Qubes GUI daemon to connect before attaching client VMs (@talex5, #38).
  If the firewall is restarted while AppVMs are connected, qubesd tries to
  reconnect them before starting the GUI agent. However, the firewall was
  waiting for the GUI agent to connect before handling the connections. This
  led to a 10s delay on restart for each client VM. Reported by @xaki23.

- Add stub makefile for qubes-builder (@xaki23, #37).

- Update build instructions for latest Fedora (@talex5, #36). `yum` no longer exists.
  Also, show how to create a symlink for `/var/lib/docker` on build VMs that aren't standalone.
  Reported by @xaki23.

- Add installation instructions for Qubes 4 (@yomimono, @reynir, @talex5, #27).

- Use `Ethernet_wire.sizeof_ethernet` instead of a magic `14` (@hannesm, #46).

### 0.4

- Add support for HVM guests (needed for Qubes 4).

- Add support for disposable VMs.

- Drop frames if an interface's queue gets too long.

- Show the packet when failing to add a NAT rule. The previous message was
  just: `WRN [firewall] Failed to add NAT rewrite rule: Cannot NAT this packet`

### 0.3

- Add support for NAT of ICMP queries (e.g. pings) and errors (e.g. "Host unreachable").
  Before, these packets would be dropped.

- Use an LRU cache to avoid running out of memory and needing to reset the table.
  Should avoid any more out-of-memory bugs.

- Pass around parsed packets rather than raw ethernet frames.

- Pin Docker base image to a specific hash. Requested by Joanna Rutkowska.

- Update for Mirage 3.

- Remove non-Docker build instructions. Fedora 24 doesn't work with opam
  (because the current binary release of aspcud's clasp binary segfaults, which
  opam reports as `External solver failed with inconsistent return value.`).

### 0.2

Build:

- Add option to build with Docker. This fixes opam-repository to a known commit
  for reproducible builds. It also displays the actual and expected SHA hashes
  after building.

Bug fixes:

- Updated README: the build also requires "patch". Reported by William Waites.
- Monitor set of client interfaces, not client domains. Qubes does not remove
  the client directory itself when the domain exits. This prevented clients
  from reconnecting. This may also make it possible to connect clients to the
  firewall via multiple interfaces, although this doesn't seem useful.
- Handle errors writing to client. mirage-net-xen would report `Netback_shutdown`
  if we tried to write to a client after it had disconnected. Now we just log
  this and continue.
- Ensure that old client has quit before adding new one. Not sure if this can
  happen, but it removes a TODO from the code.
- Allow clients to have any IP address. We previously assumed that Qubes would
  always give clients IP addresses on a particular network. However, it is not
  required to do this and in fact uses a different network for disposable VMs.
  With this change:
  - We no longer reject clients with unknown IP addresses.
  - The `Unknown_client` classification is gone; we have no way to tell the
    difference between a client that isn't connected and an external address.
  - We now consider every client to be on a point-to-point link and do not
    answer ARP requests on behalf of other clients. Clients should assume their
    netmask is `255.255.255.255` (and ignore `/qubes-netmask`). This allows
    disposable VMs to connect to the firewall but for some reason they don't
    process any frames we send them (we get their ARP requests but they don't
    get our replies). Taking eth0 down in the disp VM, then bringing it back up
    (and re-adding the routes) allows it to work.
- Cope with writing a frame failing. If a client disconnects suddenly then we
  may get an error trying to map its grant to send the frame.
- Survive death of our GUId connection to dom0. We don't need the GUI anyway.
- Handle `Out_of_memory` adding NAT entries. Because hash tables resize in big
  steps, this can happen even if we have a fair chunk of free memory.
- Calculate checksums even for `Accept` action. If packet has been NAT'd then we
  certainly need to recalculate the checksum, but even for direct pass-through
  it might have been received with an invalid checksum due to checksum offload.
  For now, recalculate full checksum in all cases.
- Log correct destination for redirected packets. Before, we always said it was
  going to "NetVM".
- If we can't find a free port, reset the NAT table.
- Reset NAT table if memory gets low.

Other changes:

- Report current memory use to XenStore.
- Reduce logging verbosity.
- Avoid using `Lwt.join` on listening threads.
  `Lwt.join` only reports an error if _both_ threads fail.
- Keep track of transmit queue lengths. Log if we have to wait to send a frame.
- Use mirage-logs library for log reporter.
- Respond to `WaitForSession` commands (we're always ready!).
- Log `SetDateTime` messages from dom0 (we still don't actually update our clock,
  though).

Updates for upstream library changes:

- Updates for mirage 2.9.0.
  - Use new name for uplink device (`0`, not `tap0`).
  - Don't configure logging - mirage does that for us now.
- Remove tcpip pin. The 2.7.0 release has the checksum feature we need.
- Remove mirage-xen pin. mirage-xen 2.4.0 has been released with the required
  features (also fixes indentation problem reported by @cfcs).
- Add ncurses-dev to required yum packages. The ocamlfind package has started
  listing this as a required dependency for some reason, although it appears
  not to need it. Reported by cyrinux.
- Add work-around for Qubes passing Linux kernel arguments. With the new
  Functoria release of Mirage, these unrecognised arguments prevented the
  unikernel from booting. See: https://github.com/mirage/mirage/issues/493
- Remove mirage-logs pin. Now available from the main repository.
- Remove mirage-qubes pin.
  mirage-qubes 0.2 has been released, and supports the latests Logs API.
- Remove mirage-net-xen pin.
  Version 1.5 has now been released, and includes netback support.
- Update to new Logs API.
- Remove pin for mirage-clock-xen. New version has been released now.

### 0.1

Initial release.
