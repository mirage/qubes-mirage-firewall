# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless an update
# changes some compiler optimisations (unlikely).
# bookworm-slim
FROM debian@sha256:07c6cb2ae86479dcc1942a89b0a1f4049b6e9415f7de327ff641aed58b8e3100
# and set the package source to a specific release too
RUN printf "deb [check-valid-until=no] http://snapshot.notset.fr/archive/debian/20230418T024659Z bookworm main" > /etc/apt/sources.list

RUN apt update && apt install --no-install-recommends --no-install-suggests -y wget ca-certificates git patch unzip bzip2 make gcc g++ libc-dev
RUN wget -O /usr/bin/opam https://github.com/ocaml/opam/releases/download/2.1.4/opam-2.1.4-i686-linux && chmod 755 /usr/bin/opam

ENV OPAMROOT=/tmp
ENV OPAMCONFIRMLEVEL=unsafe-yes
# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
RUN opam init --disable-sandboxing -a --bare https://github.com/ocaml/opam-repository.git#28b35f67988702df5018fbf30d1c725734425670
RUN opam switch create myswitch 4.14.1
RUN opam exec -- opam install -y mirage opam-monorepo ocaml-solo5
RUN mkdir /tmp/orb-build
ADD config.ml /tmp/orb-build/config.ml
WORKDIR /tmp/orb-build
CMD opam exec -- sh -exc 'mirage configure -t xen --allocation-policy=best-fit && make depend && make tar'
