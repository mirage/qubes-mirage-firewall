# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless an update
# changes some compiler optimisations (unlikely).
# ubuntu-20.04
FROM ubuntu@sha256:b25ef49a40b7797937d0d23eca3b0a41701af6757afca23d504d50826f0b37ce

RUN apt update && apt install --no-install-recommends --no-install-suggests -y wget ca-certificates git patch unzip make gcc g++ libc-dev
RUN wget -O /usr/bin/opam https://github.com/ocaml/opam/releases/download/2.1.3/opam-2.1.3-i686-linux && chmod 755 /usr/bin/opam

ENV OPAMROOT=/tmp
ENV OPAMCONFIRMLEVEL=unsafe-yes
# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN opam init --disable-sandboxing -a --bare https://github.com/ocaml/opam-repository.git#685eb4efcebfa671660e55d76dea017f00fed4d9
RUN opam switch create myswitch 4.14.0
RUN opam exec -- opam install -y mirage opam-monorepo ocaml-solo5
RUN mkdir /tmp/orb-build
ADD config.ml /tmp/orb-build/config.ml
WORKDIR /tmp/orb-build
CMD opam exec -- sh -exc 'mirage configure -t xen --allocation-policy=best-fit && make depend && make tar'
