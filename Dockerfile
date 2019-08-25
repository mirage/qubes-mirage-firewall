# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocurrent/opam:alpine-3.10-ocaml-4.08
FROM ocurrent/opam@sha256:4cf6f8a427e7f65a250cd5dbc9f5069e8f8213467376af5136bf67a21d39d6ec

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd ~/opam-repository && git fetch origin master && git reset --hard a83bd077e4e54c41b0664a2e1618670d57b7c79d && opam update

RUN opam depext -i -y mirage lwt
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
