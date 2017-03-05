# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian 8
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam:debian-8_ocaml-4.03.0
FROM ocaml/opam@sha256:72ebf516fca7a9464db2136f2dcf2a58d09547669b60f3643a8329768febaed6

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd opam-repository && git reset --hard 8f4d15eae94dfe6f70a66a7572a21a0c60d9f4f4 && opam update

RUN sudo apt-get install -y m4 libxen-dev
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage
RUN opam pin add -n -y tcpip 'https://github.com/talex5/mirage-tcpip.git#fix-length-checks'
RUN opam pin add -n -y mirage-nat 'https://github.com/talex5/mirage-nat.git#cleanup'
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
