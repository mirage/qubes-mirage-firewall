# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam2:debian-9-ocaml-4.07
FROM ocaml/opam2@sha256:74fb6e30a95e1569db755b3c061970a8270dfc281c4e69bffe2cf9905d356b38

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN git fetch origin && git reset --hard 3389beb33b37da54c9f5a41f19291883dfb59bfb && opam update

RUN sudo apt-get install -y m4 libxen-dev pkg-config
RUN opam install -y mirage lwt
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
