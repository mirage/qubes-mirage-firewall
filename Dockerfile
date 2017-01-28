FROM ocaml/opam:debian-8_ocaml-4.03.0

# Pin last known-good version for reproducible builds.
# Remove this line if you want to test with the latest versions.
RUN cd opam-repository && git reset --hard 0f17b354206c97e729700ce60ddce3789ccb1d52 && opam update

RUN sudo apt-get install -y m4 libxen-dev
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage
RUN opam pin add -n -y mirage-nat 'https://github.com/talex5/mirage-nat.git#simplify-checksum'
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure --xen
CMD opam config exec -- mirage configure --xen --no-opam && \
    opam config exec -- make tar
