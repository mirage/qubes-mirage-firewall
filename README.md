# qubes-mirage-firewall

A unikernel that can run as a QubesOS ProxyVM, replacing `sys-firewall`.
It uses the [mirage-qubes][] library to implement the Qubes protocols.

See [A Unikernel Firewall for QubesOS][] for more details.


## Binary releases

Pre-built binaries are available from the [releases page][].
See the [Deploy](#deploy) section below for installation instructions.

## Build from source

Note: The most reliable way to build is using Docker.
Fedora 38 works well for this, Debian 11 also works (and Debian 12 should), but you'll need to follow the instructions at [docker.com][debian-docker] to get Docker
(don't use Debian's version).

Create a new Fedora-38 AppVM (or reuse an existing one). In the Qube's Settings (Basic / Disk storage), increase the private storage max size from the default 2048 MiB to 4096 MiB. Open a terminal.

Clone this Git repository and run the `build-with-docker.sh` script (Note: The `chcon` call is mandatory with new SELinux policies which do not allow to standardly keep the images in homedir):

    mkdir /home/user/docker
    sudo ln -s /home/user/docker /var/lib/docker
    sudo chcon -Rt container_file_t /home/user/docker
    sudo dnf install docker
    sudo systemctl start docker
    git clone https://github.com/mirage/qubes-mirage-firewall.git
    cd qubes-mirage-firewall
    sudo ./build-with-docker.sh

This took about 10 minutes on my laptop (it will be much quicker if you run it again).
The symlink step at the start isn't needed if your build VM is standalone.
It gives Docker more disk space and avoids losing the Docker image cache when you reboot the Qube.

Note: the object files are stored in the `_build` directory to speed up incremental builds.
If you change the dependencies, you will need to delete this directory before rebuilding.

It's OK to install the Docker package in a template VM if you want it to remain
after a reboot, but the build of the firewall itself should be done in a regular AppVM.

You can also build without Docker, as for any normal Mirage unikernel;
see [the Mirage installation instructions](https://mirage.io/wiki/install) for details.

The Docker build fixes the versions of the libraries it uses, ensuring that you will get
exactly the same binary that is in the release. If you build without Docker, it will build
against the latest versions instead (and the hash will therefore probably not match).
However, it should still work fine.

## Deploy

### Manual deployment
If you want to deploy manually, unpack `mirage-firewall.tar.bz2` in domU. The tarball contains `vmlinuz`,
which is the unikernel itself, plus a dummy initramfs file that Qubes requires:

    [user@dev ~]$ tar xjf mirage-firewall.tar.bz2

Copy `vmlinuz` to `/var/lib/qubes/vm-kernels/mirage-firewall` directory in dom0, e.g. (if `dev` is the AppVM where you built it):

    [tal@dom0 ~]$ mkdir -p /var/lib/qubes/vm-kernels/mirage-firewall/
    [tal@dom0 ~]$ cd /var/lib/qubes/vm-kernels/mirage-firewall/
    [tal@dom0 mirage-firewall]$ qvm-run -p dev 'cat mirage-firewall/vmlinuz' > vmlinuz

Finally, create [a dummy file required by Qubes OS](https://github.com/QubesOS/qubes-issues/issues/5516):

    [tal@dom0 mirage-firewall]$ gzip -n9 < /dev/null > initramfs

Run this command in dom0 to create a `mirage-firewall` VM using the `mirage-firewall` kernel you added above

```
qvm-create \
  --property kernel=mirage-firewall \
  --property kernelopts='' \
  --property memory=64 \
  --property maxmem=64 \
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

Copyright (c) 2019, Thomas Leonard
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[test-mirage]: https://github.com/talex5/qubes-test-mirage
[mirage-qubes]: https://github.com/mirage/mirage-qubes
[A Unikernel Firewall for QubesOS]: http://roscidus.com/blog/blog/2016/01/01/a-unikernel-firewall-for-qubesos/
[releases page]: https://github.com/mirage/qubes-mirage-firewall/releases
[debian-docker]: https://docs.docker.com/install/linux/docker-ce/debian/#install-using-the-repository
