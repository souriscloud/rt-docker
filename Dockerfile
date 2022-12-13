FROM debian:bullseye-slim as msmtp-builder

ENV MSMTP_VERSION="1.8.22"

# Install required packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get -q -y install --no-install-recommends \
  wget ca-certificates libgnutls28-dev xz-utils \
  build-essential automake libtool gettext texinfo pkg-config

RUN wget -O /msmtp.tar.xz -nv https://marlam.de/msmtp/releases/msmtp-${MSMTP_VERSION}.tar.xz \
  && tar -xf /msmtp.tar.xz \
  && cd /msmtp-${MSMTP_VERSION} \
  && autoreconf -i \
  && ./configure --sysconfdir=/etc \
  && make \
  && make install

#############################################################################

FROM debian:bullseye-slim as ossl-builder

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get -q -y install --no-install-recommends \
  ca-certificates \
  build-essential automake libtool gettext texinfo pkg-config


FROM perl:5.36.0 as builder

ENV RT="rt-5.0.3"
ENV RT_SHA256="e23aee3cb291ccad5e521aeabe0fcd2f076bcfa8b7f801af498a7505e53d8441"

# use cpanm for dependencies
ENV RT_FIX_DEPS_CMD="cpanm --no-man-pages"

# Create RT user
RUN groupadd -g 1000 rt && useradd -u 1000 -g 1000 -Ms /bin/bash -d /opt/rt5 rt

# Install required packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get -q -y install --no-install-recommends \
  ca-certificates wget gnupg graphviz libssl1.1 zlib1g \
  libgd3 libexpat1 libpq5 w3m elinks links html2text lynx openssl libgd-dev

# Download and extract RT
RUN mkdir -p /src \
  # download and extract RT
  && wget -O /src/${RT}.tar.gz -nv https://download.bestpractical.com/pub/rt/release/${RT}.tar.gz \
  && echo "${RT_SHA256} /src/${RT}.tar.gz" | sha256sum -c - \
  && tar -C /src -xzf /src/${RT}.tar.gz

# Configure RT
RUN cd /src/${RT} \
  # configure with all plugins and with the newly created user
  && ./configure --with-db-type=Pg --enable-gpg --enable-gd --enable-graphviz --enable-smime --enable-externalauth --with-web-user=rt --with-web-group=rt --with-rt-group=rt --with-bin-owner=rt --with-libs-owner=rt

# install GD::Graph without running tests as the tests
# are broken since the latest GD::Image update and
# the project seems to be dead
# https://rt.cpan.org/Public/Bug/Display.html?id=140940
# Also install Sever::Starter without tests
# as they constanly fail with timeouts and thus break
# the build
RUN cpanm --no-man-pages -n install GD::Graph \
  && cpanm --no-man-pages -n install Server::Starter

# Install dependencies
RUN make -C /src/${RT} fixdeps \
  && make -C /src/${RT} testdeps \
  && make -C /src/${RT} install \
  && cpanm --install RT::Extension::MergeUsers \
  && cpanm --install RT::Extension::TerminalTheme

#############################################################################

FROM perl:5.36.0-slim

# Install required packages
# we use busybox-static here for the busybox crond which works
# without systemd
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get -q -y install --no-install-recommends \
  procps supervisor ca-certificates getmail wget curl gnupg graphviz libssl1.1 \
  zlib1g libgd3 libexpat1 libpq5 w3m elinks links html2text lynx openssl busybox-static \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
# msmtp - disabled for now to use the newer version

# Create RT user
RUN useradd -u 1000 -Ms /bin/bash -d /opt/rt5 rt

# copy msmtp
COPY --from=msmtp-builder /usr/local/bin/msmtp /usr/bin/msmtp
COPY --from=msmtp-builder  /usr/local/share/locale /usr/local/share/locale

# copy all needed stuff from the builder image
COPY --from=builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=builder /opt/rt5 /opt/rt5
# run a final dependency check if we copied all 
RUN perl /opt/rt5/sbin/rt-test-dependencies --with-pg --with-fastcgi --with-gpg --with-graphviz --with-gd

# supervisord config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN mkdir -p /var/log/supervisor/ \
  && chown rt:rt /var/log/supervisor/ \
  && mkdir -p /var/run/supervisord \
  && chown rt:rt /var/run/supervisord

# cron config and install busybox symlink for crond
# RUN mkdir -p /var/spool/cron/crontabs \
#   && ln -fs /bin/busybox /usr/sbin/crond

# msmtp config
RUN mkdir /msmtp \
  && chown rt:rt /msmtp \
  # also fake sendmail for cronjobs
  && ln -s /usr/bin/msmtp /usr/sbin/sendmail

# getmail
RUN mkdir -p /getmail \
  && chown rt:rt /getmail

# gpg
RUN mkdir -p /opt/rt5/var/data/gpg \
  && chown rt:rt /opt/rt5/var/data/gpg

# smime
RUN mkdir -p /opt/rt5/var/data/smime \
  && chown rt:rt /opt/rt5/var/data/smime

# shredder dir
RUN mkdir -p /opt/rt5/var/data/RT-Shredder \
  && chown rt:rt /opt/rt5/var/data/RT-Shredder

# add dev/maintainer tools
RUN apt update && apt install -q -y vim nano cron gcc build-essential ca-certificates
# COPY crontab /etc/cron.d/rt
# RUN chmod 0644 /etc/cron.d/rt
# RUN chmod +x /etc/cron.d/crontab
# RUN crontab /etc/cron.d/crontab
RUN touch /var/log/cron.log
# RUN touch /etc/crontab /etc/cron.*/*

# openssl for getmail
RUN mkdir -p /opt/openssl/ssl
RUN ln -s /etc/ssl/certs /opt/openssl/ssl/certs
RUN wget -O /openssl.tar.gz https://www.openssl.org/source/openssl-1.1.1l.tar.gz \
  && tar -zxf /openssl.tar.gz --directory /opt/openssl \
  && cd /opt/openssl/openssl-1.1.1l \
  && ./config --prefix=/opt/openssl --openssldir=/opt/openssl/ssl \
  && make \
  # && make test \
  && make install \
  && mv /usr/bin/openssl /usr/bin/openssl-1.1.1g \
  && ln -s /usr/local/bin/openssl /usr/bin/openssl \
  && ldconfig \
  && touch /etc/profile.d/openssl.sh \
  && echo '#!/bin/sh' > /etc/profile.d/openssl.sh \
  && echo 'export PATH=/opt/openssl/bin:${PATH}' >> /etc/profile.d/openssl.sh \
  && echo 'export LD_LIBRARY_PATH=/opt/openssl/lib:${LD_LIBRARY_PATH}' >> /etc/profile.d/openssl.sh \
  && chmod +x /etc/profile.d/openssl.sh
  # && source /etc/profile.d/openssl.sh

# update PATH
ENV PATH="${PATH}:/opt/rt5/sbin:/opt/rt5/bin"

EXPOSE 9000

USER rt
WORKDIR /opt/rt5/

CMD [ "/usr/bin/supervisord" ]
