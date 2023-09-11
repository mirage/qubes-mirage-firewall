# How to install the superlight mirage-firewall for Qubes OS by using saltstack
# Tested on Qubes v4.1 and mirage v0.8.5
# After the install, you have to switch your AppVMs to use the mirage firewall vm created by this script e.g. by using "Qubes Global Settings"
# inspired by: https://github.com/one7two99/my-qubes/tree/master/mirage-firewall

# default template + dispvm template are used. Possible optimization is to use min-dvms
{% set DownloadVMTemplate = salt['cmd.shell']("qubes-prefs default_template") %}
{% set DispVM = salt['cmd.shell']("qubes-prefs default_dispvm") %}

{% set DownloadVM = "DownloadVmMirage" %}
{% set MirageFW = "sys-mirage-fw" %}
{% set GithubUrl = "https://github.com/mirage/qubes-mirage-firewall" %}
{% set Filename = "mirage-firewall.tar.bz2" %}
{% set MirageInstallDir = "/var/lib/qubes/vm-kernels/mirage-firewall" %}

#download and install the latest version
{% set Release = salt['cmd.shell']("qvm-run --dispvm " ~ DispVM ~ " --pass-io \"curl --silent --location -o /dev/null -w %{url_effective} " ~ GithubUrl ~ "/releases/latest | rev | cut -d \"/\" -f 1 | rev\"") %}

{% if Release != salt['cmd.shell']("[ ! -f " ~ MirageInstallDir ~ "/version.txt" ~ " ] && touch " ~ MirageInstallDir ~ "/version.txt" ~ ";cat " ~ MirageInstallDir ~ "/version.txt") %}

create-downloader-VM:
  qvm.vm:
     - name: {{ DownloadVM }}
     - present:
       - template: {{ DownloadVMTemplate }}
       - label: red
     - prefs:
       - template: {{ DownloadVMTemplate }}
       - include-in-backups: false

{% set DownloadBinary = GithubUrl ~ "/releases/download/" ~ Release ~ "/" ~ Filename %}

download-and-unpack-in-DownloadVM4mirage:
  cmd.run: 
    - names:
      - qvm-run --pass-io {{ DownloadVM }} {{ "curl -L -O " ~ DownloadBinary }}
      - qvm-run --pass-io {{ DownloadVM }} {{ "tar -xvjf " ~ Filename }}
    - require: 
      - create-downloader-VM


check-checksum-in-DownloadVM:
  cmd.run: 
    - names:
      - qvm-run --pass-io {{ DownloadVM }} {{ "\"echo \\\"Checksum of last build on github:\\\";curl -s https://raw.githubusercontent.com/mirage/qubes-mirage-firewall/main/build-with-docker.sh  | grep \\\"SHA2 last known:\\\" | cut -d\' \' -f5 | tr -d \\\\\\\"\"" }}
      - qvm-run --pass-io {{ DownloadVM }} {{ "\"echo \\\"Checksum of downloaded local file:\\\";sha256sum ~/mirage-firewall/vmlinuz | cut -d\' \' -f1\"" }}
      - qvm-run --pass-io {{ DownloadVM }} {{ "\"diff <(curl -s https://raw.githubusercontent.com/mirage/qubes-mirage-firewall/main/build-with-docker.sh  | grep \\\"SHA2 last known:\\\" | cut -d\' \' -f5 | tr -d \\\\\\\") <(sha256sum ~/mirage-firewall/vmlinuz | cut -d\' \' -f1) && echo \\\"Checksums DO match.\\\" || (echo \\\"Checksums do NOT match.\\\";exit 101)\"" }} #~/mirage-firewall/modules.img
    - require: 
      - download-and-unpack-in-DownloadVM4mirage

copy-mirage-kernel-to-dom0:
  cmd.run: 
    - name: mkdir -p {{ MirageInstallDir }}; qvm-run --pass-io --no-gui {{ DownloadVM }} "cat ~/mirage-firewall/vmlinuz" > {{ MirageInstallDir ~ "/vmlinuz" }}
    - require: 
      - download-and-unpack-in-DownloadVM4mirage
      - check-checksum-in-DownloadVM

create-initramfs:
  cmd.run: 
    - names: 
      - gzip -n9 < /dev/null > {{ MirageInstallDir ~ "/initramfs" }}
      - echo {{ Release }} > {{ MirageInstallDir ~ "/version.txt" }}
    - require: 
      - copy-mirage-kernel-to-dom0

create-sys-mirage-fw:
  qvm.vm:
    - name: {{ MirageFW }}
    - present:
      - class: StandaloneVM
      - label: black
    - prefs:
      - kernel: mirage-firewall
      - kernelopts:
      - include-in-backups: False
      - memory: 64
      - maxmem: 64
      - netvm: sys-net
      - provides-network: True
      - vcpus: 1
      - virt-mode: pvh
    - features:
      - enable:
        - qubes-firewall
        - no-default-kernelopts
    - require: 
      - copy-mirage-kernel-to-dom0


cleanup-in-DownloadVM:
  cmd.run:
   - names:
      - qvm-run -a --pass-io --no-gui {{ DownloadVM }} "{{ "rm " ~ Filename ~ "; rm -R ~/mirage-firewall" }}"
   - require: 
     - create-initramfs

remove-DownloadVM4mirage:
  qvm.absent:
    - name: {{ DownloadVM }}
    - require: 
      - cleanup-in-DownloadVM

{% endif %}
