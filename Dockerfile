# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocaml/opam2:debian-9-ocaml-4.07
FROM ocaml/opam2@sha256:f7125924dd6632099ff98b2505536fe5f5c36bf0beb24779431bb62be5748562

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN git fetch origin && git reset --hard c261c4ee9c1ef032af93483913b60f674d4acdb2 && opam update

RUN sudo apt-get install -y m4 libxen-dev pkg-config
RUN opam pin add -yn cmdliner 'https://github.com/talex5/cmdliner.git#repro-builds'
RUN opam install -y vchan xen-gnt mirage-xen-ocaml mirage-xen-minios io-page mirage-xen mirage mirage-nat mirage-qubes
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
