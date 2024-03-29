# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless an update
# changes some compiler optimisations (unlikely).
# bookworm-slim taken from https://hub.docker.com/_/debian/tags?page=1&name=bookworm-slim
FROM debian@sha256:ea5ad531efe1ac11ff69395d032909baf423b8b88e9aade07e11b40b2e5a1338
# install remove default packages repository
RUN rm /etc/apt/sources.list.d/debian.sources
# and set the package source to a specific release too
# taken from https://snapshot.debian.org/archive/debian
RUN printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20231107T084929Z bookworm main\n" > /etc/apt/sources.list
# taken from https://snapshot.debian.org/archive/debian-security/
RUN printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20231108T004541Z bookworm-security main\n" >> /etc/apt/sources.list

RUN apt update && apt install --no-install-recommends --no-install-suggests -y wget ca-certificates git patch unzip bzip2 make gcc g++ libc-dev
RUN wget -O /usr/bin/opam https://github.com/ocaml/opam/releases/download/2.1.5/opam-2.1.5-i686-linux && chmod 755 /usr/bin/opam
# taken from https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh
RUN test `sha512sum /usr/bin/opam | cut -d' ' -f1` = \
"38802b3079eeceb27aab3465bfd0f9f05a710dccf9487eb35fa2c02fbaf9a0659e1447aa19dd36df9cd01f760229de28c523c08c1c86a3aa3f5e25dbe7b551dd" || exit

ENV OPAMROOT=/tmp
ENV OPAMCONFIRMLEVEL=unsafe-yes
# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
# taken from https://github.com/ocaml/opam-repository
RUN opam init --disable-sandboxing -a --bare https://github.com/ocaml/opam-repository.git#d1a8bf040fbb2c81ddb2612f1a49a471a06083dc
RUN opam switch create myswitch 4.14.1
RUN opam exec -- opam install -y mirage opam-monorepo ocaml-solo5
RUN mkdir /tmp/orb-build
ADD config.ml /tmp/orb-build/config.ml
WORKDIR /tmp/orb-build
CMD opam exec -- sh -exc 'mirage configure -t xen --extra-repos=\
opam-overlays:https://github.com/dune-universe/opam-overlays.git#91a371754a2c9f4febbb6c7bb039649ad49a3c13,\
mirage-overlays:https://github.com/dune-universe/mirage-opam-overlays.git#05f1c1823d891ce4d8adab91f5db3ac51d86dc0b \
--allocation-policy=best-fit && make depend && make tar'
