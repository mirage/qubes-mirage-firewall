# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam2:debian-9-ocaml-4.07
FROM ocaml/opam2@sha256:5ff7e5a1d4ab951dcc26cca7834fa57dce8bb08d1d27ba67a0e51071c2197599

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN git fetch origin && git reset --hard 95448cbb9fad7515e104222f92b3d1e0bee70ede && opam update

RUN sudo apt-get install -y m4 libxen-dev pkg-config
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage mirage-nat mirage-qubes
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
