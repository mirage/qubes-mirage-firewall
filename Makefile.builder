MIRAGE_KERNEL_NAME = qubes_firewall.xen
OCAML_VERSION ?= 4.08.1
SOURCE_BUILD_DEP := firewall-build-dep

firewall-build-dep:
	opam pin -y add mirage 3.5.2

