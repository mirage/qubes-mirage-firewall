# qubes-mirage-firewall

A unikernel that can run as a QubesOS ProxyVM, replacing `sys-firewall`.
It uses the [mirage-qubes][] library to implement the Qubes protocols.

See [A Unikernel Firewall for QubesOS][] for more details.


## Binary releases

Pre-built binaries are available from the [releases page][].
See the [Deploy](#deploy) section below for installation instructions.

## Build from source

Note: The most reliable way to build is using Docker or Podman.
Fedora 38 works well for this, Debian 12 also works, but you'll need to follow the instructions at [docker.com][debian-docker] to get Docker
(don't use Debian's version).

Create a new Fedora-38 AppVM (or reuse an existing one). In the Qube's Settings (Basic / Disk storage), increase the private storage max size from the default 2048 MiB to 8192 MiB. Open a terminal.

Clone this Git repository and run the `build-with.sh` script with either `docker` or `podman` as argument (Note: The `chcon` call is mandatory on Fedora with new SELinux policies which do not allow to standardly keep the docker images in homedir):

    mkdir /home/user/docker
    sudo ln -s /home/user/docker /var/lib/docker
    sudo chcon -Rt container_file_t /home/user/docker
    sudo dnf install docker
    sudo systemctl start docker
    git clone https://github.com/mirage/qubes-mirage-firewall.git
    cd qubes-mirage-firewall
    sudo ./build-with.sh docker

Or

    sudo systemctl start podman
    git clone https://github.com/mirage/qubes-mirage-firewall.git
    cd qubes-mirage-firewall
    ./build-with.sh podman

This took about 15 minutes on my laptop (it will be much quicker if you run it again).
The symlink step at the start isn't needed if your build VM is standalone. It gives Docker more disk space and avoids losing the Docker image cache when you reboot the Qube.
It's not needed with Podman as the containers lives in your home directory by default.

Note: the object files are stored in the `_build` directory to speed up incremental builds.
If you change the dependencies, you will need to delete this directory before rebuilding.

It's OK to install the Docker or Podman package in a template VM if you want it to remain
after a reboot, but the build of the firewall itself should be done in a regular AppVM.

You can also build without that script, as for any normal Mirage unikernel;
see [the Mirage installation instructions](https://mirage.io/wiki/install) for details.

The build script fixes the versions of the libraries it uses, ensuring that you will get
exactly the same binary that is in the release. If you build without it, it will build
against the latest versions instead (and the hash will therefore probably not match).
However, it should still work fine.

## Deploy

### Manual deployment
If you want to deploy manually, you just need to download `qubes-firewall.xen` and
`qubes-firewall.sha256` in domU and check that the `.xen` file has a corresponding
hashsum. `qubes-firewall.xen` is the unikernel itself and should be copied to
`vmlinuz` in the `/var/lib/qubes/vm-kernels/mirage-firewall` directory in dom0, e.g.
(if `dev` is the AppVM where you built it):

    [tal@dom0 ~]$ mkdir -p /var/lib/qubes/vm-kernels/mirage-firewall/
    [tal@dom0 ~]$ cd /var/lib/qubes/vm-kernels/mirage-firewall/
    [tal@dom0 mirage-firewall]$ qvm-run -p dev 'cat mirage-firewall/qubes-firewall.xen' > vmlinuz

Run this command in dom0 to create a `mirage-firewall` VM using the `mirage-firewall` kernel you added above

```
qvm-create \
  --property kernel=mirage-firewall \
  --property kernelopts='' \
  --property memory=32 \
  --property maxmem=32 \
  --property netvm=sys-net \
  --property provides_network=True \
  --property vcpus=1 \
  --property virt_mode=pvh \
  --label=green \
  --class StandaloneVM \
  mirage-firewall

qvm-features mirage-firewall qubes-firewall 1
qvm-features mirage-firewall no-default-kernelopts 1
```

### Deployment using saltstack
If you're familiar how to run salt states in Qubes, you can also use the script `SaltScriptToDownloadAndInstallMirageFirewallInQubes.sls` to automatically deploy the latest version of mirage firewall in your Qubes OS. An introduction can be found [here](https://forum.qubes-os.org/t/qubes-salt-beginners-guide/20126) and [here](https://www.qubes-os.org/doc/salt/). Following the instructions from the former link, you can run the script in dom0 with the command `sudo qubesctl --show-output state.apply SaltScriptToDownloadAndInstallMirageFirewallInQubes saltenv=user`. The script checks the checksum from the integration server and compares with the latest version provided in the github releases. It might be necessary to adjust the VM templates in the script which are used for downloading of the mirage unikernel, if your default templates do not have the tools `curl` and `tar` installed by default. Also don't forget to change the VMs in which the uni kernel should be used or adjust the "Qubes Global Settings".

## Upgrading

To upgrade from an earlier release, just overwrite `/var/lib/qubes/vm-kernels/mirage-firewall/vmlinuz` with the new version and restart the firewall VM.

### Configure AppVMs to use it

You can run `mirage-firewall` alongside your existing `sys-firewall` and you can choose which AppVMs use which firewall using the GUI.
To configure an AppVM to use it, go to the app VM's settings in the GUI and change its `NetVM` from `default (sys-firewall)` to `mirage-firewall`.

You can also configure it by running this command in dom0 (replace `my-app-vm` with the AppVM's name):

```
qvm-prefs --set my-app-vm netvm mirage-firewall
```

Alternatively, you can configure `mirage-firewall` to be your default firewall VM.

Note that by default dom0 uses sys-firewall as its "UpdateVM" (a proxy for downloading updates).
mirage-firewall cannot be used for this, but any Linux VM should be fine.
https://www.qubes-os.org/doc/software-update-dom0/ says:

> The role of UpdateVM can be assigned to any VM in the Qubes VM Manager, and
> there are no significant security implications in this choice. By default,
> this role is assigned to the firewallvm.

### Configure firewall with OpenBSD-like netvm

OpenBSD is currently unable to be used as netvm, so if you want to use a BSD as your sys-net VM, you'll need to set its netvm to qubes-mirage-firewall (see https://github.com/mirage/qubes-mirage-firewall/issues/146 for more information).
That means you'll have `AppVMs -> qubes-mirage-firewall <- OpenBSD` with the arrow standing for the netvm property setting.

In that case you'll have to tell qubes-mirage-firewall which AppVM client should be used as uplink:
```
qvm-prefs --set mirage-firewall -- kernelopts '--ipv4=X.X.X.X --ipv4-gw=Y.Y.Y.Y'
```
with `X.X.X.X` the IP address for mirage-firewall and `Y.Y.Y.Y` the IP address of your OpenBSD HVM.

### Components

This diagram show the main components (each box corresponds to a source `.ml` file with the same name):

<p align='center'>
  <img src="./diagrams/components.svg"/>
</p>

Ethernet frames arrives from client qubes (such as `work` or `personal`) or from `sys-net`.
Internet (IP) packets are sent to `firewall`, which consults the NAT table and the rules from QubesDB to decide what to do with the packet.
If it should be sent on, it uses `router` to send it to the chosen destination.
`client_net` watches the XenStore database provided by dom0
to find out when clients need to be added or removed.

The boot process:

- `config.ml` describes the libraries used and static configuration settings (NAT table size).
  The `mirage` tool uses this to generate `main.ml`.
- `main.ml` initialises the drivers selected by `config.ml`
  and calls the `start` function in `unikernel.ml`.
- `unikernel.ml` connects the Qubes agents, sets up the networking components,
  and then waits for a shutdown request.

### Easy deployment for developers

For development, use the [test-mirage][] scripts to deploy the unikernel (`qubes-firewall.xen`) from your development AppVM.
This takes a little more setting up the first time, but will be much quicker after that. e.g.

    [user@dev ~]$ test-mirage dist/qubes-firewall.xen mirage-firewall
    Waiting for 'Ready'... OK
    Uploading 'dist/qubes-firewall.xen' (7454880 bytes) to "mirage-test"
    Waiting for 'Booting'... OK
    Connecting to mirage-test console...
    Solo5: Xen console: port 0x2, ring @0x00000000FEFFF000
                |      ___|
      __|  _ \  |  _ \ __ \
    \__ \ (   | | (   |  ) |
    ____/\___/ _|\___/____/
    Solo5: Bindings version v0.7.3
    Solo5: Memory map: 32 MB addressable:
    Solo5:   reserved @ (0x0 - 0xfffff)
    Solo5:       text @ (0x100000 - 0x319fff)
    Solo5:     rodata @ (0x31a000 - 0x384fff)
    Solo5:       data @ (0x385000 - 0x53ffff)
    Solo5:       heap >= 0x540000 < stack < 0x2000000
    2022-08-13 14:55:38 -00:00: INF [qubes.rexec] waiting for client...
    2022-08-13 14:55:38 -00:00: INF [qubes.db] connecting to server...
    2022-08-13 14:55:38 -00:00: INF [qubes.db] connected
    2022-08-13 14:55:38 -00:00: INF [qubes.db] got update: "/mapped-ip/10.137.0.20/visible-ip" = "10.137.0.20"
    2022-08-13 14:55:38 -00:00: INF [qubes.db] got update: "/mapped-ip/10.137.0.20/visible-gateway" = "10.137.0.23"
    2022-08-13 14:55:38 -00:00: INF [qubes.rexec] client connected, using protocol version 3
    2022-08-13 14:55:38 -00:00: INF [unikernel] QubesDB and qrexec agents connected in 0.041 s
    2022-08-13 14:55:38 -00:00: INF [dao] Got network configuration from QubesDB:
                NetVM IP on uplink network: 10.137.0.4
                Our IP on uplink network:   10.137.0.23
                Our IP on client networks:  10.137.0.23
                DNS resolver:               10.139.1.1
                DNS secondary resolver:     10.139.1.2
    2022-08-13 14:55:38 -00:00: INF [net-xen frontend] connect 0
    2022-08-13 14:55:38 -00:00: INF [net-xen frontend] create: id=0 domid=1
    2022-08-13 14:55:38 -00:00: INF [net-xen frontend]  sg:true gso_tcpv4:true rx_copy:true rx_flip:false smart_poll:false
    2022-08-13 14:55:38 -00:00: INF [net-xen frontend] MAC: 00:16:3e:5e:6c:00
    2022-08-13 14:55:38 -00:00: INF [ethernet] Connected Ethernet interface 00:16:3e:5e:6c:00
    2022-08-13 14:55:38 -00:00: INF [ARP] Sending gratuitous ARP for 10.137.0.23 (00:16:3e:5e:6c:00)
    2022-08-13 14:55:38 -00:00: INF [ARP] Sending gratuitous ARP for 10.137.0.23 (00:16:3e:5e:6c:00)
    2022-08-13 14:55:38 -00:00: INF [udp] UDP layer connected on 10.137.0.23
    2022-08-13 14:55:38 -00:00: INF [dao] Watching backend/vif
    2022-08-13 14:55:38 -00:00: INF [memory_pressure] Writing meminfo: free 20MiB / 27MiB (72.68 %)

# Testing if the firewall works

A unikernel which tests the firewall is available in the `test/` subdirectory.
To use it, run `test.sh` and follow the instructions to set up the test environment.

# Security advisories

See [issues tagged "security"](https://github.com/mirage/qubes-mirage-firewall/issues?utf8=%E2%9C%93&q=label%3Asecurity+) for security advisories affecting the firewall.

# LICENSE

See [LICENSE.md](https://github.com/mirage/qubes-mirage-firewall/blob/main/LICENSE.md)

[test-mirage]: https://github.com/talex5/qubes-test-mirage
[mirage-qubes]: https://github.com/mirage/mirage-qubes
[A Unikernel Firewall for QubesOS]: http://roscidus.com/blog/blog/2016/01/01/a-unikernel-firewall-for-qubesos/
[releases page]: https://github.com/mirage/qubes-mirage-firewall/releases
[debian-docker]: https://docs.docker.com/install/linux/docker-ce/debian/#install-using-the-repository
