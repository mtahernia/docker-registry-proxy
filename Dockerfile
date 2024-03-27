# We start from my nginx fork which includes the proxy-connect module from tEngine
# Source is available at https://github.com/rpardini/nginx-proxy-connect-stable-alpine
# This is already multi-arch!

FROM alpine:3.12.7 as nginx

# apk upgrade in a separate layer (musl is huge)
RUN apk upgrade --no-cache --update

# Bring in tzdata and runtime libs into their own layer
RUN apk add --no-cache --update tzdata pcre zlib libssl1.1

# If set to 1, enables building debug version of nginx, which is super-useful, but also heavy to build.
ARG DEBUG_BUILD="0"
ENV DO_DEBUG_BUILD="$DEBUG_BUILD"

ENV NGINX_VERSION 1.20.1

# nginx layer
RUN CONFIG="\
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nginx \
		--group=nginx \
		--with-http_ssl_module \
		--with-http_realip_module \
		--with-http_addition_module \
		--with-http_sub_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_random_index_module \
		--with-http_secure_link_module \
		--with-http_stub_status_module \
		--with-http_auth_request_module \
		--with-threads \
		--with-stream \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
		--with-http_slice_module \
		--with-compat \
		--with-file-aio \
		--with-http_v2_module \
	" \
	&& addgroup -S nginx \
	&& adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
	&& apk add --no-cache --update --virtual .build-deps gcc libc-dev make openssl-dev pcre-dev zlib-dev linux-headers patch curl git  \
 	&& curl -fSL https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz \
	&& git clone https://github.com/chobits/ngx_http_proxy_connect_module.git /usr/src/ngx_http_proxy_connect_module \
	&& cd /usr/src/ngx_http_proxy_connect_module && export PROXY_CONNECT_MODULE_PATH="$(pwd)" && cd - \
	&& CONFIG="$CONFIG --add-module=$PROXY_CONNECT_MODULE_PATH" \
	&& mkdir -p /usr/src \
	&& tar -zxC /usr/src -f nginx.tar.gz \
	&& rm nginx.tar.gz \
	&& cd /usr/src/nginx-$NGINX_VERSION \
	&& patch -p1 < $PROXY_CONNECT_MODULE_PATH/patch/proxy_connect_rewrite_101504.patch \
	&& [ "a$DO_DEBUG_BUILD" == "a1" ] && { echo "Bulding DEBUG" &&  ./configure $CONFIG --with-debug && make -j$(getconf _NPROCESSORS_ONLN) && mv objs/nginx objs/nginx-debug ; } || { echo "Not building debug"; } \
	&& { echo "Bulding RELEASE" && ./configure $CONFIG  && make -j$(getconf _NPROCESSORS_ONLN) && make install; } \
	&& ls -laR objs/addon/ngx_http_proxy_connect_module/ \
	&& rm -rf /etc/nginx/html/ \
	&& mkdir /etc/nginx/conf.d/ \
	&& mkdir -p /usr/share/nginx/html/ \
	&& install -m644 html/index.html /usr/share/nginx/html/ \
	&& install -m644 html/50x.html /usr/share/nginx/html/ \
	&& [ "a$DO_DEBUG_BUILD" == "a1" ] && { install -m755 objs/nginx-debug /usr/sbin/nginx-debug; } || { echo "Not installing debug..."; } \
	&& mkdir -p /usr/lib/nginx/modules \
	&& ln -s /usr/lib/nginx/modules /etc/nginx/modules \
	&& strip /usr/sbin/nginx* \
	&& rm -rf /usr/src/nginx-$NGINX_VERSION \
	\
	# Remove -dev apks and sources
	&& apk del .build-deps gcc libc-dev make openssl-dev pcre-dev zlib-dev linux-headers patch curl git && rm -rf /usr/src \
	\
	# forward request and error logs to docker log collector
	&& ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log

#RUN ls -laR /usr/share/nginx /etc/nginx /etc/nginx/modules/ /usr/lib/nginx

ADD nginx.default.conf /etc/nginx/nginx.conf
ADD nginx.vh.default.conf /etc/nginx/conf.d/default.conf

