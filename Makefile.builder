MIRAGE_KERNEL_NAME = qubes_firewall.xen
SOURCE_BUILD_DEP := mfw-build-dep
OCAML_VERSION ?= 4.07.1

mfw-build-dep:
  opam pin -y add mirage 3.4.0
#	opam pin -y add ssh-agent https://github.com/reynir/ocaml-ssh-agent.git

