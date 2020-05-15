# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocurrent/opam:alpine-3.10-ocaml-4.08
FROM ocurrent/opam@sha256:3f3ce7e577a94942c7f9c63cbdd1ecbfe0ea793f581f69047f3155967bba36f6

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd ~/opam-repository && git fetch origin master && git reset --hard 3548c2a8537029b8165466cd9c5a94bb7bc30405 && opam update

RUN opam depext -i -y mirage.3.7.6 lwt.5.2.0
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
