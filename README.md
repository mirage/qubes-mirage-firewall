# qubes-mirage-firewall

A unikernel that can run as a QubesOS ProxyVM, replacing `sys-firewall`.
It uses the [mirage-qubes][] library to implement the Qubes protocols.

Note: This firewall *ignores the rules set in the Qubes GUI*. See `rules.ml` for the actual policy.

See [A Unikernel Firewall for QubesOS][] for more details.


## Binary releases

Pre-built binaries are available from the [releases page][].

## Build from source

Clone this Git repository and run the `build-with-docker.sh` script:

    sudo ln -s /var/lib/docker /home/user/docker
    sudo dnf install docker
    sudo systemctl start docker
    git clone https://github.com/talex5/qubes-mirage-firewall.git
    cd qubes-mirage-firewall
    sudo ./build-with-docker.sh

This took about 10 minutes on my laptop (it will be much quicker if you run it again).
The symlink step at the start isn't needed if your build VM is standalone.
It gives Docker more disk space and avoids losing the Docker image cache when you reboot the Qube.

Note: the object files are stored in the `_build` directory to speed up incremental builds.
If you change the dependencies, you will need to delete this directory before rebuilding.

You can also build without Docker, as for any normal Mirage unikernel;
see [the Mirage installation instructions](https://mirage.io/wiki/install) for details.

## Deploy

If you want to deploy manually, unpack `mirage-firewall.tar.bz2` in dom0, inside `/var/lib/qubes/vm-kernels/`. e.g. (if `dev` is the AppVM where you built it):

    [tal@dom0 ~]$ cd /var/lib/qubes/vm-kernels/
    [tal@dom0 vm-kernels]$ qvm-run -p dev 'cat qubes-mirage-firewall/mirage-firewall.tar.bz2' | tar xjf -

The tarball contains `vmlinuz`, which is the unikernel itself, plus a couple of dummy files that Qubes requires.

### Qubes 3

To configure your new firewall using the Qubes 3 Manager GUI:

- Create a new ProxyVM named `mirage-firewall` to run the unikernel.
- You can use any template, and make it standalone or not. It doesn’t matter, since we don’t use the hard disk.
- Set the type to `ProxyVM`.
- Select `sys-net` for networking (not `sys-firewall`).
- Click `OK` to create the VM.
- Go to the VM settings, and look in the `Advanced` tab:
  - Set the kernel to `mirage-firewall`.
  - Turn off memory balancing and set the memory to 32 MB or so (you might have to fight a bit with the Qubes GUI to get it this low).
  - Set VCPUs (number of virtual CPUs) to 1.

### Qubes 4

Run this command in dom0 to create a `mirage-firewall` VM using the `mirage-firewall` kernel you added above:

```
qvm-create \
  --property kernel=mirage-firewall \
  --property kernelopts=None \
  --property memory=32 \
  --property maxmem=32 \
  --property netvm=sys-net \
  --property provides_network=True \
  --property vcpus=1 \
  --property virt_mode=pv \
  --label=green \
  --class StandaloneVM \
  mirage-firewall
```

### Configure AppVMs to use it

You can run `mirage-firewall` alongside your existing `sys-firewall` and you can choose which AppVMs use which firewall using the GUI.
To configure an AppVM to use it, go to the app VM's settings in the GUI and change its `NetVM` from `default (sys-firewall)` to `mirage-firewall`.

You can also configure it by running this command in dom0 (replace `my-app-vm` with the AppVM's name):

```
qvm-prefs --set my-app-vm netvm mirage-firewall
```

Alternatively, you can configure `mirage-firewall` to be your default firewall VM.

### Easy deployment for developers

For development, use the [test-mirage][] scripts to deploy the unikernel (`qubes_firewall.xen`) from your development AppVM.
This takes a little more setting up the first time, but will be much quicker after that. e.g.

    $ test-mirage qubes_firewall.xen mirage-firewall
    Waiting for 'Ready'... OK
    Uploading 'qubes_firewall.xen' (5901080 bytes) to "mirage-firewall"
    Waiting for 'Booting'... OK
    --> Loading the VM (type = ProxyVM)...
    --> Starting Qubes DB...
    --> Setting Qubes DB info for the VM...
    --> Updating firewall rules...
    --> Starting the VM...
    --> Starting the qrexec daemon...
    Waiting for VM's qrexec agent.connected
    --> Starting Qubes GUId...
    Connecting to VM's GUI agent: .connected
    --> Sending monitor layout...
    --> Waiting for qubes-session...
    Connecting to mirage-firewall console...
    MirageOS booting...
    Initialising timer interface
    Initialising console ... done.
    gnttab_stubs.c: initialised mini-os gntmap
    2017-03-18 11:32:37 -00:00: INF [qubes.rexec] waiting for client...
    2017-03-18 11:32:37 -00:00: INF [qubes.gui] waiting for client...
    2017-03-18 11:32:37 -00:00: INF [qubes.db] connecting to server...
    2017-03-18 11:32:37 -00:00: INF [qubes.db] connected
    2017-03-18 11:32:37 -00:00: INF [qubes.rexec] client connected, using protocol version 2
    2017-03-18 11:32:37 -00:00: INF [qubes.db] got update: "/qubes-keyboard" = "xkb_keymap {\n\txkb_keycodes  { include \"evdev+aliases(qwerty)\"\t};\n\txkb_types     { include \"complete\"\t};\n\txkb_compat    { include \"complete\"\t};\n\txkb_symbols   { include \"pc+gb+inet(evdev)\"\t};\n\txkb_geometry  { include \"pc(pc105)\"\t};\n};"
    2017-03-18 11:32:37 -00:00: INF [qubes.gui] client connected (screen size: 6720x2160)
    2017-03-18 11:32:37 -00:00: INF [unikernel] Qubes agents connected in 0.095 s (CPU time used since boot: 0.008 s)
    2017-03-18 11:32:37 -00:00: INF [net-xen:frontend] connect 0
    2017-03-18 11:32:37 -00:00: INF [memory_pressure] Writing meminfo: free 6584 / 17504 kB (37.61 %)
    Note: cannot write Xen 'control' directory
    2017-03-18 11:32:37 -00:00: INF [net-xen:frontend] create: id=0 domid=1
    2017-03-18 11:32:37 -00:00: INF [net-xen:frontend]  sg:true gso_tcpv4:true rx_copy:true rx_flip:false smart_poll:false
    2017-03-18 11:32:37 -00:00: INF [net-xen:frontend] MAC: 00:16:3e:5e:6c:11
    2017-03-18 11:32:37 -00:00: WRN [command] << Unknown command "QUBESRPC qubes.SetMonitorLayout dom0"
    2017-03-18 11:32:38 -00:00: INF [ethif] Connected Ethernet interface 00:16:3e:5e:6c:11
    2017-03-18 11:32:38 -00:00: INF [arpv4] Connected arpv4 device on 00:16:3e:5e:6c:11
    2017-03-18 11:32:38 -00:00: INF [dao] Watching backend/vif
    2017-03-18 11:32:38 -00:00: INF [qubes.db] got update: "/qubes-netvm-domid" = "1"


# LICENSE

Copyright (c) 2018, Thomas Leonard
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
gg

[test-mirage]: https://github.com/talex5/qubes-test-mirage
[mirage-qubes]: https://github.com/talex5/mirage-qubes
[A Unikernel Firewall for QubesOS]: http://roscidus.com/blog/blog/2016/01/01/a-unikernel-firewall-for-qubesos/
[releases page]: https://github.com/talex5/qubes-mirage-firewall/releases
