# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless an update
# changes some compiler optimisations (unlikely).
FROM ocaml/opam@sha256:68b7ce1fd4c992d6f3bfc9b4b0a88ee572ced52427f0547b6e4eb6194415f585
ENV PATH="${PATH}:/home/opam/.opam/4.14/bin"

# Since mirage 4.2 we must use opam version 2.1 or later
RUN sudo cp /usr/bin/opam-2.1 /usr/bin/opam

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd /home/opam/opam-repository && git fetch origin master && git reset --hard f85e121f6dd1fd92d9a3d9c8ac9fa553495258bc && opam update

RUN opam install -y mirage opam-monorepo
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam exec -- mirage configure -t xen && make depend
CMD opam exec -- mirage configure -t xen && make tar