# Basic sanity testing.
RUN nginx -V 2>&1 && nginx -t && ldd /usr/sbin/nginx && apk list && rm -rf /run/nginx.pid /var/cache/nginx/*_temp

EXPOSE 80

STOPSIGNAL SIGTERM

CMD ["nginx", "-g", "daemon off;"]







FROM nginx as registry-proxy

# Link image to original repository on GitHub
LABEL org.opencontainers.image.source https://github.com/rpardini/docker-registry-proxy

# apk packages that will be present in the final image both debug and release
RUN apk add --no-cache --update bash ca-certificates-bundle coreutils openssl

# If set to 1, enables building mitmproxy, which helps a lot in debugging, but is super heavy to build.
ARG DEBUG_IMAGE
ARG DO_DEBUG_BUILD="${DEBUG_IMAGE:-"0"}"

# Build mitmproxy via pip. This is heavy, takes minutes do build and creates a 90mb+ layer. Oh well.
RUN [[ "a$DO_DEBUG_BUILD" == "a1" ]] && { echo "Debug build ENABLED." \
 && apk add --no-cache --update su-exec cargo bsd-compat-headers git g++ libffi libffi-dev libstdc++ openssl-dev python3 python3-dev py3-pip py3-wheel py3-six py3-idna py3-certifi py3-setuptools \
 && rm /usr/lib/python3.*/EXTERNALLY-MANAGED \
 && LDFLAGS=-L/lib pip install MarkupSafe mitmproxy \
 && apk del --purge git g++ libffi-dev openssl-dev python3-dev py3-pip py3-wheel \
 && rm -rf ~/.cache/pip \
 ; } || { echo "Debug build disabled." ; }

# Required for mitmproxy
ENV LANG=en_US.UTF-8

# Check the installed mitmproxy version, if built.
RUN [[ "a$DO_DEBUG_BUILD" == "a1" ]] && { mitmproxy --version && mitmweb --version ; } || { echo "Debug build disabled."; }

# Create the cache directory and CA directory
RUN mkdir -p /docker_mirror_cache /ca

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME /docker_mirror_cache

# Expose /ca as a volume. Users are supposed to volume mount this, as to preserve it across restarts.
# Actually, its required; if not, then docker clients will reject the CA certificate when the proxy is run the second time
VOLUME /ca

# Add our configuration
ADD nginx.conf /etc/nginx/nginx.conf
ADD nginx.manifest.common.conf /etc/nginx/nginx.manifest.common.conf
ADD nginx.manifest.stale.conf /etc/nginx/nginx.manifest.stale.conf

# Add our very hackish entrypoint and ca-building scripts, make them executable
ADD entrypoint.sh /entrypoint.sh
ADD create_ca_cert.sh /create_ca_cert.sh
RUN chmod +x /create_ca_cert.sh /entrypoint.sh

# Add Liveliness Probe script for CoreWeave
RUN apk --no-cache add curl
ADD liveliness.sh /liveliness.sh
RUN chmod +x /liveliness.sh

# Clients should only use 3128, not anything else.
EXPOSE 3128

# In debug mode, 8081 exposes the mitmweb interface (for incoming requests from Docker clients)
EXPOSE 8081
# In debug-hub mode, 8082 exposes the mitmweb interface (for outgoing requests to DockerHub)
EXPOSE 8082

## Default envs.
# A space delimited list of registries we should proxy and cache; this is in addition to the central DockerHub.
ENV REGISTRIES="k8s.gcr.io gcr.io quay.io"
# List of registries requiring a special TCP port
ENV REGISTRIES_CUSTOM_PORT="registry-1.docker.io:443"
# A space delimited list of registry:user:password to inject authentication for
ENV AUTH_REGISTRIES="some.authenticated.registry:oneuser:onepassword another.registry:user:password"
# Should we verify upstream's certificates? Default to true.
ENV VERIFY_SSL="true"
# Enable debugging mode; this inserts mitmproxy/mitmweb between the CONNECT proxy and the caching layer
ENV DEBUG="false"
# Enable debugging mode; this inserts mitmproxy/mitmweb between the caching layer and DockerHub's registry
ENV DEBUG_HUB="false"
# Enable nginx debugging mode; this uses nginx-debug binary and enabled debug logging, which is VERY verbose so separate setting
ENV DEBUG_NGINX="false"
# Enable slow caching tier; this allows caching in a secondary cache path on e.g a larger slower disk; for known URIs defined in SLOW_TIER_URIS
ENV SLOW_TIER_ENABLED="false"
# Statically define worker_processes; defaults to auto
ENV WORKER_PROCESSES="auto"

