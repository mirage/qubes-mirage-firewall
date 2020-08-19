# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocurrent/opam:alpine-3.10-ocaml-4.10
FROM ocurrent/opam@sha256:4546b41a99b54f163af435327c86f88d06346f2a059f0f42bea431b37329ea8d

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd ~/opam-repository && git fetch origin master && git reset --hard 6ef290f5681b7ece5d9c085bcf0c55268c118292 && opam update

RUN opam depext -i -y mirage
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
