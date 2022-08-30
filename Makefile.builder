MIRAGE_KERNEL_NAME = dist/qubes-firewall.xen
OCAML_VERSION ?= 4.14.0
SOURCE_BUILD_DEP := firewall-build-dep

firewall-build-dep:
	opam install -y mirage

