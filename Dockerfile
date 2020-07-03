# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocurrent/opam:alpine-3.10-ocaml-4.10
FROM ocurrent/opam@sha256:d30098ff92b5ee10cf7c11c17f2351705e5226a6b05aa8b9b7280b3d87af9cde

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd ~/opam-repository && git fetch origin master && git reset --hard e81ab2996896b21cba74c43a903b305a5a6341ef && opam update

RUN opam depext -i -y mirage.3.8.0 lwt.5.3.0
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
