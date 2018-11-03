# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam2:debian-9-ocaml-4.04
FROM ocaml/opam2@sha256:feebac4b6f9df9ed52ca1fe7266335cb9fdfffbdc0f6ba4f5e8603ece7e8b096

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN git fetch origin && git reset --hard 1fa4c078f5b145bd4a455eb0a5559f761d0a94c0 && opam update

RUN sudo apt-get install -y m4 libxen-dev pkg-config
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage mirage-nat mirage-qubes
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
