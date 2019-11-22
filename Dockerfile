# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless Debian
# changes some compiler optimisations (unlikely).
#FROM ocurrent/opam:alpine-3.10-ocaml-4.08
FROM ocurrent/opam@sha256:3f3ce7e577a94942c7f9c63cbdd1ecbfe0ea793f581f69047f3155967bba36f6

# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN cd ~/opam-repository && git fetch origin master && git reset --hard 5eed470abc5c7991e448c9653698c03d6ea146d1 && opam update

RUN opam depext -i -y mirage.3.5.2 lwt
RUN opam pin -n xenstore 'https://github.com/talex5/ocaml-xenstore.git#unwatch-crash'
RUN mkdir /home/opam/qubes-mirage-firewall
ADD config.ml /home/opam/qubes-mirage-firewall/config.ml
WORKDIR /home/opam/qubes-mirage-firewall
RUN opam config exec -- mirage configure -t xen && make depend
CMD opam config exec -- mirage configure -t xen && \
    opam config exec -- make tar