# Manifest caching tiers. Disabled by default, to mimick 0.4/0.5 behaviour.
# Setting it to true enables the processing of the ENVs below.
# Once enabled, it is valid for all registries, not only DockerHub.
# The envs *_REGEX represent a regex fragment, check entrypoint.sh to understand how they're used (nginx ~ location, PCRE syntax).
ENV ENABLE_MANIFEST_CACHE="false"

# 'Primary' tier defaults to 10m cache for frequently used/abused tags.
# - People publishing to production via :latest (argh) will want to include that in the regex
# - Heavy pullers who are being ratelimited but don't mind getting outdated manifests should (also) increase the cache time here
ENV MANIFEST_CACHE_PRIMARY_REGEX="(stable|nightly|production|test)"
ENV MANIFEST_CACHE_PRIMARY_TIME="10m"

# 'Secondary' tier defaults any tag that has 3 digits or dots, in the hopes of matching most explicitly-versioned tags.
# It caches for 60d, which is also the cache time for the large binary blobs to which the manifests refer.
# That makes them effectively immutable. Make sure you're not affected; tighten this regex or widen the primary tier.
ENV MANIFEST_CACHE_SECONDARY_REGEX="(.*)(\d|\.)+(.*)(\d|\.)+(.*)(\d|\.)+"
ENV MANIFEST_CACHE_SECONDARY_TIME="60d"

# The default cache duration for manifests that don't match either the primary or secondary tiers above.
# In the default config, :latest and other frequently-used tags will get this value.
ENV MANIFEST_CACHE_DEFAULT_TIME="1h"

# This lists the registries hosts for which manifests caching is disabled
ENV MANIFEST_CACHE_EXCLUDE_HOSTS="privat.registry.io"

# Should we allow actions different than pull, default to false.
ENV ALLOW_PUSH="false"

# If push is allowed, buffering requests can cause issues on slow upstreams.
# If you have trouble pushing, set this to false first, then fix remainig timouts.
# Default is true to not change default behavior.
ENV PROXY_REQUEST_BUFFERING="true"

# Force HTTP/1.1 upstream connections, for http2 upstream that returns 426 Upgrade Required
ENV FORCE_UPSTREAM_HTTP_1_1="false"

# Stream data; reduce TTFB
# Effectively disables caching
# Default is true to not change default behavior.
ENV PROXY_BUFFERING="true"

# Should we allow overridding with own authentication, default to false.
ENV ALLOW_OWN_AUTH="false"

# Should we allow push only with own authentication, default to false.
ENV ALLOW_PUSH_WITH_OWN_AUTH="false"


# Timeouts
# ngx_http_core_module
ENV SEND_TIMEOUT="60s"
ENV CLIENT_BODY_TIMEOUT="60s"
ENV CLIENT_HEADER_TIMEOUT="60s"
ENV KEEPALIVE_TIMEOUT="300s"
# ngx_http_proxy_module
ENV PROXY_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_TIMEOUT="60s"
ENV PROXY_SEND_TIMEOUT="60s"
# ngx_http_proxy_connect_module - external module
ENV PROXY_CONNECT_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_CONNECT_TIMEOUT="60s"
ENV PROXY_CONNECT_SEND_TIMEOUT="60s"

# Did you want a shell? Sorry, the entrypoint never returns, because it runs nginx itself. Use 'docker exec' if you need to mess around internally.
ENTRYPOINT ["/entrypoint.sh"]
