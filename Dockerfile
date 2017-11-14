# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian 8
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam:debian-8_ocaml-4.04.2
FROM ocaml/opam@sha256:17143ad95a2e944758fd9de6ee831e9af98367455cd273b17139c38dcb032f09

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd opam-repository && git fetch origin && git reset --hard 67ab04a9a142da70935c9fdf919bf09b517499c9 && opam update

RUN sudo apt-get install -y m4 libxen-dev
# TODO: remove this once the new versions are released (mnx>1.7.1)
RUN opam pin add -yn --dev netchannel
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage mirage-nat mirage-qubes
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
