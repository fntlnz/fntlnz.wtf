FROM docker.io/golang:1.8 as builder


WORKDIR /tmp
RUN curl -L -o hugo.tar.gz  https://github.com/gohugoio/hugo/releases/download/v0.31.1/hugo_0.31.1_Linux-64bit.tar.gz
RUN tar -xvf hugo.tar.gz
RUN mv hugo /bin/hugo
ADD . /site
WORKDIR /site
ARG HUGO_SITE_VERSION=dirty
RUN hugo -d build

FROM docker.io/nginx:1.13-alpine

COPY --from=builder /site/build /usr/share/nginx/html
