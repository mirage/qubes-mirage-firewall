# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian 8
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam:debian-8_ocaml-4.04.2
FROM ocaml/opam@sha256:17a527319b850bdaf6759386a566dd088a053758b6d0603712dbcb10ad62f86c

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd opam-repository && git fetch origin && git reset --hard ad6348231fa14e1d9df724db908a1b7fe07d3ab9 && opam update

RUN sudo apt-get install -y m4 libxen-dev
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage mirage-nat
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
