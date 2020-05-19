MIRAGE_KERNEL_NAME = qubes_firewall.xen
OCAML_VERSION ?= 4.10.0
SOURCE_BUILD_DEP := firewall-build-dep

firewall-build-dep:
	opam install -y depext
	opam depext -i -y mirage.3.7.7 lwt.5.3.0

