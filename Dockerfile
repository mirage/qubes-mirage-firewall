# Pin the base image to a specific hash for maximum reproducibility.
# It will probably still work on newer images, though, unless an update
# changes some compiler optimisations (unlikely).
# trixie-slim taken from https://hub.docker.com/_/debian/tags?page=1&name=trixie-slim
FROM debian@sha256:a617c1cdde36a7e0194b2f07dff669e1753c03c3205356b94f9f350b0f9a57d1

# install remove default packages repository
RUN rm /etc/apt/sources.list.d/debian.sources
# and set the package source to a specific release too
# taken from https://snapshot.debian.org/archive/debian
RUN printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260624T203550Z trixie main\n" > /etc/apt/sources.list
# taken from https://snapshot.debian.org/archive/debian-security/
RUN printf "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260624T222306Z trixie-security main\n" >> /etc/apt/sources.list

RUN apt update && apt install --no-install-recommends --no-install-suggests -y wget ca-certificates git patch unzip bzip2 make gcc g++ libc-dev xz-utils
RUN wget -O /usr/bin/opam https://github.com/ocaml/opam/releases/download/2.5.1/opam-2.5.1-x86_64-linux && chmod 755 /usr/bin/opam
# taken from https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh
RUN test `sha512sum /usr/bin/opam | cut -d' ' -f1` = \
"8c8bb8286d5453106e8b3997dde791fb338716d1ce9fbe692c22de25d2f0910990031e0b260fbca8d869197793b492ff9736bd240e2695fd54b91fabdaa3593d" || exit

ENV OPAMROOT=/tmp
ENV OPAMCONFIRMLEVEL=unsafe-yes
# Pin last known-good version for reproducible builds.
# Remove this line (and the base image pin above) if you want to test with the
# latest versions.
# taken from https://github.com/ocaml/opam-repository
RUN opam init --disable-sandboxing -a --bare https://github.com/ocaml/opam-repository.git#3f11c2a6ff49cb3786a9201432c4caa91bda0a59
RUN opam switch create myswitch 5.5.0
RUN opam exec -- opam install -y mirage opam-monorepo ocaml-solo5
RUN mkdir /tmp/orb-build
ADD config.ml /tmp/orb-build/config.ml
WORKDIR /tmp/orb-build
CMD opam exec -- sh -exc 'mirage configure -t xen --extra-repos=\
opam-overlays:https://github.com/dune-universe/opam-overlays.git#d3aca134ac032e7522e95a18f1ef72c63f45459b \
&& make depend && make unikernel'
