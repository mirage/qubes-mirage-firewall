# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian 8
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam:debian-8_ocaml-4.03.0
FROM ocaml/opam@sha256:48c025a4ec2e6ff6dcb4c14f8cae0f332a090fa1ed677170912c4a48627778ab

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd opam-repository && git reset --hard a51e30ffcec63836014a5bd2408203ec02e4c7af && opam update

RUN sudo apt-get install -y m4 libxen-dev
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage
RUN opam pin add -n -y mirage-nat 'https://github.com/talex5/mirage-nat.git#lru'
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
